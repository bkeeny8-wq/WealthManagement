//  Engine.swift
//  WealthPolicyDesk
//
//  The evaluation engine — the pure functions the TypeScript policy layer only
//  DECLARED (validateTacticalTilts, resolveTargets, analyzeItemization,
//  recommendDisposition, partitionByLayer, …) plus the implied engines it
//  described (required return, the balance-sheet view, cross-module constraint
//  evaluation). Everything here is a pure function of (household, policy, tax,
//  asOf) — no I/O, no clock, no randomness — so a delivered plan reproduces.
//
//  These are teaching-grade models, not a certified financial planner. Several
//  use deliberately simple, documented approximations (a constant-real-return
//  funding recursion, straight-line PVs). The point is to make the policy
//  layer's BELIEFS computable and visible, not to price a plan to the dollar.

import Foundation

// MARK: - Result types produced by the engine

public struct YearBalance: Identifiable, Sendable, Hashable {
    public var year: Int
    public var balanceUsd: Usd
    public var id: Int { year }
}

public struct RequiredReturn: Sendable, Hashable {
    public var currentAssetsUsd: Usd
    public var externalIncomePvUsd: Usd
    public var futureSavingsPvUsd: Usd
    public var liabilityPvUsd: Usd
    public var netLiabilityPvUsd: Usd
    /// The anchor. Reported FIRST — before any capital-market assumption.
    public var requiredRealReturnBps: Bps
    /// After flexing every flexible goal to its most conservative setting.
    public var requiredRealReturnWithFlexibilityBps: Bps
    public var fundedRatioBps: Bps
    public var projection: [YearBalance]
    public var safeRealRateBps: Bps
    /// Terminal-wealth floor (today's $) the corpus must end at. 0 = spend-down.
    public var legacyFloorUsd: Usd
    /// The required return with the legacy floor set to 0 — the spend-down
    /// baseline. The gap to requiredRealReturnBps is the cost of the legacy claim.
    public var spendDownRealReturnBps: Bps
    /// The required return BEFORE decumulation taxes. requiredRealReturnBps is now
    /// AFTER-TAX (it also funds the tax on withdrawals); the gap here is the tax drag.
    public var requiredRealReturnPreTaxBps: Bps = 0
}

public struct AllocationRow: Identifiable, Sendable, Hashable {
    public enum Status: String, Sendable, Hashable { case within, innerBreach, outerBreach }
    public var sleeveId: String
    public var label: String
    public var tier: SleeveTier
    public var targetBps: Bps              // tactical target (strategic ± committed tilts)
    public var strategicTargetBps: Bps = 0 // the forecast-free target before tilts
    public var currentBps: Bps
    public var driftBps: Bps
    public var innerBandBps: Bps
    public var outerBandBps: Bps
    public var status: Status
    public var id: String { sleeveId }
}

public struct AltSizingRow: Identifiable, Sendable, Hashable {
    public var fn: AltFunction
    public var targetBps: Bps
    public var currentBps: Bps
    public var chosenWrapperId: String?
    public var chosenWrapperLabel: String
    public var eligible: Bool
    public var fallbackSleeveId: String
    public var wrapperFeeBps: Bps
    public var feeOverBudget: Bool
    public var id: String { fn.rawValue }
}

public enum FindingModule: String, CaseIterable, Sendable, Hashable {
    case policy = "Policy", household = "Household", fixedIncome = "Fixed income & liabilities"
    case disposition = "Disposition", layer = "Layer separation", tilt = "Tactical tilts"
    case planning = "Planning surface", tax = "Tax"
}

public struct Finding: Identifiable, Sendable, Hashable {
    public var ruleId: String
    public var module: FindingModule
    public var severity: Severity
    public var title: String
    public var detail: String
    /// Per-instance discriminator (e.g. a ticker) so two positions tripping the
    /// same ruleId get distinct Identifiable ids. ruleId stays stable for
    /// pass/fail matching.
    public var key: String = ""
    /// Rough dollars at stake, used to rank the advice surface by materiality
    /// (0 = not a dollar-denominated finding; those sort last within a severity).
    public var magnitudeUsd: Usd = 0
    public var id: String { module.rawValue + ":" + ruleId + (key.isEmpty ? "" : ":" + key) }
    public init(ruleId: String, module: FindingModule, severity: Severity, key: String = "", title: String, detail: String, magnitudeUsd: Usd = 0) {
        self.ruleId = ruleId; self.module = module; self.severity = severity
        self.key = key; self.title = title; self.detail = detail; self.magnitudeUsd = magnitudeUsd
    }
}

public struct LadderPlan: Sendable, Hashable {
    public var yearsCovered: Int
    public var netAnnualOutflowUsd: Usd
    public var ladderSizeUsd: Usd
    public var rebalanceReserveUsd: Usd
    public var twelveMonthFloorUsd: Usd
    public var requiredLiquidUsd: Usd
    /// Cash + fixed income. NOT every position: funding near-term spending out of
    /// equities is precisely the sequence risk the ladder exists to avoid.
    public var availableDefensiveUsd: Usd
    public var covered: Bool
}

