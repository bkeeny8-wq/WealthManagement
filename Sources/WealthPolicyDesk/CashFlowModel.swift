//  CashFlowModel.swift
//  WealthPolicyDesk
//
//  The CASH-FLOW engine: it DERIVES investable surplus from income, deferrals, tax and
//  today's spending, instead of taking "real savings per year" as a number the client types.
//
//  Pure and deterministic. No clock, no randomness, no IO. Every rate is a dated,
//  verify-labelled snapshot.
//
//  WHAT THIS FILE DOES NOT CONTAIN: a wage schedule. An earlier draft carried its own
//  `WageStep` list, which would have made TWO stepped-income models — this one and
//  `HumanCapital.compensationSchedule` — for one quantity. The waterfall below reads the
//  schedule through `HumanCapital.statedCompUsd(planYear:)`, the same primitive
//  `Engine.wagesAtPlanYear` reads, and `cashFlowWageAgreementUsd` exists so a drift between
//  them is a test failure rather than a discovery.
//
//  Doctrine it must not break: ALLOCATION IS AN OUTPUT. This file feeds the FUNDING side of
//  `requiredReturn` — more surplus lowers the required return, which lowers the risk the plan
//  needs. It never names a sleeve and never sets a target.

import Foundation

// MARK: - Pre-tax payroll deductions

/// Pre-tax payroll deductions, split by what they BECOME.
///
/// The split is the whole point. A 401(k) deferral and a medical premium both reduce taxable
/// wages, but the deferral is SAVINGS — it lands in the portfolio — and the premium is
/// SPENDING, it buys cover and is gone. Lumping them, which is how a paystub presents them and
/// how a client's own spreadsheet carries them as a single pre-tax line, either credits
/// consumed premiums to the corpus or writes off real retirement saving.
public struct PretaxDeductions: Sendable, Hashable {
    /// Elective deferral as a share of BASE salary, so it tracks base rather than needing
    /// re-entry whenever the schedule steps.
    public var retirementBps: Bps
    /// A flat deferral that overrides the rate when > 0 — the client who simply maxes out.
    public var retirementUsdOverride: Usd
    /// HSA contribution, a flat annual amount.
    public var hsaUsd: Usd
    /// Family (rather than self-only) HDHP coverage, which more than doubles the HSA cap.
    public var hsaFamilyCoverage: Bool
    /// Medical / dental / vision / transit — pre-tax and CONSUMED.
    public var benefitPremiumsUsd: Usd
    /// Employer match, as a share of base. Not wages, never taxed here, but it IS saved.
    public var employerMatchBps: Bps
    public init(retirementBps: Bps = 0, retirementUsdOverride: Usd = 0, hsaUsd: Usd = 0,
                hsaFamilyCoverage: Bool = false, benefitPremiumsUsd: Usd = 0,
                employerMatchBps: Bps = 0) {
        self.retirementBps = retirementBps; self.retirementUsdOverride = retirementUsdOverride
        self.hsaUsd = hsaUsd; self.hsaFamilyCoverage = hsaFamilyCoverage
        self.benefitPremiumsUsd = benefitPremiumsUsd; self.employerMatchBps = employerMatchBps
    }
}

/// One earner's payroll mechanics. Deliberately ONLY the mechanics: the wage level comes from
/// that person's `HumanCapital`, so this type cannot contradict the schedule.
///
/// An earner with no entry here is still counted at full wages with default (zero) deductions,
/// which is what keeps `grossWagesUsd` equal to `Engine.wagesAtPlanYear` even on a
/// half-completed intake.
public struct EarnerCashFlow: Identifiable, Sendable, Hashable {
    public var personId: String
    public var deductions: PretaxDeductions
    public var id: String { personId }
    public init(personId: String, deductions: PretaxDeductions = .init()) {
        self.personId = personId; self.deductions = deductions
    }
}

// MARK: - Today's spending

