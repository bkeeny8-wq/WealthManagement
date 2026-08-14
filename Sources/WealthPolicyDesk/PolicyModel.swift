//  PolicyModel.swift
//  WealthPolicyDesk
//
//  Ported from src/policy-schema-v2.ts — the investment policy schema.
//
//  The organizing idea: policy states PREFERENCES and BELIEFS. Household
//  allocation is an OUTPUT of funding goal claims, never a target. Tax numbers
//  live elsewhere (TaxModel). Beliefs should outlive both Congress and the
//  business cycle.

import Foundation

// MARK: - Shared enums (used across every module)

public enum AccountTaxTreatment: String, CaseIterable, Identifiable, Sendable, Hashable {
    case taxable
    case taxDeferred = "tax_deferred"
    case taxFree = "tax_free"
    public var id: String { rawValue }
    public var short: String {
        switch self {
        case .taxable: return "Taxable"
        case .taxDeferred: return "Tax-deferred"
        case .taxFree: return "Tax-free"
        }
    }
}

public enum FilingStatus: String, CaseIterable, Identifiable, Sendable, Hashable {
    case single, mfj, mfs, hoh
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .single: return "Single"
        case .mfj: return "Married filing jointly"
        case .mfs: return "Married filing separately"
        case .hoh: return "Head of household"
        }
    }
}

/// Liquidity class. NOT a boolean — the rebalancing engine, the ladder, and the
/// eligibility tiers all need to distinguish these.
public enum LiquidityClass: String, CaseIterable, Identifiable, Sendable, Hashable {
    case daily                          // ETFs, mutual funds
    case secondaryHaircut = "secondary_haircut"  // notes: sellable pre-maturity at a cost
    case selfLiquidating = "self_liquidating"    // notes at maturity, ladder rungs
    case gated                          // interval funds: ~5%/quarter
    case locked                         // PE, private credit — lockup + capital calls
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .daily: return "Daily"
        case .secondaryHaircut: return "Secondary (haircut)"
        case .selfLiquidating: return "Self-liquidating"
        case .gated: return "Gated"
        case .locked: return "Locked"
        }
    }
    /// Rank from most to least liquid, for sorting and floor checks.
    public var rank: Int {
        switch self {
        case .daily: return 0
        case .selfLiquidating: return 1
        case .secondaryHaircut: return 2
        case .gated: return 3
        case .locked: return 4
        }
    }
}

// MARK: - Alternatives: function budget, not product list

/// The three jobs sold under one label. Sizing is by FUNCTION; the wrapper
/// varies by what the household can actually access.
public enum AltFunction: String, CaseIterable, Identifiable, Sendable, Hashable {
    case convexity                       // trend, commodities, gold — inflation shocks
    case illiquidityPremium = "illiquidity_premium"  // PE, private credit
    case shapedPayoff = "shaped_payoff"  // notes, buffer ETFs — defined outcome
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .convexity: return "Convexity"
        case .illiquidityPremium: return "Illiquidity premium"
        case .shapedPayoff: return "Shaped payoff"
        }
    }
}

public struct AltFunctionBudget: Identifiable, Sendable, Hashable {
    public var fn: AltFunction
    public var targetBps: Bps
    public var bandBps: Bps
    /// Honest rationale. illiquidity_premium does NOT get the correlation argument.
    public var rationale: String
    /// Sleeve-level fee ceiling. Against 5bp bonds, the hurdle is real.
    public var maxFeeBps: Bps
    /// If no eligible wrapper exists at this tier, where the unfunded weight goes.
    public var fallbackSleeveId: String
    public var id: String { fn.rawValue }
    public init(fn: AltFunction, targetBps: Bps, bandBps: Bps, rationale: String, maxFeeBps: Bps, fallbackSleeveId: String) {
        self.fn = fn; self.targetBps = targetBps; self.bandBps = bandBps
        self.rationale = rationale; self.maxFeeBps = maxFeeBps; self.fallbackSleeveId = fallbackSleeveId
    }
}