/// Everything the desk needs for one household, in one pass.
public struct Evaluation: Sendable {
    public var household: Household
    public var policy: InvestmentPolicy        // the spending/glide policy
    public var legacyPolicy: InvestmentPolicy
    public var tax: TaxParameterSet
    public var asOf: IsoDate
    public var balanceSheet: BalanceSheetView
    public var requiredReturn: RequiredReturn
    public var allocation: [AllocationRow]
    public var altSizing: [AltSizingRow]
    public var findings: [Finding]
    public var itemization: ItemizationAnalysis
    public var dispositions: [DispositionDecision]
    public var ladder: LadderPlan
    public var muni: MuniCrossover
    public var paydowns: [PaydownAnalysis]
    public var deferredTaxTotalUsd: Usd
    public var netFixedIncomeUsd: Usd
    public var riskProfile: RiskProfile?
    public var decumulation: RothStrategy
    public var resilience: ResilienceAnalysis
}

// MARK: - The engine namespace

public enum Engine {

    // Tickers the engine treats as fixed income (sleeve mapping is the primary
    // signal; this catches unclassified legacy holdings).
    static let fiTickers: Set<String> = ["BND", "MUB", "SCHP", "AGG", "TLT", "BIL", "VTIP", "GOVT", "HYG", "JNK", "EMB", "SGOV"]
    static let muniTickers: Set<String> = ["MUB", "VTEB", "TFI"]
    static let commodityTickers: Set<String> = ["DBC", "GLD", "IAU", "PDBC"]

    // Reference safe real rate (TIPS-like), used for funded ratio and PVs. An
    // OBSERVABLE, not a capital-market forecast — the README's distinction.
    static let safeRealRate = 0.015
    static let humanCapitalDiscount = 0.03

    /// Portfolio friction the CME reconciliation nets off the GROSS expected real return
    /// so it compares apples-to-apples with the AFTER-TAX required return. Fund fees hit
    /// EVERY dollar; the annual investment-tax drag (dividends + rebalancing) hits only
    /// TAXABLE accounts — so it is a flat fee term plus a tax-drag term scaled by the
    /// taxable share of the book. An all-IRA retiree pays only the fee term; an all-taxable
    /// book the full drag. Labeled dials to VERIFY. (The alt sleeves' CMEs are already net
    /// of their own fees.) On the Harrisons (~57% taxable) this lands ≈41bp, near the old
    /// flat 40; the point is it now MOVES with account location instead of over-charging
    /// a sheltered book enough to flip the funded verdict.
    static let fundFeeDragBps: Bps = 12          // blended liquid-fund expense ratios
    static let taxableTaxDragBps: Bps = 50       // annual dividend + rebalancing tax if 100% taxable
    static func cmeFrictionDragBps(_ h: Household) -> Bps {
        let total = h.value(in: .taxable) + h.value(in: .taxDeferred) + h.value(in: .taxFree)
        let taxableShare = total > 0 ? h.value(in: .taxable) / total : 0
        return fundFeeDragBps + Int((Double(taxableTaxDragBps) * taxableShare).rounded())
    }

    // MARK: dates

    public static func year(_ iso: IsoDate) -> Int { Int(iso.prefix(4)) ?? 2026 }
    public static func age(birthDate: IsoDate, asOf: IsoDate) -> Int { max(0, year(asOf) - year(birthDate)) }

    // MARK: top-level entry point