/// Today's spending — the input the app did not have.
///
/// `retirementSpendingUsd` modelled what the household will spend LATER. Nothing modelled what
/// it spends NOW, which is precisely what makes surplus computable: net pay minus today's
/// outlay IS the investable surplus. Fixed is split from variable because the resilience engine
/// needs to know which half is cuttable.
public struct CurrentSpending: Sendable, Hashable {
    public var fixedUsd: Usd
    public var variableUsd: Usd
    /// Real (above-inflation) drift in the household's own outlay. 0 = flat in real terms,
    /// which is the convention the rest of this engine runs on.
    public var realGrowthBps: Bps
    public var totalUsd: Usd { max(0, fixedUsd) + max(0, variableUsd) }
    public init(fixedUsd: Usd = 0, variableUsd: Usd = 0, realGrowthBps: Bps = 0) {
        self.fixedUsd = fixedUsd; self.variableUsd = variableUsd; self.realGrowthBps = realGrowthBps
    }
}

/// How the state leg of wage tax is priced. The honest options, named.
public enum StateWageTaxBasis: Sendable, Hashable {
    /// `StateTaxProfile.incomeRate` applied to post-deferral wages. That field is the state's
    /// TOP MARGINAL rate — its own doc says so, and scopes it to SALT and muni comparisons —
    /// so using it as an EFFECTIVE wage rate OVERSTATES in every graduated state. Carried as
    /// the default only because it is the only state data that exists, and reported as an
    /// estimate by `state_wage_tax_is_estimated` wherever it bites.
    case topMarginalProxy
    /// The rate the advisor read off the client's own return or paystub.
    case manual(Bps)
}

public struct CashFlowProfile: Sendable, Hashable {
    public var earners: [EarnerCashFlow]
    public var spending: CurrentSpending
    public var stateWageTax: StateWageTaxBasis
    /// Replaces the whole computed tax leg with one rate on post-deferral wages — the client's
    /// own "effective 31.8%". Present so the engine can be pinned to the number the client
    /// already believes, and so the gap against the computed figure is visible rather than
    /// argued about.
    public var effectiveTaxRateBpsOverride: Bps?
    /// Count EXPECTED FUTURE equity grants as investable surplus when they vest. Default
    /// false. See `Engine.futureGrantVestingNetInYear` for why this is a separate switch and
    /// not simply added in.
    public var includesFutureEquityGrants: Bool
    public init(earners: [EarnerCashFlow] = [], spending: CurrentSpending = .init(),
                stateWageTax: StateWageTaxBasis = .topMarginalProxy,
                effectiveTaxRateBpsOverride: Bps? = nil,
                includesFutureEquityGrants: Bool = false) {
        self.earners = earners; self.spending = spending; self.stateWageTax = stateWageTax
        self.effectiveTaxRateBpsOverride = effectiveTaxRateBpsOverride
        self.includesFutureEquityGrants = includesFutureEquityGrants
    }
    public func deductions(for personId: String) -> PretaxDeductions {
        earners.first { $0.personId == personId }?.deductions ?? .init()
    }
}

// MARK: - The derived year

/// One plan year of the cash-flow waterfall, every line of it shown rather than netted, so the
/// screen can print the client's own spreadsheet back to them row for row.
public struct CashFlowYear: Sendable, Hashable {
    public var planYear: Int
    public var grossWagesUsd: Usd
    public var retirementDeferralUsd: Usd
    public var hsaDeferralUsd: Usd
    public var benefitPremiumsUsd: Usd
    public var employerMatchUsd: Usd
    public var federalTaxableWagesUsd: Usd
    public var ficaTaxableWagesUsd: Usd
    public var federalIncomeTaxUsd: Usd
    public var payrollTaxUsd: Usd
    public var stateIncomeTaxUsd: Usd
    public var netPayUsd: Usd
    public var spendingUsd: Usd
    /// Net pay minus outlay. NEGATIVE when the household outspends its pay, which is a real
    /// answer and must reach the corpus as a draw rather than be clamped to zero.
    public var leftoverCashUsd: Usd
    /// What actually reaches the portfolio: leftover cash PLUS the deferrals and the match,
    /// which never passed through net pay. A client's spreadsheet stops at `leftoverCashUsd`
    /// and so understates their own saving by exactly the deferrals.
    public var investableSurplusUsd: Usd
    /// Vesting of EXPECTED FUTURE grants, reported separately and added to
    /// `investableSurplusUsd` only when the profile opts in.
    public var futureEquityVestingUsd: Usd
    public var totalTaxUsd: Usd { federalIncomeTaxUsd + payrollTaxUsd + stateIncomeTaxUsd }
    /// Tax over post-deferral wages — the "effective rate" a paystub spreadsheet means.
    public var effectiveTaxRateBps: Bps {
        let denom = grossWagesUsd - retirementDeferralUsd - hsaDeferralUsd - benefitPremiumsUsd
        return denom > 0 ? (totalTaxUsd / denom).bps : 0
    }
}

