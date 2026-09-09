//  Decumulation.swift
//  WealthPolicyDesk
//
//  The multi-year, AFTER-TAX decumulation projection — the model's answer to the
//  question a single required-return number can't ask: year by year in retirement,
//  what income is forced out (RMDs, Social Security), what tax it triggers, and
//  where the household should draw from. Everything is in REAL (today's $) terms;
//  the 2026 brackets are inflation-indexed, so real brackets ≈ constant, and the
//  portfolio grows at the plan's own required real return (an internal number, not
//  a market forecast). This is a teaching projection, not a tax return.
//
//  A1 (here): the BASELINE path — no Roth conversions yet, a simple
//  taxable→deferred→Roth withdrawal order. A2 layers a bracket-fill optimizer on
//  top; A3 folds the per-year tax back into the required-return recursion.

import Foundation

public struct DecumulationYear: Identifiable, Sendable, Hashable {
    public var year: Int
    public var age: Int                    // the primary earner's age that year
    public var spendingNeedUsd: Usd
    public var guaranteedIncomeUsd: Usd    // Social Security + pension
    public var rmdUsd: Usd
    public var taxableWithdrawalUsd: Usd
    public var deferredWithdrawalUsd: Usd  // discretionary, on top of the RMD
    public var rothWithdrawalUsd: Usd
    public var rothConversionUsd: Usd      // tax-deferred → Roth, voluntarily taxed this year
    public var wagesUsd: Usd               // still-working adults' earnings that year
    public var ordinaryIncomeUsd: Usd      // wages + RMD + deferred draws + pension + taxable SS + conversion
    public var capitalGainsUsd: Usd
    public var ssTaxableUsd: Usd
    public var taxableIncomeUsd: Usd       // ordinary taxable income after the standard deduction
    public var federalTaxUsd: Usd
    public var irmaaUsd: Usd
    /// The part of (federal tax + IRMAA) the PORTFOLIO actually paid. A working year settles
    /// its tax out of that year's wages first, so this sits below the headline tax whenever an
    /// adult is still earning. The required-return and resilience recursions read this, not the
    /// headline — charging the portfolio for tax on wages it never received made a plan get
    /// worse the more the household earned.
    public var portfolioTaxUsd: Usd
    public var marginalRateBps: Bps
    public var magiUsd: Usd
    public var endTaxableUsd: Usd
    public var endDeferredUsd: Usd
    public var endRothUsd: Usd
    public var id: Int { year }
}

public struct DecumulationPlan: Sendable, Hashable {
    public var years: [DecumulationYear]
    public var lifetimeFederalTaxUsd: Usd
    public var lifetimeIrmaaUsd: Usd
    public var firstRmdAge: Int            // 0 if the plan ends before RMDs begin
    public var peakMarginalRateBps: Bps
    public static let empty = DecumulationPlan(years: [], lifetimeFederalTaxUsd: 0, lifetimeIrmaaUsd: 0, firstRmdAge: 0, peakMarginalRateBps: 0)
}

/// The recommended Roth-conversion plan vs the no-conversion baseline.
public struct RothStrategy: Sendable, Hashable {
    public var plan: DecumulationPlan          // the recommended projection (with conversions if they win)
    public var baseline: DecumulationPlan      // the no-conversion projection, for comparison
    public var targetBracketBps: Bps           // the bracket top filled to; 0 = no conversion recommended
    public var avgAnnualConversionUsd: Usd
    public var conversionYears: Int
    public var lifetimeTaxSavedUsd: Usd        // baseline − recommended (≥ 0)
    public static let empty = RothStrategy(plan: .empty, baseline: .empty, targetBracketBps: 0, avgAnnualConversionUsd: 0, conversionYears: 0, lifetimeTaxSavedUsd: 0)
}

public extension Engine {