    public static func evaluate(_ input: Household, asOf: IsoDate = Engine.planningAsOf) -> Evaluation {
        // For a couple, step retirement spending down to the survivor share after the first
        // death. Applied once here so every downstream read (required return, funded ratio,
        // decumulation, and the IPS display) sees one consistent schedule.
        let h = input.withSurvivorSpending(asOf: asOf)
        let tax = Seed.tax2026
        let policy = Seed.policy(h.goals.first { $0.kind == .spending }?.policyId ?? "spending-glide")
        // Two-pass, after-tax required return: solve pre-tax, project the decumulation tax
        // at that return, then re-solve so the corpus also funds those taxes.
        let rrPre = requiredReturn(h, asOf: asOf)
        let baseDecum = decumulation(h, tax: tax, rr: rrPre, asOf: asOf)
        let y0 = year(asOf)
        var taxByYear: [Int: Usd] = [:]
        for yr in baseDecum.years { taxByYear[yr.year - y0] = yr.federalTaxUsd + yr.irmaaUsd }
        var rr = requiredReturn(h, asOf: asOf, annualTaxUsd: taxByYear)
        rr.requiredRealReturnPreTaxBps = rrPre.requiredRealReturnBps
        let bs = balanceSheet(h, tax: tax, asOf: asOf, rr: rr)
        let lad = ladder(h, policy: policy, asOf: asOf)
        let risk = riskProfile(h, fundedRatioBps: bs.fundedRatioBps, ladder: lad)
        // Allocation is an OUTPUT: derive the sleeve targets from this household's
        // funded ratio, its risk ceiling, and its liability-sized bond floor —
        // then everything downstream reads the derived policy, not a fixed seed.
        let baseGrowth = Seed.legacyPolicy.sleeves.filter { $0.role == .growth }.reduce(0) { $0 + $1.targetBps }
        let derivedPolicy = resolveTargets(h, base: Seed.legacyPolicy, fundedRatioBps: bs.fundedRatioBps,
                                           equityCeilingBps: risk?.bindingEquityBps ?? baseGrowth, ladder: lad)
        // Tactical layer: the sentiment-sourced tilts deviate the strategic target
        // within budget (funded within-role), producing the tactical target. Drifts
        // and downstream reads track the tactical target; the strategic is kept.
        let tacticalPolicy = applyTacticalTilts(derivedPolicy, tilts: h.tacticalTilts)
        let alloc = resolveAllocation(h, policy: tacticalPolicy, strategic: derivedPolicy)
        let alts = resolveAltSizing(h, policy: derivedPolicy)
        let item = analyzeItemization(itemizationInput(for: h, asOf: asOf), tax: tax)
        let disp = dispositions(h, tax: tax)
        let mc = muniCrossover(h, tax: tax, muniYieldBps: 340, treasuryYieldBps: 430, corporateYieldBps: 520)
        let pays = h.liabilities.filter { $0.isFixedIncomeOffset }.map { paydown($0, household: h, tax: tax) }
        let decum = rothStrategy(h, tax: tax, rr: rr, asOf: asOf)
        let findings = evaluateConstraints(h, policy: derivedPolicy, tax: tax, asOf: asOf,
                                           balanceSheet: bs, allocation: alloc, altSizing: alts, ladder: lad,
                                           rothTaxSavedUsd: decum.lifetimeTaxSavedUsd)
        let resil = resilience(h, tax: tax, rr: rr, asOf: asOf, policy: derivedPolicy, annualTaxUsd: taxByYear)
        return Evaluation(household: h, policy: policy, legacyPolicy: derivedPolicy, tax: tax, asOf: asOf,
                          balanceSheet: bs, requiredReturn: rr, allocation: alloc, altSizing: alts,
                          findings: findings, itemization: item, dispositions: disp, ladder: lad, muni: mc,
                          paydowns: pays, deferredTaxTotalUsd: bs.liabilities.deferredTaxUsd,
                          netFixedIncomeUsd: bs.netFixedIncomeUsd, riskProfile: risk, decumulation: decum, resilience: resil)
    }

    // MARK: - Risk profile (capacity vs tolerance, bind to the lower)

    /// Risk CAPACITY is derived (horizon + income character + funded status);
    /// TOLERANCE is the household's stated (behavior-tempered) drawdown limit.
    /// The plan binds to the lower of the two — the planning-layer belief.
    /// Risk CAPACITY (equity ceiling in bps): what the SITUATION can afford —
    /// horizon + income character + a funded-status penalty. Independent of the
    /// household's stated tolerance, so a risk spectrum can vary tolerance against it.
    public static func riskCapacityBps(_ h: Household, fundedRatioBps: Bps) -> Bps {
        let horizon = h.goals.compactMap { $0.horizonYears }.max() ?? 20
        var cap = 3000 + min(horizon, 30) * 150
        switch h.humanCapital.first?.character {
        case .bondLike: cap += 1500          // stable income → carry more equity
        case .moderate: cap += 500
        case .equityLike: cap -= 300
        case .leveredEquity: cap -= 1200
        case .none: break
        }
        if fundedRatioBps < 8000 { cap -= 500 }   // underfunded → less room for error
        return max(2000, min(9500, cap))
    }

    /// The equity ceiling a stated max-drawdown tolerance implies — read off the
    /// FRONTIER (the highest-equity portfolio the solver would build whose modeled
    /// drawdown stays within the limit), not the old flat 2× rule. Diversification-
    /// aware: the "defensive" sleeves carry real credit/commodity/alt risk, so this
    /// is usually more conservative than 2×. Uses volatilities/correlations only —
    /// the strategic target stays free of return forecasts.
    public static func riskProfile(_ h: Household, fundedRatioBps: Bps, ladder: LadderPlan) -> RiskProfile? {
        guard h.statedToleranceMaxDrawdownBps > 0 else { return nil }
        let cap = riskCapacityBps(h, fundedRatioBps: fundedRatioBps)
        let tol = toleranceEquityBps(h, ladder: ladder, maxDrawdownBps: h.statedToleranceMaxDrawdownBps)
        let binding = min(cap, tol)
        return RiskProfile(capacityEquityBps: cap, toleranceImpliedEquityBps: tol,
                           bindingEquityBps: binding, gapBps: abs(cap - tol), bindingIsCapacity: cap <= tol)
    }