// MARK: - Payroll tax parameters (dated snapshot — VERIFY)

/// Social Security and Medicare, kept DISTINCT from income tax.
///
/// They are a different tax on a different base with a different cap, and conflating them is
/// how an effective-rate guess goes wrong in both directions at once: OASDI stops at the wage
/// base, so a high earner's marginal payroll rate falls; Medicare never stops; and the
/// additional Medicare surtax has its own threshold that is not indexed. A 401(k) elective
/// deferral reduces income-taxable wages but NOT FICA wages, while §125 premiums and a
/// cafeteria-plan HSA reduce both.
public struct PayrollTaxParameters: Sendable, Hashable {
    public var socialSecurityWageBaseUsd: Usd
    public var socialSecurityRateBps: Bps
    public var medicareRateBps: Bps
    public var additionalMedicareRateBps: Bps
    /// Un-indexed since 2013, and NOT the NIIT threshold despite the coincidence at
    /// $200,000/$250,000 — one is on wages, the other on investment income.
    public var additionalMedicareThresholdUsd: [FilingStatus: Usd]
    public init(socialSecurityWageBaseUsd: Usd, socialSecurityRateBps: Bps, medicareRateBps: Bps,
                additionalMedicareRateBps: Bps, additionalMedicareThresholdUsd: [FilingStatus: Usd]) {
        self.socialSecurityWageBaseUsd = socialSecurityWageBaseUsd
        self.socialSecurityRateBps = socialSecurityRateBps
        self.medicareRateBps = medicareRateBps
        self.additionalMedicareRateBps = additionalMedicareRateBps
        self.additionalMedicareThresholdUsd = additionalMedicareThresholdUsd
    }
}

/// Dated caps on the pre-tax deferrals. Law, so it belongs beside the brackets.
public struct DeferralLimits: Sendable, Hashable {
    public var elective401kUsd: Usd
    public var catchUp50Usd: Usd
    public var hsaSelfOnlyUsd: Usd
    public var hsaFamilyUsd: Usd
    public var hsaCatchUp55Usd: Usd
    public init(elective401kUsd: Usd, catchUp50Usd: Usd, hsaSelfOnlyUsd: Usd,
                hsaFamilyUsd: Usd, hsaCatchUp55Usd: Usd) {
        self.elective401kUsd = elective401kUsd; self.catchUp50Usd = catchUp50Usd
        self.hsaSelfOnlyUsd = hsaSelfOnlyUsd; self.hsaFamilyUsd = hsaFamilyUsd
        self.hsaCatchUp55Usd = hsaCatchUp55Usd
    }
}

public extension Seed {
    /// FICA, 2026 (VERIFY — the wage base is indexed annually and the 2026 figure is an
    /// estimate until SSA publishes it).
    static let payroll2026 = PayrollTaxParameters(
        socialSecurityWageBaseUsd: 183_600, socialSecurityRateBps: 620,
        medicareRateBps: 145, additionalMedicareRateBps: 90,
        additionalMedicareThresholdUsd: [.single: 200_000, .mfj: 250_000, .mfs: 125_000, .hoh: 200_000])

    /// Elective-deferral and HSA caps, 2026 (VERIFY).
    static let deferralLimits2026 = DeferralLimits(
        elective401kUsd: 24_500, catchUp50Usd: 8_000,
        hsaSelfOnlyUsd: 4_400, hsaFamilyUsd: 8_750, hsaCatchUp55Usd: 1_000)