    /// The decumulation output: the no-conversion baseline compared against filling the
    /// pre-RMD low-bracket years to the top of the 22% or 24% bracket, keeping whichever
    /// minimizes LIFETIME federal tax (converting early trades tax now for smaller RMDs,
    /// less Social-Security taxation, and less IRMAA later).
    static func rothStrategy(_ h: Household, tax: TaxParameterSet, rr: RequiredReturn, asOf: IsoDate) -> RothStrategy {
        let baseline = decumulation(h, tax: tax, rr: rr, asOf: asOf, debitTax: true)
        guard !baseline.years.isEmpty else { return .empty }
        var best = baseline, bestTarget: Bps = 0
        for target: Bps in [2200, 2400] {
            let p = decumulation(h, tax: tax, rr: rr, asOf: asOf, conversionToBracketTopBps: target, debitTax: true)
            if p.lifetimeFederalTaxUsd < best.lifetimeFederalTaxUsd { best = p; bestTarget = target }
        }
        let convYears = best.years.filter { $0.rothConversionUsd > 0 }
        let avg = convYears.isEmpty ? 0 : convYears.reduce(0) { $0 + $1.rothConversionUsd } / Double(convYears.count)
        return RothStrategy(plan: best, baseline: baseline, targetBracketBps: bestTarget,
                            avgAnnualConversionUsd: avg, conversionYears: convYears.count,
                            lifetimeTaxSavedUsd: max(0, baseline.lifetimeFederalTaxUsd - best.lifetimeFederalTaxUsd))
    }