    // MARK: - Tax rate helpers

    /// Marginal ordinary rate at a given taxable income, in bps.
    public static func marginalOrdinaryRateBps(taxableIncome: Usd, filing: FilingStatus, tax: TaxParameterSet) -> Bps {
        let brackets = tax.ordinaryBrackets[filing] ?? []
        for row in brackets {
            if let up = row.upToUsd { if taxableIncome <= up { return row.rateBps } } else { return row.rateBps }
        }
        return brackets.last?.rateBps ?? 0
    }

    /// Marginal long-term capital gains rate at a given total taxable income.
    public static func marginalLtcgRateBps(taxableIncome: Usd, filing: FilingStatus, tax: TaxParameterSet) -> Bps {
        let bp = tax.ltcgBreakpoints[filing] ?? []
        for row in bp {
            if let up = row.upToUsd { if taxableIncome <= up { return row.rateBps } } else { return row.rateBps }
        }
        return bp.last?.rateBps ?? 1500
    }

    // MARK: - Couples economics (savings window + survivor spending)

    /// A survivor spends less than a couple — retirement spending steps down after the
    /// first death to this share of the joint budget (a common planning assumption; VERIFY).
    public static let survivorSpendingFactor: Double = 0.75

    /// Years the household keeps saving — until the LATER of the two adults' retirements
    /// (a couple keeps saving while EITHER still earns), not just the primary's.
    public static func householdSaveYears(_ h: Household, asOf: IsoDate) -> Int {
        let adults = h.people.filter { $0.role == .primary || $0.role == .spouse }
        return adults.map { max(0, $0.expectedRetirementAge - age(birthDate: $0.birthDate, asOf: asOf)) }.max() ?? 0
    }

    // MARK: - Required return (pure arithmetic, no CMAs)

    /// `annualTaxUsd` (plan-year t → projected federal tax + IRMAA) makes the recursion
    /// AFTER-TAX: the corpus must fund spending PLUS the tax the withdrawals generate.
    /// Empty ⇒ the pre-tax number.
    public static func requiredReturn(_ h: Household, asOf: IsoDate, annualTaxUsd: [Int: Usd] = [:]) -> RequiredReturn {
        let A = h.portfolioValueUsd
        let saveYears = householdSaveYears(h, asOf: asOf)
        let horizon = max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30)
        // A primary already at/past retirement is drawing down THIS year, and the
        // decumulation feeder keys that current-year tax at t=0. Fund year 0 too, so it
        // isn't silently dropped. An accumulator has no year-0 outflow, so the frame is
        // unchanged for them (and savings are never added at t=0 — see below).
        let primaryRetiredNow = h.primary.map { age(birthDate: $0.birthDate, asOf: asOf) >= $0.expectedRetirementAge } ?? false
        let startT = primaryRetiredNow ? 0 : 1

        // Real cashflows by year, net of external income, plus the decumulation tax.
        // KNOWN APPROXIMATION (couples with staggered retirement): `annualTaxUsd` is keyed
        // to the primary's drawdown frame, while savings run to the LATER retirement
        // (householdSaveYears). In an overlap year (primary retired, spouse still earning)
        // both a savings inflow and a decumulation tax are booked; the tax slightly
        // overstates the true withdrawal because it ignores the still-earning spouse's
        // wages. Bounded to ≈ the tax on one household's overlap wages — small, and left as
        // a deliberate simplification until decumulation models overlap-year wages.
        func netOutflow(_ t: Int, deferYears: Int, scaleDownBps: Bps) -> Usd {
            var out: Usd = annualTaxUsd[t] ?? 0
            for g in h.goals where g.kind == .spending || g.kind == .reserve {
                let excess = g.inflationSeries.realExcessBps.frac
                let scale = g.kind == .spending ? (1.0 - scaleDownBps.frac) : 1.0
                let shift = g.kind == .spending ? deferYears : 0
                for o in g.outflows where (o.year + shift) == t {
                    let esc = o.inflationLinked ? pow(1.0 + excess, Double(max(0, t - 1))) : 1.0
                    out += o.amountUsd * scale * esc
                }
            }
            // External income offsets. Savings occur in working years 1…saveYears — never
            // year 0 (today's draw), so a retired household never books a phantom saving.
            var inflow: Usd = 0
            if t >= 1 && t <= saveYears { inflow += h.annualSavingsUsd }
            inflow += socialSecurityAnnual(h, year: t, asOf: asOf)
            inflow += pensionAnnual(h, year: t)
            inflow += homeEquityOffset(h, year: t)
            return out - inflow
        }