    /// Long-run REAL potential-GDP growth — the anchor available for wage growth.
    ///
    /// Deliberately the TREND, not the current print. The macro board's GDP row is a
    /// cycle-lean input that swings with the quarter; wiring a plan's lifetime income growth to
    /// it would let the business cycle re-cut a household's career on every refresh, which is a
    /// forecast entering through the back door. Dated snapshot to VERIFY.
    ///
    /// Nothing uses this unless an earner's `gdpTrendPremiumBps` is set, so it cannot move an
    /// existing household's numbers by sitting here.
    static let gdpTrendRealGrowthBps: Bps = 180
    static let gdpTrendAsOf: IsoDate = "2026-01-01"
    static let gdpTrendSource = "CBO potential real GDP growth, 10-yr projection (verify)"
}

// MARK: - Tax primitives

public extension Engine {
    /// Payroll (FICA) tax on ONE earner's wages. Per earner, never on a household total: the
    /// Social Security wage base is a PER-PERSON cap, so summing two spouses' wages and
    /// capping once understates OASDI for a two-earner couple.
    ///
    /// `ficaWages` is gross wages less only the deductions that reduce the FICA base (§125
    /// premiums, cafeteria-plan HSA) — NOT 401(k) elective deferrals, which are FICA-taxable.
    static func payrollTax(ficaWages: Usd, filing: FilingStatus,
                           payroll: PayrollTaxParameters = Seed.payroll2026) -> Usd {
        let w = max(0, ficaWages)
        let oasdi = min(w, payroll.socialSecurityWageBaseUsd) * payroll.socialSecurityRateBps.frac
        let medicare = w * payroll.medicareRateBps.frac
        let threshold = payroll.additionalMedicareThresholdUsd[filing] ?? 200_000
        let surtax = max(0, w - threshold) * payroll.additionalMedicareRateBps.frac
        return oasdi + medicare + surtax
    }

    /// Federal income tax on WAGES alone — the ordinary brackets applied to post-deferral wages
    /// less the standard deduction.
    ///
    /// A separate entry point from `capitalGainsTax` on purpose: that one is documented
    /// federal-only and prices a realized GAIN stacked on ordinary income. This prices the
    /// ordinary income itself. Both walk `progressiveTax`, which is the one bracket walker.
    static func federalWageTax(federalTaxableWages: Usd, otherOrdinaryUsd: Usd = 0,
                               filing: FilingStatus, tax: TaxParameterSet = Seed.tax2026) -> Usd {
        let stdDed = tax.standardDeduction[filing] ?? 0
        let taxable = max(0, max(0, federalTaxableWages) + max(0, otherOrdinaryUsd) - stdDed)
        return progressiveTax(taxable, brackets: tax.ordinaryBrackets[filing] ?? [])
    }
}

// MARK: - The engine

public enum CashFlow {

    /// The state wage rate actually applied, and whether it is the overstating proxy.
    static func stateWageRate(_ h: Household, _ cf: CashFlowProfile) -> (bps: Bps, isProxy: Bool) {
        switch cf.stateWageTax {
        case .manual(let bps): return (max(0, bps), false)
        case .topMarginalProxy:
            return (Seed.stateTaxProfile(for: h.stateOfResidence).incomeRate.bps, true)
        }
    }