/// Wrapper available at a given eligibility tier. Same function, different
/// vehicle as the household scales.
public struct AltWrapper: Identifiable, Sendable, Hashable {
    public var id: String
    public var fn: AltFunction
    public var label: String
    public var minTicketUsd: Usd
    public var liquidityClass: LiquidityClass
    public var feeBps: Bps
    public var requiresAccredited: Bool
    public var requiresQualifiedPurchaser: Bool
    /// Reported vol is understated for appraisal-marked assets. Any projection
    /// MUST use this override or unsmooth the series first.
    public var volatilityOverrideBps: Bps?
    public var returnsAreSmoothed: Bool
    /// Locked wrappers carry unfunded commitments — a liability, not just a weight.
    public var hasCapitalCalls: Bool
    /// Defined-outcome ETFs: buffer/cap apply only over a full outcome period.
    public var hasOutcomePeriod: Bool
    public init(id: String, fn: AltFunction, label: String, minTicketUsd: Usd, liquidityClass: LiquidityClass, feeBps: Bps, requiresAccredited: Bool, requiresQualifiedPurchaser: Bool, volatilityOverrideBps: Bps?, returnsAreSmoothed: Bool, hasCapitalCalls: Bool, hasOutcomePeriod: Bool) {
        self.id = id; self.fn = fn; self.label = label; self.minTicketUsd = minTicketUsd
        self.liquidityClass = liquidityClass; self.feeBps = feeBps
        self.requiresAccredited = requiresAccredited; self.requiresQualifiedPurchaser = requiresQualifiedPurchaser
        self.volatilityOverrideBps = volatilityOverrideBps; self.returnsAreSmoothed = returnsAreSmoothed
        self.hasCapitalCalls = hasCapitalCalls; self.hasOutcomePeriod = hasOutcomePeriod
    }
}

/// Tiers are DERIVED, not asserted. If notes cap at 3%/position and you want 3
/// issuers, the sleeve needs 9% of the portfolio — with $10k tickets that sets
/// a hard floor on portfolio size before the function is even coherent.
public struct EligibilityTier: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var minInvestableUsd: Usd
    public var accredited: Bool
    public var qualifiedPurchaser: Bool
    public var availableWrapperIds: [String]
    public init(id: String, label: String, minInvestableUsd: Usd, accredited: Bool, qualifiedPurchaser: Bool, availableWrapperIds: [String]) {
        self.id = id; self.label = label; self.minInvestableUsd = minInvestableUsd
        self.accredited = accredited; self.qualifiedPurchaser = qualifiedPurchaser
        self.availableWrapperIds = availableWrapperIds
    }
}

// MARK: - Sleeves

public enum SleeveTier: String, CaseIterable, Sendable, Hashable {
    case core, satellite, diversifier, liquidity
}

public enum TaxEfficiency: String, CaseIterable, Sendable, Hashable {
    case high, moderate, low
}

public struct SleeveInstrument: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case primary, tlhPartner = "tlh_partner", option }
    public var ticker: String
    public var role: Role
    public init(ticker: String, role: Role) { self.ticker = ticker; self.role = role }
}

public struct Sleeve: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var tier: SleeveTier
    public var targetBps: Bps
    public var bandBps: Bps
    public var maxBps: Bps?
    public var taxEfficiency: TaxEfficiency
    public var locationPreference: [AccountTaxTreatment]
    public var liquidityClass: LiquidityClass
    public var instruments: [SleeveInstrument]
    public var rationale: String
    public init(id: String, label: String, tier: SleeveTier, targetBps: Bps, bandBps: Bps, maxBps: Bps?, taxEfficiency: TaxEfficiency, locationPreference: [AccountTaxTreatment], liquidityClass: LiquidityClass, instruments: [SleeveInstrument], rationale: String) {
        self.id = id; self.label = label; self.tier = tier; self.targetBps = targetBps
        self.bandBps = bandBps; self.maxBps = maxBps; self.taxEfficiency = taxEfficiency
        self.locationPreference = locationPreference; self.liquidityClass = liquidityClass
        self.instruments = instruments; self.rationale = rationale
    }
    public var primaryTicker: String { instruments.first(where: { $0.role == .primary })?.ticker ?? instruments.first?.ticker ?? "—" }
}

// MARK: - Glide, rebalance, withdrawal, regime, ladder