    /// After-tax retirement projection. With `conversionToBracketTopBps` set, each
    /// pre-RMD year converts tax-deferred → Roth up to the top of that ordinary bracket.
    static func decumulation(_ h: Household, tax: TaxParameterSet, rr: RequiredReturn, asOf: IsoDate,
                             conversionToBracketTopBps: Bps? = nil, debitTax: Bool = false) -> DecumulationPlan {
        guard let primary = h.primary else { return .empty }
        let filing = h.filingStatus
        let stdDed = tax.standardDeduction[filing] ?? 0
        let r = max(0, rr.requiredRealReturnBps.frac)          // real growth = the plan's own required return
        let primaryAge0 = age(birthDate: primary.birthDate, asOf: asOf)
        let rmdAge = rmdStartAge(birthDate: primary.birthDate, default: tax.rmdStartAge)
        let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
        let planToAge = primaryAge0 + horizon
        let firstAge = max(primaryAge0, primary.expectedRetirementAge)
        guard planToAge >= firstAge else { return .empty }

        // Bucket balances and the taxable account's blended gain fraction.
        var taxable = h.value(in: .taxable)
        var roth = h.value(in: .taxFree)

        // Tax-deferred money is POOLED for spending, but RMDs are not a household event:
        // each account's required beginning age follows ITS OWNER's birth year and its
        // divisor follows that owner's age. Gating the whole pool on the primary started a
        // spouse's 401(k) distributing on his schedule — with a primary of 75 and a spouse
        // of 73 holding the whole pool, the engine reported the first RMD in a year she
        // turns 82, and the optimiser recommended conversions through years she was already
        // taking distributions. Joint and unowned accounts fall to the primary.
        var deferredBuckets: [(ownerAge0: Int, rmdAge: Int, balance: Usd)] = {
            var byOwner: [String: Usd] = [:]
            for p in h.positions(in: .taxDeferred) {
                let owner = h.account(p.accountId)?.ownership.ownerPersonId
                let person = h.people.first { $0.id == owner && $0.role != .dependent } ?? primary
                byOwner[person.id, default: 0] += p.marketValueUsd
            }
            return byOwner.compactMap { id, bal in
                guard let person = h.people.first(where: { $0.id == id }) else { return nil }
                return (age(birthDate: person.birthDate, asOf: asOf),
                        rmdStartAge(birthDate: person.birthDate, default: tax.rmdStartAge), bal)
            }.sorted { $0.ownerAge0 > $1.ownerAge0 }   // deterministic order; oldest owner first
        }()
        func deferredTotal() -> Usd { deferredBuckets.reduce(0) { $0 + $1.balance } }
        /// Draw `amount` from the deferred pool pro-rata across owners, returning what was
        /// actually available. Spending, conversions and tax all drain through here so the
        /// per-owner split stays consistent with the pooled total.
        @discardableResult
        func drainDeferred(_ amount: Usd) -> Usd {
            let total = deferredTotal()
            guard total > 0, amount > 0 else { return 0 }
            let take = min(amount, total)
            for i in deferredBuckets.indices {
                deferredBuckets[i].balance -= take * (deferredBuckets[i].balance / total)
            }
            return take
        }
        func growDeferred(_ factor: Double) {
            for i in deferredBuckets.indices { deferredBuckets[i].balance *= factor }
        }
        func addDeferred(_ amount: Usd) {
            guard amount > 0 else { return }
            let total = deferredTotal()
            if total > 0 {
                for i in deferredBuckets.indices {
                    deferredBuckets[i].balance += amount * (deferredBuckets[i].balance / total)
                }
            } else if !deferredBuckets.isEmpty {
                deferredBuckets[0].balance += amount
            } else {
                deferredBuckets = [(primaryAge0, rmdAge, amount)]
            }
        }
        let taxablePos = h.positions(in: .taxable)
        let taxableMv = taxablePos.reduce(0) { $0 + $1.marketValueUsd }
        let taxableGainFrac = taxableMv > 0 ? taxablePos.reduce(0) { $0 + max(0, $1.unrealizedGainUsd) } / taxableMv : 0

        // Project the accumulation phase to retirement: compound the current balances at
        // r and add the future value of real annual savings (split by the current bucket
        // mix), so a not-yet-retired household starts retirement on the right balances.
        let accumYears = firstAge - primaryAge0
        if accumYears > 0 {
            let g = pow(1 + r, Double(accumYears))
            taxable *= g; roth *= g; growDeferred(g)
            let fvSavings = r > 0 ? h.annualSavingsUsd * (g - 1) / r : h.annualSavingsUsd * Double(accumYears)
            let deferredNow = deferredTotal()
            let bal = taxable + deferredNow + roth
            if bal > 0 {
                taxable += fvSavings * taxable / bal
                roth += fvSavings * roth / bal
                addDeferred(fvSavings * deferredNow / bal)
            } else { addDeferred(fvSavings) }
        }

        // The muni share of the taxable book, fixed at the plan date and applied to the
        // running balance — the projection does not track instruments, only buckets.
        let muniMv = taxablePos.filter { Engine.muniTickers.contains($0.ticker.uppercased()) }
            .reduce(0) { $0 + $1.marketValueUsd }
        let muniShareOfTaxable = taxableMv > 0 ? muniMv / taxableMv : 0

        let startYear = year(asOf)
        let adults = h.people.filter { $0.role != .dependent }
        var years: [DecumulationYear] = []
        var lifetimeTax: Usd = 0, lifetimeIrmaa: Usd = 0, firstRmdAge = 0

        for ageNow in firstAge...planToAge {
            let t = ageNow - primaryAge0                       // plan-year index (years from asOf)
            let ss = socialSecurityAnnual(h, year: t, asOf: asOf)
            let pension = pensionAnnual(h, year: t)
            // Wages of any adult still working this year. The projection starts at the
            // PRIMARY's retirement, so a younger spouse is often still earning — ignoring
            // that income made the pre-RMD years look empty, understated Social-Security
            // taxation, and handed the Roth optimizer a phantom low bracket to fill.
            let wages = wagesAtPlanYear(h, year: t, asOf: asOf)
            // RMD: each owner's own balance, on their own required beginning age, divided by
            // the IRS Uniform Lifetime factor for THEIR age.
            var rmd: Usd = 0
            for i in deferredBuckets.indices {
                let ownerAge = deferredBuckets[i].ownerAge0 + t
                guard ownerAge >= deferredBuckets[i].rmdAge, deferredBuckets[i].balance > 0 else { continue }
                let amount = deferredBuckets[i].balance / uniformLifetimeDivisor(ownerAge)
                deferredBuckets[i].balance -= amount           // the RMD leaves the account (as income)
                rmd += amount
            }
            if rmd > 0 && firstRmdAge == 0 { firstRmdAge = ageNow }

            // Discretionary need beyond guaranteed income and the forced RMD.
            let spend = retirementSpendingOutflow(h, year: t)
            var need = max(0, spend - ss - pension - wages - rmd)
            var wTaxable: Usd = 0, wDeferred: Usd = 0, wRoth: Usd = 0
            if need > 0 { wTaxable = min(taxable, need); taxable -= wTaxable; need -= wTaxable }
            if need > 0 { wDeferred = drainDeferred(need); need -= wDeferred }
            if need > 0 { wRoth = min(roth, need); roth -= wRoth; need -= wRoth }
            // Cash conservation. Guaranteed income covers spending first; wages and the forced
            // RMD cover what is left. Whatever the RMD leaves over is reinvested in taxable, and
            // whatever the WAGES leave over is saved at the rate the household actually reports —
            // the surplus above that rate is the working year's living costs, which the
            // retirement-spending goal does not describe. Wages used to be netted against
            // spending and taxed but credited nowhere: the tax on them was debited from the
            // portfolio while the cash itself vanished, so a plan got worse as the client earned.
            let unmetBySafeIncome = max(0, spend - ss - pension)
            var wagesLeft = max(0, wages - unmetBySafeIncome)
            taxable += max(0, rmd - max(0, unmetBySafeIncome - wages))

            // Income and federal tax.
            let capGains = wTaxable * taxableGainFrac
            var ordinaryExSS = rmd + wDeferred + pension + wages
            // Roth conversion: in the pre-RMD window, fill ordinary income up to the top
            // of the target bracket (tax-deferred → Roth, taxed now at the low rate).
            var conversion: Usd = 0
            // The window closes when the FIRST owner's RMDs begin — recommending conversions
            // in a year any part of the pool is already distributing is the error the
            // per-owner split exists to prevent.
            if let topBps = conversionToBracketTopBps, deferredTotal() > 0,
               !deferredBuckets.contains(where: { $0.ownerAge0 + t >= $0.rmdAge }) {
                let ceiling = bracketTopTaxable(topBps, filing: filing, tax: tax)
                let ssEst = taxableSocialSecurity(ss: ss, otherIncome: ordinaryExSS + capGains, filing: filing)
                let preTaxable = max(0, ordinaryExSS + ssEst - stdDed)
                conversion = drainDeferred(max(0, ceiling - preTaxable))
                roth += conversion; ordinaryExSS += conversion
            }
            let ssTaxable = taxableSocialSecurity(ss: ss, otherIncome: ordinaryExSS + capGains, filing: filing)
            let ordinaryIncome = ordinaryExSS + ssTaxable
            let ordinaryTaxable = max(0, ordinaryIncome - stdDed)
            // Standard deduction not consumed by ordinary income spills onto the gains.
            let taxableGains = max(0, capGains - max(0, stdDed - ordinaryIncome))
            let ordinaryTax = progressiveTax(ordinaryTaxable, brackets: tax.ordinaryBrackets[filing] ?? [])
            let ltcgTax = ltcgTaxStacked(taxableGains, ordinaryTaxable: ordinaryTaxable, breakpoints: tax.ltcgBreakpoints[filing] ?? [])
            let magi = ordinaryIncome + capGains
            let niit = niitTax(magi: magi, netInvestmentIncome: capGains, filing: filing, tax: tax)
            let federalTax = ordinaryTax + ltcgTax + niit
            let medicareCount = adults.filter { age(birthDate: $0.birthDate, asOf: asOf) + t >= 65 }.count
            // IRMAA MAGI is AGI PLUS tax-exempt interest — municipal income is explicitly
            // added back. It stays out of NIIT and the SALT phase-down band, which is why
            // the two are easy to conflate, but a retiree at $205,000 with $10,000 of muni
            // interest reads as safely under the $200,000 step when they have in fact
            // cleared it. Estimated from the muni share of the taxable book, which shrinks
            // with the balance as the projection draws it down.
            let irmaaMagi = magi + taxable * muniShareOfTaxable * Engine.assumedMuniYieldBps.frac
            let irmaa = irmaaAnnual(magi: irmaaMagi, medicareCount: medicareCount, filing: filing, tiers: tax.irmaaTiers)
            lifetimeTax += federalTax; lifetimeIrmaa += irmaa
            // Conservation: the year's tax is actually paid from the portfolio (taxable → deferred → Roth),
            // so the balances that roll forward — and the RMDs they drive — are genuinely after-tax.
            // A working year settles its own tax out of that year's wages before the portfolio
            // is touched. Split it whether or not THIS pass debits balances: the first pass
            // runs with `debitTax: false` purely to feed the required-return recursion, and
            // that recursion reads `portfolioTaxUsd` — computing it inside the debit branch
            // fed the second pass an all-zero series and silently turned the after-tax solve
            // back into the pre-tax one.
            var due = federalTax + irmaa
            let payW = min(wagesLeft, due); wagesLeft -= payW; due -= payW
            let portfolioTax = due
            if debitTax {
                let payT = min(taxable, due); taxable -= payT; due -= payT
                let payD = drainDeferred(due); due -= payD
                roth = max(0, roth - due)
            }
            // What the wages leave after spending and tax is saved, at the reported rate.
            // Only past `accumYears`: the accumulation block above already compounded the
            // savings for plan-years 1...accumYears, and this loop's FIRST year is t ==
            // accumYears — crediting there would book that year's saving twice.
            if t > accumYears { taxable += min(h.annualSavingsUsd, wagesLeft) }

            years.append(DecumulationYear(
                year: startYear + t, age: ageNow, spendingNeedUsd: spend, guaranteedIncomeUsd: ss + pension,
                rmdUsd: rmd, taxableWithdrawalUsd: wTaxable, deferredWithdrawalUsd: wDeferred, rothWithdrawalUsd: wRoth,
                rothConversionUsd: conversion, wagesUsd: wages,
                ordinaryIncomeUsd: ordinaryIncome, capitalGainsUsd: capGains, ssTaxableUsd: ssTaxable,
                taxableIncomeUsd: ordinaryTaxable, federalTaxUsd: federalTax, irmaaUsd: irmaa, portfolioTaxUsd: portfolioTax,
                marginalRateBps: marginalOrdinaryRateBps(taxableIncome: ordinaryTaxable, filing: filing, tax: tax),
                magiUsd: magi, endTaxableUsd: taxable, endDeferredUsd: deferredTotal(), endRothUsd: roth))

            // Grow the surviving balances into next year.
            taxable *= (1 + r); roth *= (1 + r); growDeferred(1 + r)
        }
        return DecumulationPlan(years: years, lifetimeFederalTaxUsd: lifetimeTax, lifetimeIrmaaUsd: lifetimeIrmaa,
                                firstRmdAge: firstRmdAge, peakMarginalRateBps: years.map { $0.marginalRateBps }.max() ?? 0)
    }