    /// The waterfall for plan year `t`.
    ///
    /// Two rules hold this to the rest of the engine, and both are asserted rather than
    /// described:
    ///
    ///  • WHO EARNS is `Engine.wagesAtPlanYear`'s rule exactly — dependents never earn, and an
    ///    adult stops the year they reach their expected retirement age — so the cash-flow
    ///    engine and the required-return recursion cannot disagree about who is working.
    ///  • HOW MUCH is `HumanCapital.statedCompUsd(planYear:)`, STATED and flat in real terms,
    ///    not the grown `projectedIncomeUsd`. Flat is the convention the corpus recursion and
    ///    the savings cap have always used; applying real growth here while
    ///    `wagesAtPlanYear` stayed flat would make the surplus and the tax base describe
    ///    different incomes in the same year. Real wage growth belongs to the human-capital
    ///    PV, which is where `HumanCapital.effectiveRealGrowthBps` is read.
    public static func year(_ h: Household, _ cf: CashFlowProfile, year t: Int, asOf: IsoDate,
                            tax: TaxParameterSet = Seed.tax2026,
                            payroll: PayrollTaxParameters = Seed.payroll2026,
                            limits: DeferralLimits = Seed.deferralLimits2026) -> CashFlowYear {
        var gross: Usd = 0, retDef: Usd = 0, hsa: Usd = 0, prem: Usd = 0, match: Usd = 0
        var fedTaxableWages: Usd = 0, ficaWagesTotal: Usd = 0, payrollTotal: Usd = 0

        for p in h.people where p.role != .dependent {
            let age = Engine.age(birthDate: p.birthDate, asOf: asOf)
            guard age + t < p.expectedRetirementAge else { continue }
            guard let hc = h.humanCapital.first(where: { $0.personId == p.id }) else { continue }
            let c = hc.statedCompUsd(planYear: t)
            let base = max(0, c.salary)
            let w = max(0, c.salary + c.cashBonus)

            let d = cf.deductions(for: p.id)
            let rawRet = d.retirementUsdOverride > 0 ? d.retirementUsdOverride : base * d.retirementBps.frac
            let cap = limits.elective401kUsd + (age + t >= 50 ? limits.catchUp50Usd : 0)
            let ret = min(max(0, rawRet), min(cap, w))
            let hsaCap = (d.hsaFamilyCoverage ? limits.hsaFamilyUsd : limits.hsaSelfOnlyUsd)
                + (age + t >= 55 ? limits.hsaCatchUp55Usd : 0)
            let hsaAmt = min(max(0, d.hsaUsd), hsaCap)
            let premAmt = max(0, d.benefitPremiumsUsd)

            // §125 premiums and a cafeteria-plan HSA cut the FICA base; a 401(k) elective
            // deferral does NOT. Modelling them as one pre-tax block understates payroll tax by
            // the MARGINAL payroll rate on the deferral — which is 7.65% only below the OASDI
            // wage base, 1.45% between the base and the additional-Medicare threshold, and
            // 2.35% above it. The case-study earner is in the top band, so a 6% deferral off
            // $225,000 costs $317 rather than the $1,033 the flat-rate reading gives. That
            // three-fold spread, over one deduction, is why this is three parameters and not a
            // rate.
            let ficaWages = max(0, w - hsaAmt - premAmt)
            payrollTotal += Engine.payrollTax(ficaWages: ficaWages, filing: h.filingStatus, payroll: payroll)

            gross += w; retDef += ret; hsa += hsaAmt; prem += premAmt
            match += base * max(0, d.employerMatchBps).frac
            fedTaxableWages += max(0, w - ret - hsaAmt - premAmt)
            ficaWagesTotal += ficaWages
        }

        // Tax. One override replaces the whole computed leg (the client's own effective rate);
        // otherwise federal income tax + payroll + the state estimate.
        let fedTax: Usd, stateTax: Usd, payrollOut: Usd
        if let bps = cf.effectiveTaxRateBpsOverride {
            fedTax = fedTaxableWages * max(0, bps).frac
            stateTax = 0; payrollOut = 0
        } else {
            fedTax = Engine.federalWageTax(federalTaxableWages: fedTaxableWages,
                                           filing: h.filingStatus, tax: tax)
            payrollOut = payrollTotal
            stateTax = fedTaxableWages * stateWageRate(h, cf).bps.frac
        }

        let spendFactor = pow(1 + max(0, cf.spending.realGrowthBps).frac, Double(max(0, t)))
        let spend = cf.spending.totalUsd * spendFactor
        let netPay = gross - retDef - hsa - prem - (fedTax + payrollOut + stateTax)
        let leftover = netPay - spend
        let futureVest = Engine.futureGrantVestingNetInYear(h, year: t, asOf: asOf)
        let surplus = leftover + retDef + hsa + match + (cf.includesFutureEquityGrants ? futureVest : 0)

        return CashFlowYear(
            planYear: t, grossWagesUsd: gross, retirementDeferralUsd: retDef, hsaDeferralUsd: hsa,
            benefitPremiumsUsd: prem, employerMatchUsd: match,
            federalTaxableWagesUsd: fedTaxableWages, ficaTaxableWagesUsd: ficaWagesTotal,
            federalIncomeTaxUsd: fedTax, payrollTaxUsd: payrollOut, stateIncomeTaxUsd: stateTax,
            netPayUsd: netPay, spendingUsd: spend, leftoverCashUsd: leftover,
            investableSurplusUsd: surplus, futureEquityVestingUsd: futureVest)
    }
}