public struct LadderPolicy: Sendable, Hashable {
    /// Years of net outflows to pre-fund. Drives ladder length directly.
    public var yearsCovered: Int
    public var minCreditQuality: String
    public var allowCredit: Bool
    public var rollForward: Bool
    /// Liquid FI floor for rebalancing ammunition — separate from the ladder.
    public var rebalanceReserveBps: Bps
    public init(yearsCovered: Int, minCreditQuality: String, allowCredit: Bool, rollForward: Bool, rebalanceReserveBps: Bps) {
        self.yearsCovered = yearsCovered; self.minCreditQuality = minCreditQuality
        self.allowCredit = allowCredit; self.rollForward = rollForward; self.rebalanceReserveBps = rebalanceReserveBps
    }
}

public struct ValuationSignal: Sendable, Hashable {
    public enum Metric: String, Sendable, Hashable { case cape, earningsYieldReal = "earnings_yield_real", equityRiskPremium = "equity_risk_premium" }
    public var metric: Metric
    public var richThreshold: Double
    public var cheapThreshold: Double
    public var maxScheduleDeviationYears: Double
    public init(metric: Metric, richThreshold: Double, cheapThreshold: Double, maxScheduleDeviationYears: Double) {
        self.metric = metric; self.richThreshold = richThreshold
        self.cheapThreshold = cheapThreshold; self.maxScheduleDeviationYears = maxScheduleDeviationYears
    }
}

/// Applies to the SPENDING claim only. The legacy claim never glides.
public struct GlidePolicy: Sendable, Hashable {
    public var startDate: IsoDate
    public var hardCompletionDate: IsoDate
    public var fromEquityBps: Bps
    public var toEquityBps: Bps
    public var ratchet: Bool
    public var valuationSignal: ValuationSignal
    public var altCompositionShift: [(fn: AltFunction, deltaBps: Bps)]
    public init(startDate: IsoDate, hardCompletionDate: IsoDate, fromEquityBps: Bps, toEquityBps: Bps, ratchet: Bool, valuationSignal: ValuationSignal, altCompositionShift: [(fn: AltFunction, deltaBps: Bps)]) {
        self.startDate = startDate; self.hardCompletionDate = hardCompletionDate
        self.fromEquityBps = fromEquityBps; self.toEquityBps = toEquityBps
        self.ratchet = ratchet; self.valuationSignal = valuationSignal; self.altCompositionShift = altCompositionShift
    }
    public static func == (l: GlidePolicy, r: GlidePolicy) -> Bool {
        l.startDate == r.startDate && l.hardCompletionDate == r.hardCompletionDate &&
        l.fromEquityBps == r.fromEquityBps && l.toEquityBps == r.toEquityBps &&
        l.ratchet == r.ratchet && l.valuationSignal == r.valuationSignal &&
        l.altCompositionShift.map(\.deltaBps) == r.altCompositionShift.map(\.deltaBps) &&
        l.altCompositionShift.map(\.fn) == r.altCompositionShift.map(\.fn)
    }
    public func hash(into h: inout Hasher) { h.combine(fromEquityBps); h.combine(toEquityBps) }
}

public struct RebalancePolicy: Sendable, Hashable {
    public var reviewCadence: String
    public var trigger: String
    /// Inner band: flag. Outer band: mandatory.
    public var outerBandMultiplier: Double
    /// Partial correction toward target, letting momentum run. 0–10000 bps.
    public var correctionFractionBps: Bps
    public var minTradeUsd: Usd
    public var preferCashFlowRebalancing: Bool
    public var washSaleWindowDays: Int
    /// Realized gain budget for NON-earmarked lots only. nil = none.
    public var realizedGainBudgetBps: Bps?
    /// Locked/gated holdings sit outside bands; the rest absorbs their drift.
    public var excludedLiquidityClasses: [LiquidityClass]
    public init(reviewCadence: String, trigger: String, outerBandMultiplier: Double, correctionFractionBps: Bps, minTradeUsd: Usd, preferCashFlowRebalancing: Bool, washSaleWindowDays: Int, realizedGainBudgetBps: Bps?, excludedLiquidityClasses: [LiquidityClass]) {
        self.reviewCadence = reviewCadence; self.trigger = trigger; self.outerBandMultiplier = outerBandMultiplier
        self.correctionFractionBps = correctionFractionBps; self.minTradeUsd = minTradeUsd
        self.preferCashFlowRebalancing = preferCashFlowRebalancing; self.washSaleWindowDays = washSaleWindowDays
        self.realizedGainBudgetBps = realizedGainBudgetBps; self.excludedLiquidityClasses = excludedLiquidityClasses
    }
}