    // MARK: - Tax primitives (real dollars, 2026 indexed brackets)

    /// Gross real spending drawn by the household's spending goals in plan-year t.
    static func retirementSpendingOutflow(_ h: Household, year t: Int) -> Usd {
        var out: Usd = 0
        for g in h.goals where g.kind == .spending {
            let excess = g.inflationSeries.realExcessBps.frac
            for o in g.outflows where o.year == t {
                out += o.amountUsd * (o.inflationLinked ? pow(1 + excess, Double(max(0, t - 1))) : 1.0)
            }
        }
        return out
    }

    /// The taxable-income ceiling (top edge) of the ordinary bracket with the given rate.
    static func bracketTopTaxable(_ rateBps: Bps, filing: FilingStatus, tax: TaxParameterSet) -> Usd {
        (tax.ordinaryBrackets[filing] ?? []).first { $0.rateBps == rateBps }?.upToUsd ?? Double.greatestFiniteMagnitude
    }

    /// Total (not marginal) ordinary tax by walking the brackets.
    static func progressiveTax(_ taxable: Usd, brackets: [BracketRow]) -> Usd {
        guard taxable > 0 else { return 0 }
        var tax: Usd = 0, lower: Usd = 0
        for row in brackets {
            let upper = row.upToUsd ?? Double.greatestFiniteMagnitude
            guard taxable > lower else { break }
            tax += (min(taxable, upper) - lower) * row.rateBps.frac
            lower = upper
        }
        return tax
    }