        // Corpus recursion terminal balance at rate r.
        func terminal(_ r: Double, deferYears: Int, scaleDownBps: Bps) -> Usd {
            // A retiree's current-year draw comes straight off the top — no growth year
            // precedes today's spending — so subtract year 0 before compounding begins.
            var b = A
            if startT == 0 { b -= netOutflow(0, deferYears: deferYears, scaleDownBps: scaleDownBps) }
            // Extend the horizon by the deferral so shifted outflows are still
            // funded at their later years rather than silently dropped.
            for t in 1...(horizon + deferYears) {
                b = b * (1 + r) - netOutflow(t, deferYears: deferYears, scaleDownBps: scaleDownBps)
            }
            return b
        }

        // Solve for r making the corpus END at the legacy floor (in today's $).
        // A floor of 0 is a pure spend-down; a positive floor prices the
        // perpetual legacy claim and raises the required return.
        let legacyFloor = max(0, h.legacyFloorUsd)
        func solve(deferYears: Int, scaleDownBps: Bps, floor: Usd) -> Double {
            var lo = -0.05, hi = 0.20
            // If even 20% real can't reach the floor, cap; if 0% overshoots it, floor.
            if terminal(hi, deferYears: deferYears, scaleDownBps: scaleDownBps) < floor { return hi }
            if terminal(lo, deferYears: deferYears, scaleDownBps: scaleDownBps) > floor { return lo }
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                if terminal(mid, deferYears: deferYears, scaleDownBps: scaleDownBps) > floor { hi = mid } else { lo = mid }
            }
            return (lo + hi) / 2
        }

        let r = solve(deferYears: 0, scaleDownBps: 0, floor: legacyFloor)
        let rSpendDown = solve(deferYears: 0, scaleDownBps: 0, floor: 0)
        let deferMax = h.goals.filter { $0.kind == .spending }.map { $0.flexibility.deferrableYears }.max() ?? 0
        let scaleMax = h.goals.filter { $0.kind == .spending }.map { $0.flexibility.scalableDownBps }.max() ?? 0
        // KNOWN APPROXIMATION: the flexibility solve shifts spending later (deferYears) but
        // reuses `annualTaxUsd` from the NON-deferred decumulation, so spending pushed past
        // the original horizon carries no withdrawal tax — the flex number is slightly
        // optimistic. It is a secondary, advisory figure ("flexibility would ease the
        // requirement to X"); re-projecting the decumulation tax under the deferred schedule
        // is left as future work.
        let rFlex = solve(deferYears: deferMax, scaleDownBps: scaleMax, floor: legacyFloor)

        // PVs at the safe real rate for the funded ratio and the resource split.
        var liabilityPv: Usd = 0, externalPv: Usd = 0, savingsPv: Usd = 0
        for t in startT...horizon {
            let disc = pow(1 + safeRealRate, Double(t))
            var grossOut: Usd = 0
            for g in h.goals where g.kind == .spending || g.kind == .reserve {
                let excess = g.inflationSeries.realExcessBps.frac
                for o in g.outflows where o.year == t {
                    let esc = o.inflationLinked ? pow(1 + excess, Double(max(0, t - 1))) : 1.0
                    grossOut += o.amountUsd * esc
                }
            }
            liabilityPv += (grossOut + (annualTaxUsd[t] ?? 0)) / disc
            externalPv += (socialSecurityAnnual(h, year: t, asOf: asOf) + pensionAnnual(h, year: t) + homeEquityOffset(h, year: t)) / disc
            if t >= 1 && t <= saveYears { savingsPv += h.annualSavingsUsd / disc }
        }
        // The legacy floor is itself a liability the resources must cover, in PV.
        let floorPv = legacyFloor / pow(1 + safeRealRate, Double(horizon))
        let netLiabilityPv = max(0, liabilityPv - externalPv) + floorPv
        let fundedRatio = netLiabilityPv > 0 ? ((A + savingsPv) / netLiabilityPv) : 9.99

        // Balance projection at the required return (ends at the legacy floor).
        var proj: [YearBalance] = []
        var b = A
        proj.append(YearBalance(year: year(asOf), balanceUsd: b))
        for t in 1...horizon {
            b = b * (1 + r) - netOutflow(t, deferYears: 0, scaleDownBps: 0)
            proj.append(YearBalance(year: year(asOf) + t, balanceUsd: max(0, b)))
        }

        return RequiredReturn(
            currentAssetsUsd: A, externalIncomePvUsd: externalPv, futureSavingsPvUsd: savingsPv,
            liabilityPvUsd: liabilityPv, netLiabilityPvUsd: netLiabilityPv,
            requiredRealReturnBps: r.bps, requiredRealReturnWithFlexibilityBps: rFlex.bps,
            fundedRatioBps: min(fundedRatio, 9.99).bps, projection: proj, safeRealRateBps: safeRealRate.bps,
            legacyFloorUsd: legacyFloor, spendDownRealReturnBps: rSpendDown.bps, requiredRealReturnPreTaxBps: r.bps)
    }

    /// Annual real Social Security income for the household, WITH survivor economics.
    /// While both spouses are alive and claiming, the household collects both benefits;
    /// on the first death the survivor keeps only the GREATER of the two (a widow(er)'s
    /// benefit) for the rest of the plan — the late-life income cliff a naive "run both
    /// forever" model hides. First death is the earlier of the two health-implied death
    /// years (Person.longevityPercentileTarget); the survivor and any single filer run
    /// to the caller's horizon. Delayed-retirement credits freeze at 70 and spousal
    /// benefits earn none.
    static func socialSecurityAnnual(_ h: Household, year t: Int, asOf: IsoDate) -> Usd {
        let maxPIA = h.socialSecurity.map { $0.estimatedPIAUsd }.max() ?? 0
        var legs: [(annual: Usd, start: Int, death: Int)] = []
        for ss in h.socialSecurity {
            guard let person = h.people.first(where: { $0.id == ss.personId }) else { continue }
            let currentAge = age(birthDate: person.birthDate, asOf: asOf)
            let start = max(0, ss.plannedClaimingAge - currentAge) + 1
            let death = person.longevityPercentileTarget - currentAge
            // A spouse claims the greater of their own PIA or half the higher earner's.
            let takingSpousal = ss.eligibleForSpousalBenefit && 0.5 * maxPIA > ss.estimatedPIAUsd
            let basePIA = takingSpousal ? 0.5 * maxPIA : ss.estimatedPIAUsd
            // Adjustment vs FRA: +8%/yr delayed (frozen at 70), −6%/yr early. Spousal
            // benefits do not earn delayed-retirement credits, so cap their credit at 0.
            let delta = ss.plannedClaimingAge - ss.fullRetirementAge
            let creditDelta = takingSpousal ? min(0, delta)
                                            : (delta > 0 ? min(delta, max(0, 70 - ss.fullRetirementAge)) : delta)
            let adj = creditDelta >= 0 ? (1 + 0.08 * Double(creditDelta)) : (1 + 0.06 * Double(creditDelta))
            legs.append((annual: basePIA * 12 * adj, start: start, death: death))
        }
        let claiming = legs.filter { t >= $0.start }
        if claiming.count <= 1 {
            // A single filer (one profile) collects to the caller's horizon. In a couple,
            // a lone claimant during the gap before the other spouse claims can be a
            // DECEASED early-claimer — pay it only while that person is alive, so a dead
            // spouse's benefit is never paid as if they were still living.
            return legs.count >= 2 ? (claiming.filter { t <= $0.death }.map { $0.annual }.max() ?? 0)
                                   : (claiming.map { $0.annual }.max() ?? 0)
        }
        // Two claimants: sum both until the first death, then the survivor keeps the greater.
        let firstDeath = legs.map { $0.death }.min() ?? Int.max
        return t <= firstDeath ? claiming.reduce(0) { $0 + $1.annual } : (claiming.map { $0.annual }.max() ?? 0)
    }

    static func pensionAnnual(_ h: Household, year t: Int) -> Usd {
        var total: Usd = 0
        for ext in h.externalAssets where ext.kind == .pension {
            if t >= ext.offsetsFromYear { total += ext.valueUsd * 0.06 }   // ~lifetime payout rate on the PV
        }
        return total
    }

    /// A primary residence is a LOCKED balance-sheet asset, not a spendable income
    /// stream: the prior 5%-of-equity "housing annuity" both double-counted the home
    /// (already an asset in net worth) and, drawn forever without depleting, financed a
    /// drawdown the equity can't actually fund — contradicting the model's own note.
    /// Home equity now offsets no spending; converting it (downsizing / reverse
    /// mortgage) is left to be modeled as an explicit, dated resource, not an assumption.
    static func homeEquityOffset(_ h: Household, year t: Int) -> Usd { 0 }

    // MARK: - Balance sheet

    public static func balanceSheet(_ h: Household, tax: TaxParameterSet, asOf: IsoDate, rr: RequiredReturn) -> BalanceSheetView {
        let portfolio = h.portfolioValueUsd
        let homeEquity = h.externalAssets.filter { $0.kind == .homeEquity }.reduce(0) { $0 + $1.valueUsd }
        let mortgage = h.liabilities.filter { $0.kind == .mortgagePrimary || $0.kind == .mortgageInvestment }.reduce(0) { $0 + $1.balanceUsd }
        let realEstateGross = homeEquity + mortgage

        // Human capital PV.
        var hcPv: Usd = 0
        for hc in h.humanCapital where hc.yearsRemaining > 0 {
            let g = hc.realGrowthRateBps.frac
            for t in 1...hc.yearsRemaining {
                hcPv += hc.annualIncomeUsd * pow(1 + g, Double(t - 1)) / pow(1 + humanCapitalDiscount, Double(t))
            }
        }
        // Social Security PV.
        var ssPv: Usd = 0
        let horizon = 35
        for t in 1...horizon { ssPv += socialSecurityAnnual(h, year: t, asOf: asOf) / pow(1 + safeRealRate, Double(t)) }
        let pensionPv = h.externalAssets.filter { $0.kind == .pension }.reduce(0) { $0 + $1.valueUsd }
        let businessPv = h.externalAssets.filter { $0.kind == .business }.reduce(0) { $0 + $1.valueUsd }
        let illiquidAlts = h.positions.filter { p in isIlliquidAlt(p) }.reduce(0) { $0 + $1.marketValueUsd }

        // Liabilities.
        let debt = h.liabilities.filter { $0.isFixedIncomeOffset }.reduce(0) { $0 + $1.balanceUsd }
        let unfunded = h.liabilities.filter { $0.kind == .unfundedCommitment }.reduce(0) { $0 + $1.balanceUsd }

        // Deferred tax — the largest unstated liability. Step-up earmarks extinguish it.
        var deferredDetail: [DeferredTaxLiability] = []
        for acct in h.accounts {
            let ps = h.positions.filter { $0.accountId == acct.id }
            let bal = ps.reduce(0) { $0 + $1.marketValueUsd }
            let gain = ps.reduce(0) { $0 + max(0, $1.unrealizedGainUsd) }
            switch acct.treatment {
            case .taxDeferred:
                let rate = 2400   // ordinary on withdrawal (approx retirement bracket)
                let liab = bal * rate.frac
                deferredDetail.append(DeferredTaxLiability(accountId: acct.id, treatment: .taxDeferred, balanceUsd: bal, unrealizedGainUsd: gain, applicableRateBps: rate, extinguishedByStepUp: false, estimatedLiabilityUsd: liab))
            case .taxable:
                // LTCG on gains, EXCEPT lots earmarked to step-up (liability = 0).
                let taxableGain = ps.filter { !$0.holdToStepUp }.reduce(0) { $0 + max(0, $1.unrealizedGainUsd) }
                let rate = 1500 + tax.niitRateBps  // 15% LTCG + NIIT for a high earner
                let liab = taxableGain * rate.frac
                let stepUpGain = ps.filter { $0.holdToStepUp }.reduce(0) { $0 + max(0, $1.unrealizedGainUsd) }
                // Flag "(step-up)" only when the account's whole taxable gain is
                // earmarked, so the label never contradicts a live liability figure.
                deferredDetail.append(DeferredTaxLiability(accountId: acct.id, treatment: .taxable, balanceUsd: bal, unrealizedGainUsd: gain, applicableRateBps: rate, extinguishedByStepUp: taxableGain == 0 && stepUpGain > 0, estimatedLiabilityUsd: liab))
            case .taxFree:
                deferredDetail.append(DeferredTaxLiability(accountId: acct.id, treatment: .taxFree, balanceUsd: bal, unrealizedGainUsd: gain, applicableRateBps: 0, extinguishedByStepUp: false, estimatedLiabilityUsd: 0))
            }
        }
        let deferredTax = deferredDetail.reduce(0) { $0 + $1.estimatedLiabilityUsd }

        // Projected estate tax. For a couple this is the SECOND-death estimate: the
        // first death passes to the surviving spouse under the unlimited marital
        // deduction (≈ $0 then), and portability gives the survivor both exemptions —
        // modeled here as exemption × non-dependent persons. The taxable estate is net
        // of non-mortgage debt (the mortgage is already netted inside homeEquity).
        let persons = h.people.filter { $0.role != .dependent }.count
        let exemption = tax.estate.lifetimeExemptionUsd * Double(max(1, persons))
        let nonMortgageDebt = max(0, debt - mortgage)
        let grossEstate = max(0, portfolio + homeEquity + pensionPv + businessPv - nonMortgageDebt)
        let projectedEstateTax = max(0, grossEstate - exemption) * tax.estate.topRateBps.frac

        // Goal liability PV (reuse the required-return liability; rr is passed in).
        let goalLiabilityPv = rr.liabilityPvUsd

        let assets = BalanceSheetView.Assets(portfolioUsd: portfolio, realEstateUsd: realEstateGross, humanCapitalPvUsd: hcPv, socialSecurityPvUsd: ssPv, pensionPvUsd: pensionPv, businessUsd: businessPv, illiquidAltsUsd: illiquidAlts)
        let liabilities = BalanceSheetView.Liabilities(debtUsd: debt, unfundedCommitmentsUsd: unfunded, deferredTaxUsd: deferredTax, projectedEstateTaxUsd: projectedEstateTax, goalLiabilityPvUsd: goalLiabilityPv)

        let totalHardAssets = portfolio + realEstateGross + businessPv
        let grossNetWorth = totalHardAssets - debt - unfunded
        let afterTaxNetWorth = grossNetWorth - deferredTax - projectedEstateTax

        // Net fixed income = FI assets - FI-offset debt.
        let fiAssets = h.positions.filter { isFixedIncome($0) }.reduce(0) { $0 + $1.marketValueUsd }
        let netFI = fiAssets - debt

        // Net household duration (dollar-duration weighted).
        let assetDollarDur = h.positions.filter { isFixedIncome($0) }.reduce(0.0) { $0 + $1.marketValueUsd * assetDuration(for: $1) }
        let debtDollarDur = h.liabilities.filter { $0.isFixedIncomeOffset }.reduce(0.0) { $0 + $1.balanceUsd * $1.durationYears }
        let netFIabs = abs(netFI) < 1 ? 1 : abs(netFI)
        // Near-zero net FI (offsetting FI assets and debt) makes the ratio explode; cap it
        // to a realistic fixed-income duration band rather than report a nonsense magnitude.
        let netDuration = max(-30.0, min(30.0, (assetDollarDur - debtDollarDur) / netFIabs))

        // Total balance-sheet equity.
        let equityPositions = h.positions.filter { isEquity($0) }.reduce(0) { $0 + $1.marketValueUsd }
        let hcEquity = h.humanCapital.reduce(0.0) { $0 + hcPvOne($1) * $1.impliedBeta }
        let unvestedEquity = h.deferredComp.filter { $0.kind == .rsu || $0.kind == .options || $0.kind == .espp }.reduce(0) { $0 + $1.grantValueUsd }
        let equityDollars = equityPositions + hcEquity + unvestedEquity + homeEquity   // levered RE equity counts
        // Unvested comp is in the numerator, so it must also be in the denominator.
        let tbsDenom = portfolio + hcPv + realEstateGross + ssPv + pensionPv + businessPv + unvestedEquity
        let tbsEquityBps = tbsDenom > 0 ? (equityDollars / tbsDenom).bps : 0

        // Single source of truth for the funded ratio (net-of-income convention).
        let fundedRatioBps = rr.fundedRatioBps

        return BalanceSheetView(householdId: h.id, asOf: asOf, assets: assets, liabilities: liabilities,
                                grossNetWorthUsd: grossNetWorth, afterTaxNetWorthUsd: afterTaxNetWorth,
                                netFixedIncomeUsd: netFI, netHouseholdDurationYears: netDuration,
                                totalBalanceSheetEquityBps: tbsEquityBps, fundedRatioBps: fundedRatioBps,
                                deferredTaxDetail: deferredDetail)
    }

    static func hcPvOne(_ hc: HumanCapital) -> Usd {
        guard hc.yearsRemaining > 0 else { return 0 }   // retiree: no human capital left
        let g = hc.realGrowthRateBps.frac
        var pv: Usd = 0
        for t in 1...hc.yearsRemaining { pv += hc.annualIncomeUsd * pow(1 + g, Double(t - 1)) / pow(1 + humanCapitalDiscount, Double(t)) }
        return pv
    }

    // MARK: classification helpers

    // Known employer-stock ticker → GICS sector, for human-capital stacking.
    static let employerStockSectors: [String: Sector] = ["MEGABANK": .financials]
    static func employerStockSector(_ ticker: String?) -> Sector? { ticker.flatMap { employerStockSectors[$0] } }

    /// The asset-class role of a held position, via its sleeve mapping (nil = an
    /// unclassified / held-away lot, which falls back to ticker heuristics).
    static func sleeveRole(_ p: Position) -> AssetRole? {
        guard let sid = p.sleeveId else { return nil }
        return Seed.legacyPolicy.sleeve(sid)?.role
    }
    static func isRealDiversifier(_ p: Position) -> Bool {
        if sleeveRole(p) == .realDiversifier { return true }
        return commodityTickers.contains(p.ticker)
    }
    static func isFixedIncome(_ p: Position) -> Bool {
        if let r = sleeveRole(p) { return r == .defensive || r == .cash }
        return fiTickers.contains(p.ticker)
    }
    static func isIlliquidAlt(_ p: Position) -> Bool { p.ticker == "PCRED" || p.ticker == "PE" }
    static func isEquity(_ p: Position) -> Bool {
        if let r = sleeveRole(p) { return r == .growth }
        return !isFixedIncome(p) && !isIlliquidAlt(p) && !isRealDiversifier(p) && p.ticker != "BUFR"
    }
    static func assetDuration(for p: Position) -> Double {
        switch sleeveRole(p) {
        case .cash: return 0.3
        case .realDiversifier: return 0.0
        default: break
        }
        switch p.sleeveId {
        case "tips", "em_debt": return 7.0
        case "credit_hy": return 3.8
        case "fixed_income_liquid": return 6.2
        default: break
        }
        if muniTickers.contains(p.ticker) { return 6.0 }
        if p.ticker == "BND" { return 6.2 }
        if p.ticker == "SGOV" || p.ticker == "BIL" { return 0.3 }
        if p.ticker == "SCHP" || p.ticker == "VTIP" || p.ticker == "EMB" { return 7.0 }
        if p.ticker == "HYG" || p.ticker == "JNK" { return 3.8 }
        return 5.0
    }
}
