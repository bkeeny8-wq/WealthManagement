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
    public var ordinaryIncomeUsd: Usd      // RMD + deferred draws + pension + taxable SS + conversion
    public var capitalGainsUsd: Usd
    public var ssTaxableUsd: Usd
    public var taxableIncomeUsd: Usd       // ordinary taxable income after the standard deduction
    public var federalTaxUsd: Usd
    public var irmaaUsd: Usd
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
        let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
        let planToAge = primaryAge0 + horizon
        let firstAge = max(primaryAge0, primary.expectedRetirementAge)
        guard planToAge >= firstAge else { return .empty }

        // Bucket balances and the taxable account's blended gain fraction.
        var taxable = h.value(in: .taxable)
        var deferred = h.value(in: .taxDeferred)
        var roth = h.value(in: .taxFree)
        let taxablePos = h.positions(in: .taxable)
        let taxableMv = taxablePos.reduce(0) { $0 + $1.marketValueUsd }
        let taxableGainFrac = taxableMv > 0 ? taxablePos.reduce(0) { $0 + max(0, $1.unrealizedGainUsd) } / taxableMv : 0

        // Project the accumulation phase to retirement: compound the current balances at
        // r and add the future value of real annual savings (split by the current bucket
        // mix), so a not-yet-retired household starts retirement on the right balances.
        let accumYears = firstAge - primaryAge0
        if accumYears > 0 {
            let g = pow(1 + r, Double(accumYears))
            taxable *= g; deferred *= g; roth *= g
            let fvSavings = r > 0 ? h.annualSavingsUsd * (g - 1) / r : h.annualSavingsUsd * Double(accumYears)
            let bal = taxable + deferred + roth
            if bal > 0 { taxable += fvSavings * taxable / bal; deferred += fvSavings * deferred / bal; roth += fvSavings * roth / bal }
            else { deferred += fvSavings }
        }

        let startYear = year(asOf)
        let adults = h.people.filter { $0.role != .dependent }
        var years: [DecumulationYear] = []
        var lifetimeTax: Usd = 0, lifetimeIrmaa: Usd = 0, firstRmdAge = 0

        for ageNow in firstAge...planToAge {
            let t = ageNow - primaryAge0                       // plan-year index (years from asOf)
            let ss = socialSecurityAnnual(h, year: t, asOf: asOf)
            let pension = pensionAnnual(h, year: t)
            // RMD: the whole tax-deferred balance divided by the IRS Uniform Lifetime factor.
            let rmd = ageNow >= tax.rmdStartAge ? deferred / uniformLifetimeDivisor(ageNow) : 0
            if rmd > 0 && firstRmdAge == 0 { firstRmdAge = ageNow }
            deferred -= rmd                                    // the RMD leaves the account (as income)

            // Discretionary need beyond guaranteed income and the forced RMD.
            let spend = retirementSpendingOutflow(h, year: t)
            var need = max(0, spend - ss - pension - rmd)
            var wTaxable: Usd = 0, wDeferred: Usd = 0, wRoth: Usd = 0
            if need > 0 { wTaxable = min(taxable, need); taxable -= wTaxable; need -= wTaxable }
            if need > 0 { wDeferred = min(deferred, need); deferred -= wDeferred; need -= wDeferred }
            if need > 0 { wRoth = min(roth, need); roth -= wRoth; need -= wRoth }
            // Forced RMD cash beyond what spending consumed doesn't vanish — it's reinvested taxable.
            taxable += max(0, rmd - max(0, spend - ss - pension))

            // Income and federal tax.
            let capGains = wTaxable * taxableGainFrac
            var ordinaryExSS = rmd + wDeferred + pension
            // Roth conversion: in the pre-RMD window, fill ordinary income up to the top
            // of the target bracket (tax-deferred → Roth, taxed now at the low rate).
            var conversion: Usd = 0
            if let topBps = conversionToBracketTopBps, ageNow < tax.rmdStartAge, deferred > 0 {
                let ceiling = bracketTopTaxable(topBps, filing: filing, tax: tax)
                let ssEst = taxableSocialSecurity(ss: ss, otherIncome: ordinaryExSS + capGains, filing: filing)
                let preTaxable = max(0, ordinaryExSS + ssEst - stdDed)
                conversion = min(max(0, ceiling - preTaxable), deferred)
                deferred -= conversion; roth += conversion; ordinaryExSS += conversion
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
            let irmaa = irmaaAnnual(magi: magi, medicareCount: medicareCount, tiers: tax.irmaaTiers)
            lifetimeTax += federalTax; lifetimeIrmaa += irmaa
            // Conservation: the year's tax is actually paid from the portfolio (taxable → deferred → Roth),
            // so the balances that roll forward — and the RMDs they drive — are genuinely after-tax.
            if debitTax {
                var due = federalTax + irmaa
                let payT = min(taxable, due); taxable -= payT; due -= payT
                let payD = min(deferred, due); deferred -= payD; due -= payD
                roth = max(0, roth - due)
            }

            years.append(DecumulationYear(
                year: startYear + t, age: ageNow, spendingNeedUsd: spend, guaranteedIncomeUsd: ss + pension,
                rmdUsd: rmd, taxableWithdrawalUsd: wTaxable, deferredWithdrawalUsd: wDeferred, rothWithdrawalUsd: wRoth,
                rothConversionUsd: conversion,
                ordinaryIncomeUsd: ordinaryIncome, capitalGainsUsd: capGains, ssTaxableUsd: ssTaxable,
                taxableIncomeUsd: ordinaryTaxable, federalTaxUsd: federalTax, irmaaUsd: irmaa,
                marginalRateBps: marginalOrdinaryRateBps(taxableIncome: ordinaryTaxable, filing: filing, tax: tax),
                magiUsd: magi, endTaxableUsd: taxable, endDeferredUsd: deferred, endRothUsd: roth))

            // Grow the surviving balances into next year.
            taxable *= (1 + r); deferred *= (1 + r); roth *= (1 + r)
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
    static func irmaaAnnual(magi: Usd, medicareCount: Int, tiers: [IrmaaTier]) -> Usd {
        guard medicareCount > 0 else { return 0 }
        var monthly: Usd = 0
        for tier in tiers.sorted(by: { $0.magiOverUsd < $1.magiOverUsd }) where magi > tier.magiOverUsd {
            monthly = tier.monthlySurchargeUsd
        }
        return monthly * 12 * Double(medicareCount)
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