    /// Long-term capital-gains tax, stacked ON TOP of ordinary taxable income
    /// (each LTCG breakpoint is a total-taxable-income threshold).
    static func ltcgTaxStacked(_ gains: Usd, ordinaryTaxable: Usd, breakpoints: [BracketRow]) -> Usd {
        guard gains > 0 else { return 0 }
        var tax: Usd = 0, lower = ordinaryTaxable, remaining = gains
        for row in breakpoints {
            let upper = row.upToUsd ?? Double.greatestFiniteMagnitude
            guard upper > lower else { continue }
            let inBracket = min(remaining, upper - lower)
            if inBracket > 0 { tax += inBracket * row.rateBps.frac; remaining -= inBracket; lower += inBracket }
            if remaining <= 0 { break }
        }
        return tax
    }

    /// Taxable portion of Social Security via the provisional-income worksheet
    /// (statutory base amounts, un-indexed since 1993).
    static func taxableSocialSecurity(ss: Usd, otherIncome: Usd, filing: FilingStatus) -> Usd {
        guard ss > 0 else { return 0 }
        let base1: Usd = filing == .mfj ? 32_000 : 25_000
        let base2: Usd = filing == .mfj ? 44_000 : 34_000
        let provisional = otherIncome + 0.5 * ss
        if provisional <= base1 { return 0 }
        if provisional <= base2 { return min(0.5 * ss, 0.5 * (provisional - base1)) }
        let tier1 = min(0.5 * ss, 0.5 * (base2 - base1))
        return min(0.85 * ss, 0.85 * (provisional - base2) + tier1)
    }