/// v1 FLAGS opportunities rather than optimizing. The retirement-to-RMD window
/// is worth more than any tilt will ever produce.
public struct WithdrawalPolicy: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable { case flagOpportunities = "flag_opportunities", optimize }
    public var mode: Mode
    public var strategy: String
    public var targetBracketRateBps: Bps
    public var conversionWindow: (fromAge: Int, toAge: Int)?
    public var cliffAwareness: [String]
    public init(mode: Mode, strategy: String, targetBracketRateBps: Bps, conversionWindow: (fromAge: Int, toAge: Int)?, cliffAwareness: [String]) {
        self.mode = mode; self.strategy = strategy; self.targetBracketRateBps = targetBracketRateBps
        self.conversionWindow = conversionWindow; self.cliffAwareness = cliffAwareness
    }
    public static func == (l: WithdrawalPolicy, r: WithdrawalPolicy) -> Bool {
        l.mode == r.mode && l.strategy == r.strategy && l.targetBracketRateBps == r.targetBracketRateBps &&
        l.conversionWindow?.fromAge == r.conversionWindow?.fromAge && l.conversionWindow?.toAge == r.conversionWindow?.toAge &&
        l.cliffAwareness == r.cliffAwareness
    }
    public func hash(into h: inout Hasher) { h.combine(mode); h.combine(targetBracketRateBps) }
}

public struct RegimePolicy: Sendable, Hashable {
    public var enabled: Bool
    public var evaluationCadence: String
    public var maxTiltBps: Bps
    public var restrictToTreatments: [AccountTaxTreatment]
    public init(enabled: Bool, evaluationCadence: String, maxTiltBps: Bps, restrictToTreatments: [AccountTaxTreatment]) {
        self.enabled = enabled; self.evaluationCadence = evaluationCadence
        self.maxTiltBps = maxTiltBps; self.restrictToTreatments = restrictToTreatments
    }
}

// MARK: - The policy aggregate

public struct InvestmentPolicy: Identifiable, Sendable, Hashable {
    public var id: String
    public var version: String
    public var effectiveDate: IsoDate
    public var taxModuleVersion: String
    public var sleeves: [Sleeve]
    public var altBudgets: [AltFunctionBudget]
    public var altWrappers: [AltWrapper]
    public var eligibilityTiers: [EligibilityTier]
    public var ladder: LadderPolicy
    public var glide: GlidePolicy?
    public var rebalance: RebalancePolicy
    public var withdrawal: WithdrawalPolicy
    public var regime: RegimePolicy
    public var constraints: [PolicyRule]
    /// Becomes IPS language and client explanation.
    public var statement: String
    public init(id: String, version: String, effectiveDate: IsoDate, taxModuleVersion: String, sleeves: [Sleeve], altBudgets: [AltFunctionBudget], altWrappers: [AltWrapper], eligibilityTiers: [EligibilityTier], ladder: LadderPolicy, glide: GlidePolicy?, rebalance: RebalancePolicy, withdrawal: WithdrawalPolicy, regime: RegimePolicy, constraints: [PolicyRule], statement: String) {
        self.id = id; self.version = version; self.effectiveDate = effectiveDate; self.taxModuleVersion = taxModuleVersion
        self.sleeves = sleeves; self.altBudgets = altBudgets; self.altWrappers = altWrappers
        self.eligibilityTiers = eligibilityTiers; self.ladder = ladder; self.glide = glide
        self.rebalance = rebalance; self.withdrawal = withdrawal; self.regime = regime
        self.constraints = constraints; self.statement = statement
    }
    public func sleeve(_ id: String) -> Sleeve? { sleeves.first { $0.id == id } }
    public func tier(_ id: String) -> EligibilityTier? { eligibilityTiers.first { $0.id == id } }
    public func wrapper(_ id: String) -> AltWrapper? { altWrappers.first { $0.id == id } }
    /// Sum of sleeve targets — the equity/FI split that "looks like" an allocation.
    public var totalSleeveTargetBps: Bps { sleeves.reduce(0) { $0 + $1.targetBps } }
    public var totalAltTargetBps: Bps { altBudgets.reduce(0) { $0 + $1.targetBps } }
}