// MARK: - Keeping wage income and vesting income distinct

public extension Engine {
    /// Vesting of grants the employer has NOT yet made — the `isExpectedFuture` ladder.
    ///
    /// `vestingNetInYear` sums EVERY grant, awarded and expected alike, which is right for
    /// "what converts this year" and wrong for "what new money arrives". An ALREADY-AWARDED
    /// grant is on the balance sheet today, at net, inside `assets.unvestedCompUsd`: when its
    /// tranche converts the household is no richer, the value merely moves from the unvested
    /// line into the portfolio. Crediting it as cash-flow income counts the same units twice,
    /// once as net worth and once as income.
    ///
    /// Expected FUTURE grants are the opposite. `deferredCompNetUsd` and `unvestedNetUsd` both
    /// filter them OUT of the balance sheet precisely because they are compensation, not
    /// property. They are therefore the only vesting that is new money, and the only vesting
    /// the cash-flow engine may add.
    ///
    /// The mirror hazard is cash comp: a bonus paid half in stock must be entered as cash in
    /// `CompensationYear.cashBonusUsd` and as stock in the grant ladder, never both.
    static func futureGrantVestingNetInYear(_ h: Household, year t: Int, asOf: IsoDate) -> Usd {
        let base = year(asOf)
        return h.deferredComp.filter(\.isExpectedFuture).reduce(0) { acc, g in
            let keep = 1 - min(1, max(0, g.withholdingBps.frac))
            return acc + g.vesting.filter { year($0.date) == base + t }
                .reduce(0) { $0 + $1.grossUsd * keep }
        }
    }

    /// Total compensation booked in plan year `t`, by channel, so the three can be reconciled
    /// on one screen and in one test.
    static func compensationChannels(_ h: Household, year t: Int, asOf: IsoDate)
        -> (cashWages: Usd, awardedVesting: Usd, futureGrantVesting: Usd) {
        let future = futureGrantVestingNetInYear(h, year: t, asOf: asOf)
        return (wagesAtPlanYear(h, year: t, asOf: asOf),
                vestingNetInYear(h, year: t, asOf: asOf) - future,
                future)
    }

    /// The gap between the cash-flow engine's gross wages and `wagesAtPlanYear` in plan year
    /// `t`. Structurally zero — both read the same schedule under the same retirement gate —
    /// and exposed so that a future edit which re-introduces a second wage path fails a test
    /// instead of quietly splitting the plan in two.
    static func cashFlowWageAgreementUsd(_ h: Household, year t: Int, asOf: IsoDate) -> Usd {
        guard let cf = h.cashFlow else { return 0 }
        return CashFlow.year(h, cf, year: t, asOf: asOf).grossWagesUsd
            - wagesAtPlanYear(h, year: t, asOf: asOf)
    }

    /// The ONE investable-surplus term. Every site that used to write its own copy of
    /// `min(h.annualSavingsUsd, wagesAtPlanYear(...))` reads this instead.
    ///
    /// With no cash-flow profile it IS that expression, term for term, so every saved record
    /// and every fixture that states a savings number keeps its plan unchanged. With one, the
    /// figure is derived and the wage cap is structural rather than a clamp: surplus comes out
    /// of net pay, which is already inside gross wages.
    static func investableSurplusAtPlanYear(_ h: Household, year t: Int, asOf: IsoDate) -> Usd {
        guard let cf = h.cashFlow else {
            return min(h.annualSavingsUsd, wagesAtPlanYear(h, year: t, asOf: asOf))
        }
        return CashFlow.year(h, cf, year: t, asOf: asOf).investableSurplusUsd
    }
}