    /// 3.8% Net Investment Income Tax on the lesser of NII and MAGI over the threshold.
    static func niitTax(magi: Usd, netInvestmentIncome nii: Usd, filing: FilingStatus, tax: TaxParameterSet) -> Usd {
        let threshold = tax.niitThreshold[filing] ?? 200_000
        return min(max(0, nii), max(0, magi - threshold)) * tax.niitRateBps.frac
    }

    /// Annual Medicare IRMAA surcharge — the highest tier the MAGI clears, times the
    /// number of Medicare-age adults (each pays their own surcharge).
    static func irmaaAnnual(magi: Usd, medicareCount: Int, filing: FilingStatus, tiers: [FilingStatus: [IrmaaTier]]) -> Usd {
        guard medicareCount > 0 else { return 0 }
        // Fall back to the single schedule rather than MFJ: for an unmarried filer the MFJ
        // table silently reports no surcharge where one is actually due.
        let band = tiers[filing] ?? tiers[.single] ?? []
        var monthly: Usd = 0
        for tier in band.sorted(by: { $0.magiOverUsd < $1.magiOverUsd }) where magi > tier.magiOverUsd {
            monthly = tier.monthlySurchargeUsd
        }
        // The surcharge is per enrolled person, but `magi` here is a HOUSEHOLD figure and
        // only the joint schedule is a household schedule. For a single or
        // married-filing-separately return the bands apply to ONE person's income, so
        // multiplying a combined-MAGI surcharge by two adults invented a bill that is not
        // owed: a two-adult MFS household at $150,000 was charged $9,768/yr where the truth
        // is between $0 and $4,884. IRMAA is debited from the portfolio every year, so it
        // moved RMDs, lifetime tax and the chosen Roth-conversion target with it.
        let heads = filing == .mfj ? medicareCount : min(1, medicareCount)
        return monthly * 12 * Double(heads)
    }

    /// The required beginning age for RMDs, which SECURE 2.0 makes a function of BIRTH YEAR,
    /// not a single scalar: 73 for those born 1951–1959, 75 for anyone born 1960 or later.
    /// (Born before 1951 the age was 72 and has already passed.) `tax.rmdStartAge` remains the
    /// seeded default for callers with no birth date.
    static func rmdStartAge(birthDate: IsoDate, default fallback: Int) -> Int {
        // Parse directly rather than via `year(_:)`, which masks a bad date as 2026 and would
        // silently classify a missing birth date into the 1960+ cohort.
        guard let by = Int(birthDate.prefix(4)), by > 1800 else { return fallback }
        if by >= 1960 { return 75 }
        if by >= 1951 { return 73 }
        return 72
    }

    /// IRS Uniform Lifetime Table (2022+) divisor; flat outside the tabulated range.
    static func uniformLifetimeDivisor(_ age: Int) -> Double {
        let t: [Int: Double] = [72: 27.4, 73: 26.5, 74: 25.5, 75: 24.6, 76: 23.7, 77: 22.9, 78: 22.0, 79: 21.1,
                                80: 20.2, 81: 19.4, 82: 18.5, 83: 17.7, 84: 16.8, 85: 16.0, 86: 15.2, 87: 14.4,
                                88: 13.7, 89: 12.9, 90: 12.2, 91: 11.5, 92: 10.8, 93: 10.1, 94: 9.5, 95: 8.9,
                                96: 8.4, 97: 7.8, 98: 7.3, 99: 6.8, 100: 6.4, 101: 6.0, 102: 5.6, 103: 5.2,
                                104: 4.9, 105: 4.6, 106: 4.3, 107: 4.1, 108: 3.9, 109: 3.7, 110: 3.5, 111: 3.4,
                                112: 3.3, 113: 3.1, 114: 3.0, 115: 2.9, 116: 2.8, 117: 2.7, 118: 2.5, 119: 2.3, 120: 2.0]
        if let d = t[age] { return d }
        return age < 72 ? 27.4 : 2.0
    }
}
