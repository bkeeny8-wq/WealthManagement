//  IntakeModel.swift
//  WealthPolicyDesk
//
//  The entrance questionnaire. IntakeModel is the raw, Codable set of answers an
//  individual gives; `buildHousehold()` derives a full Household from it —
//  synthesizing a policy-shaped portfolio, estimating Social Security, resolving
//  the eligibility tier, and folding the personality answers into a risk
//  profile. Everything a layperson can't answer (betas, sleeves, duration) is
//  derived here so minimal input still produces a working desk.
//
//  Persistence is on-device JSON (IntakeStore). No network, no account numbers.

import Foundation

// MARK: - Codable conformance for the shared enums

extension FilingStatus: Codable {}
extension HealthStatus: Codable {}
extension IncomeCharacter: Codable {}
extension Sector: Codable {}
extension AccountTaxTreatment: Codable {}
extension GoalTier: Codable {}
public extension GoalTier {
    var label: String {
        switch self { case .essential: return "Essential"; case .lifestyle: return "Lifestyle"; case .aspirational: return "Aspirational" }
    }
}

// MARK: - Personality answers

public enum BonusStability: String, Codable, CaseIterable, Hashable {
    case low, medium, high
    public var volatilityBps: Bps { self == .low ? 1000 : (self == .medium ? 2500 : 5000) }
}

public enum PastBehavior: String, Codable, CaseIterable, Hashable {
    case soldMost, soldSome, held, boughtMore, notInvested
    public var label: String {
        switch self {
        case .soldMost: return "Sold most of it"
        case .soldSome: return "Sold some"
        case .held: return "Held on"
        case .boughtMore: return "Bought more"
        case .notInvested: return "Wasn't invested yet"
        }
    }
    /// Multiplier applied to stated tolerance — revealed behavior tempers words.
    var toleranceMultiplier: Double {
        switch self {
        case .soldMost: return 0.55
        case .soldSome: return 0.8
        case .held: return 1.0
        case .boughtMore: return 1.15
        case .notInvested: return 0.85
        }
    }
}

/// A forward, dollar-anchored loss-reaction — the single most predictive risk-
/// tolerance item. What the client says they'd actually DO in a severe year
/// tempers a stated max-loss threshold (words are cheaper than actions), and it
/// applies even to someone who wasn't invested for the last drawdown.
public enum LossReaction: String, Codable, CaseIterable, Hashable {
    case sellAll, sellSome, hold, buyMore
    public var label: String {
        switch self {
        case .sellAll:  return "Sell to stop the loss"
        case .sellSome: return "Trim some"
        case .hold:     return "Hold the course"
        case .buyMore:  return "Buy more"
        }
    }
    /// Forward-reaction multiplier on stated tolerance.
    var toleranceMultiplier: Double {
        switch self { case .sellAll: return 0.6; case .sellSome: return 0.85; case .hold: return 1.0; case .buyMore: return 1.15 }
    }
}

public enum WorryFraming: String, Codable, CaseIterable, Hashable {
    case drop, shortfall
    public var label: String { self == .drop ? "A big temporary drop" : "Not reaching the goal" }
    /// Orientation tilt: a shortfall-worried client bears more volatility to reach
    /// the goal; a drop-worried client less. A small, honest nudge — the framing's
    /// bigger job (which frontier point to highlight) arrives with the frontier.
    var toleranceTiltMultiplier: Double { self == .drop ? 0.95 : 1.05 }
}

public enum LegacyPriority: String, Codable, CaseIterable, Hashable {
    case essential, niceToHave, none
    public var label: String {
        switch self { case .essential: return "Essential"; case .niceToHave: return "Nice to have"; case .none: return "Not a goal" }
    }
}

public enum SpendingFlexibility: String, Codable, CaseIterable, Hashable {
    case rigid, some, lots
    public var label: String {
        switch self { case .rigid: return "No — it's fixed"; case .some: return "Somewhat"; case .lots: return "Yes, easily" }
    }
    var deferrableYears: Int { self == .rigid ? 0 : (self == .some ? 2 : 4) }
    var scalableDownBps: Bps { self == .rigid ? 0 : (self == .some ? 1500 : 3000) }
}

public enum Appetite: String, Codable, CaseIterable, Hashable {
    case low, medium, high
    public var label: String { rawValue.capitalized }
}

// MARK: - Adult

public struct IntakeAdult: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String = ""
    public var birthYear: Int = 1975
    public var retirementAge: Int = 65
    public var health: HealthStatus = .good
    public var salaryUsd: Usd = 120_000
    public var bonusUsd: Usd = 0
    public var bonusStability: BonusStability = .medium
    public var incomeCharacter: IncomeCharacter = .moderate
    public var sector: Sector? = nil
    public var employerStockUsd: Usd = 0
    public var deferredCashUsd: Usd = 0
    public init() {}
}

// MARK: - Held-away holdings & transition

/// What the client intends to do with an itemized held-away position.
public enum HeldPositionTreatment: String, Codable, CaseIterable, Hashable {
    case keepAsCore = "keep_as_core", keepAsTlhPartner = "keep_as_tlh_partner"
    case unwindScheduled = "unwind_scheduled", unwindImmediate = "unwind_immediate"
    case permanentHold = "permanent_hold", giftOrDonate = "gift_or_donate"
    public var label: String {
        switch self {
        case .keepAsCore: return "Keep as core"
        case .keepAsTlhPartner: return "Keep as TLH partner"
        case .unwindScheduled: return "Unwind over N years"
        case .unwindImmediate: return "Unwind now"
        case .permanentHold: return "Permanent hold (to step-up)"
        case .giftOrDonate: return "Gift or donate"
        }
    }
}

/// Policy for positions the household will never sell.
public enum PermanentHoldPolicy: String, Codable, CaseIterable, Hashable {
    case absorbIntoMatrix = "absorb_into_matrix", hedge, unwindAtDeath = "unwind_at_death"
    public var label: String {
        switch self {
        case .absorbIntoMatrix: return "Absorb into the exposure matrix"
        case .hedge: return "Hedge the exposure"
        case .unwindAtDeath: return "Unwind at death"
        }
    }
}

/// A single itemized held-away position — real ticker, value and basis.
public struct IntakeHeldPosition: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var ticker: String = ""
    public var marketValueUsd: Usd = 0
    public var costBasisUsd: Usd = 0
    public var treatment: AccountTaxTreatment = .taxable
    public var plan: HeldPositionTreatment = .keepAsCore
    public var unwindYears: Int = 3
    public var isConcentrated: Bool = false
    /// When set, the lot's acquisition date drives its holding period (short vs long term).
    /// Optional so records saved before this field decode cleanly. Empty/nil = unknown vintage.
    public var acquisitionDate: IsoDate? = nil
    public init() {}
    public var unrealizedGainUsd: Usd { marketValueUsd - costBasisUsd }
}

// MARK: - Additional goals

public enum GoalType: String, Codable, CaseIterable, Hashable {
    case homePurchase = "home_purchase", education, sabbatical, business, largePurchase = "large_purchase", other
    public var label: String {
        switch self {
        case .homePurchase: return "Home purchase"
        case .education: return "Education"
        case .sabbatical: return "Sabbatical"
        case .business: return "Business"
        case .largePurchase: return "Large purchase"
        case .other: return "Other"
        }
    }
    /// Non-CPI goals price above headline inflation.
    public var defaultInflation: InflationSeries {
        switch self { case .homePurchase: return .construction; case .education: return .education; default: return .cpi }
    }
}

public struct IntakeGoal: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var type: GoalType = .largePurchase
    public var label: String = ""
    public var amountUsd: Usd = 50_000
    public var targetYear: Int = IntakeModel.currentYear + 5
    public var spanYears: Int = 1
    public var tier: GoalTier = .lifestyle
    public var deferrableYears: Int = 0
    public var scalableDownBps: Bps = 1500
    public var abandonable: Bool = false
    public init() {}
}

// MARK: - Dependents & education

public enum EducationCostPreset: String, Codable, CaseIterable, Hashable {
    case inStatePublic = "in_state_public", outOfStatePublic = "out_of_state_public", privateCollege = "private", custom
    public var label: String {
        switch self {
        case .inStatePublic: return "In-state public"
        case .outOfStatePublic: return "Out-of-state public"
        case .privateCollege: return "Private"
        case .custom: return "Custom"
        }
    }
    public var annualCostUsd: Usd {
        switch self { case .inStatePublic: return 30_000; case .outOfStatePublic: return 50_000; case .privateCollege: return 80_000; case .custom: return 0 }
    }
}

public struct IntakeChild: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String = ""
    public var birthYear: Int = 2015
    public init() {}
}

public struct IntakeEducationGoal: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var childId: UUID? = nil
    public var label: String = "College"
    public var costPreset: EducationCostPreset = .inStatePublic
    public var annualCostTodayUsd: Usd = 30_000
    public var years: Int = 4
    public var startYear: Int = IntakeModel.currentYear + 10
    public var five29BalanceUsd: Usd = 0
    public var five29OpenedYear: Int? = nil
    public var rothRolloverEligible: Bool = false
    public init() {}
}

// MARK: - Estate & giving

public enum BequestSource: String, Codable, CaseIterable, Hashable {
    case ira, taxable, none
    public var label: String {
        switch self {
        case .ira: return "Traditional IRA / tax-deferred"
        case .taxable: return "Taxable brokerage"
        case .none: return "No charitable bequest"
        }
    }
}

public enum HeirTaxBracket: String, Codable, CaseIterable, Hashable {
    case low, moderate, high, top
    public var label: String {
        switch self { case .low: return "Low ~12%"; case .moderate: return "Moderate ~24%"; case .high: return "High ~35%"; case .top: return "Top 37%" }
    }
    /// Feeds Household.estate.heirBracketBps — the IRD cost driver.
    public var bracketBps: Bps {
        switch self { case .low: return 1200; case .moderate: return 2400; case .high: return 3500; case .top: return 3700 }
    }
}

// MARK: - Protection (insurance)

public enum LtcApproach: String, Codable, CaseIterable, Hashable {
    case selfFund = "self_fund", traditionalLtc = "traditional_ltc", hybrid, none
    public var label: String {
        switch self { case .selfFund: return "Self-fund from a reserve"; case .traditionalLtc: return "Traditional LTC policy"; case .hybrid: return "Hybrid life/LTC"; case .none: return "No plan" }
    }
}
public enum LifeKind: String, Codable, CaseIterable, Hashable {
    case term, permanent, mixed, none
    public var label: String { switch self { case .term: return "Term"; case .permanent: return "Permanent"; case .mixed: return "Mixed"; case .none: return "None" } }
}

// MARK: - Equity compensation

public enum EquityGrantType: String, Codable, CaseIterable, Hashable {
    case rsu, iso, nso, espp, restrictedStock = "restricted_stock", founder
    public var label: String {
        switch self { case .rsu: return "RSUs"; case .iso: return "ISOs"; case .nso: return "NSOs"; case .espp: return "ESPP"; case .restrictedStock: return "Restricted stock (83b)"; case .founder: return "Founder shares" }
    }
}
public enum TradingWindowStatus: String, Codable, CaseIterable, Hashable {
    case open, blackout, restricted
    public var label: String { switch self { case .open: return "Open"; case .blackout: return "In blackout"; case .restricted: return "Always restricted" } }
}
public enum QsbsStatus: String, Codable, CaseIterable, Hashable {
    case none, maybe, likely
    public var label: String { switch self { case .none: return "No"; case .maybe: return "Maybe"; case .likely: return "Likely" } }
}

// MARK: - The intake

public struct IntakeModel: Codable, Hashable {
    // Assumed "now" — matches the engine's default asOf so ages line up.
    public static let currentYear = 2026

    // 1 — household
    public var adults: [IntakeAdult] = [IntakeAdult()]
    public var childrenBirthYears: [Int] = []
    public var filingStatus: FilingStatus = .single
    public var state: String = "CA"
    public var survivableOnOneIncome: Bool = true

    // 3 — savings & reserve
    public var annualSavingsUsd: Usd = 20_000
    public var emergencyReserveUsd: Usd = 50_000

    // 4 — accounts & holdings
    public var taxableUsd: Usd = 200_000
    public var traditionalUsd: Usd = 300_000
    public var rothUsd: Usd = 50_000
    /// Titling of the taxable account. nil = auto-derive (community property in CP states
    /// for a couple, else joint; individual for a single filer). Drives the death step-up.
    public var taxableTitling: OwnershipKind? = nil
    public var taxableUnrealizedGainPct: Double = 0.35   // 0..1
    /// Roughly how the money is invested TODAY (equity share, 0..1). The as-is
    /// portfolio is synthesized from THIS, not the policy target, so the allocation
    /// gap is real rather than zero-by-construction. Defaults below the policy target.
    public var currentEquityPct: Double = 0.65

    // 5 — real estate & debts
    public var homeValueUsd: Usd = 0
    public var mortgageBalanceUsd: Usd = 0
    public var mortgageRateBps: Bps = 550
    public var mortgageFixed: Bool = true
    public var helocUsd: Usd = 0
    public var otherDebtUsd: Usd = 0
    public var otherDebtRateBps: Bps = 700

    // 6 — external income
    public var pensionAnnualUsd: Usd = 0
    public var ssClaimAge: Int = 67

    // 7 — goals
    public var retirementSpendingUsd: Usd = 120_000
    public var retirementStartAge: Int = 65
    public var planToAge: Int = 92
    public var legacyFloorUsd: Usd = 0

    // 8 — personality / risk
    public var lossToleranceBps: Bps = 2000       // stated max single-year drawdown (the threshold; on the chip grid)
    public var pastBehavior: PastBehavior = .held         // revealed history
    public var forwardLossReaction: LossReaction = .hold  // stated forward reaction to a severe year
    public var worry: WorryFraming = .shortfall
    public var legacyPriority: LegacyPriority = .niceToHave
    public var spendingFlexibility: SpendingFlexibility = .some
    public var complexityAppetite: Appetite = .medium

    // 9 — held-away holdings & transition
    public var heldAwayPositions: [IntakeHeldPosition] = []
    public var annualGainBudgetUsd: Usd = 50_000
    public var transitionTargetYears: Int = 3
    public var permanentHoldPolicy: PermanentHoldPolicy = .absorbIntoMatrix

    // 10 — additional goals (beyond retirement)
    public var additionalGoals: [IntakeGoal] = []

    // 11 — dependents & education
    public var children: [IntakeChild] = []
    public var educationGoals: [IntakeEducationGoal] = []

    // 12 — estate & giving
    public var heirCount: Int = 0
    public var expectedHeirBracket: HeirTaxBracket = .moderate
    public var annualGivingUsd: Usd = 0
    public var qcdEligible: Bool = false
    public var qcdPlannedUsd: Usd = 0
    public var dafExists: Bool = false
    public var dafBalanceUsd: Usd = 0
    public var charitableBequestSource: BequestSource = .none
    public var hasWill: Bool = false
    public var hasRevocableTrust: Bool = false
    public var hasFinancialPOA: Bool = false
    public var hasHealthcareDirective: Bool = false
    public var beneficiaryDesignationsCurrent: Bool = false

    // 13 — protection
    public var disabilityGroupMonthlyUsd: Usd = 0
    public var disabilityIndividualMonthlyUsd: Usd = 0
    public var disabilityBenefitsTaxable: Bool = true
    public var disabilityOwnOccupation: Bool = false
    public var disabilityCoversBonus: Bool = false
    public var lifeInForceUsd: Usd = 0
    public var lifeKind: LifeKind = .none
    public var lifeInIrrevocableTrust: Bool = false
    public var ltcApproach: LtcApproach = .none
    public var ltcDedicatedReserveUsd: Usd = 0
    public var ltcEstimatedAnnualCostUsd: Usd = 100_000
    public var ltcEstimatedDurationYears: Int = 3
    public var umbrellaLimitUsd: Usd = 0

    // 14 — equity compensation (primary earner)
    public var equityGrantTypes: [EquityGrantType] = []
    public var isCompanyInsider: Bool = false
    public var tradingWindow: TradingWindowStatus = .open
    public var has10b51Plan: Bool = false
    public var isoUnexercisedValueUsd: Usd = 0
    public var planningIsoExerciseAndHold: Bool = false
    public var isoBargainElementUsd: Usd = 0
    public var pending83bGrantDate: String = ""    // ISO date; empty = none pending
    public var esppAnnualContributionUsd: Usd = 0
    public var esppDiscountBps: Bps = 1500
    public var esppLookback: Bool = true
    public var qsbsStatus: QsbsStatus = .none

    public init() {}

    /// Forward-compatible decode: start from defaults, then override only the
    /// keys actually present. A future non-optional field addition therefore
    /// resolves to its default on old JSON instead of throwing and silently
    /// discarding the whole saved plan.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = (try? c.decodeIfPresent([IntakeAdult].self, forKey: .adults)) ?? nil { adults = v }
        if let v = (try? c.decodeIfPresent([Int].self, forKey: .childrenBirthYears)) ?? nil { childrenBirthYears = v }
        if let v = (try? c.decodeIfPresent(FilingStatus.self, forKey: .filingStatus)) ?? nil { filingStatus = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil { state = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .survivableOnOneIncome)) ?? nil { survivableOnOneIncome = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .annualSavingsUsd)) ?? nil { annualSavingsUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .emergencyReserveUsd)) ?? nil { emergencyReserveUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .taxableUsd)) ?? nil { taxableUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .traditionalUsd)) ?? nil { traditionalUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .rothUsd)) ?? nil { rothUsd = v }
        if let v = (try? c.decodeIfPresent(Double.self, forKey: .taxableUnrealizedGainPct)) ?? nil { taxableUnrealizedGainPct = v }
        if let v = (try? c.decodeIfPresent(Double.self, forKey: .currentEquityPct)) ?? nil { currentEquityPct = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .homeValueUsd)) ?? nil { homeValueUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .mortgageBalanceUsd)) ?? nil { mortgageBalanceUsd = v }
        if let v = (try? c.decodeIfPresent(Bps.self, forKey: .mortgageRateBps)) ?? nil { mortgageRateBps = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .mortgageFixed)) ?? nil { mortgageFixed = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .helocUsd)) ?? nil { helocUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .otherDebtUsd)) ?? nil { otherDebtUsd = v }
        if let v = (try? c.decodeIfPresent(Bps.self, forKey: .otherDebtRateBps)) ?? nil { otherDebtRateBps = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .pensionAnnualUsd)) ?? nil { pensionAnnualUsd = v }
        if let v = (try? c.decodeIfPresent(Int.self, forKey: .ssClaimAge)) ?? nil { ssClaimAge = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .retirementSpendingUsd)) ?? nil { retirementSpendingUsd = v }
        if let v = (try? c.decodeIfPresent(Int.self, forKey: .retirementStartAge)) ?? nil { retirementStartAge = v }
        if let v = (try? c.decodeIfPresent(Int.self, forKey: .planToAge)) ?? nil { planToAge = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .legacyFloorUsd)) ?? nil { legacyFloorUsd = v }
        if let v = (try? c.decodeIfPresent(Bps.self, forKey: .lossToleranceBps)) ?? nil { lossToleranceBps = v }
        if let v = (try? c.decodeIfPresent(PastBehavior.self, forKey: .pastBehavior)) ?? nil { pastBehavior = v }
        if let v = (try? c.decodeIfPresent(LossReaction.self, forKey: .forwardLossReaction)) ?? nil { forwardLossReaction = v }
        if let v = (try? c.decodeIfPresent(WorryFraming.self, forKey: .worry)) ?? nil { worry = v }
        if let v = (try? c.decodeIfPresent(LegacyPriority.self, forKey: .legacyPriority)) ?? nil { legacyPriority = v }
        if let v = (try? c.decodeIfPresent(SpendingFlexibility.self, forKey: .spendingFlexibility)) ?? nil { spendingFlexibility = v }
        if let v = (try? c.decodeIfPresent(Appetite.self, forKey: .complexityAppetite)) ?? nil { complexityAppetite = v }
        if let v = (try? c.decodeIfPresent([IntakeHeldPosition].self, forKey: .heldAwayPositions)) ?? nil { heldAwayPositions = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .annualGainBudgetUsd)) ?? nil { annualGainBudgetUsd = v }
        if let v = (try? c.decodeIfPresent(Int.self, forKey: .transitionTargetYears)) ?? nil { transitionTargetYears = v }
        if let v = (try? c.decodeIfPresent(PermanentHoldPolicy.self, forKey: .permanentHoldPolicy)) ?? nil { permanentHoldPolicy = v }
        if let v = (try? c.decodeIfPresent([IntakeGoal].self, forKey: .additionalGoals)) ?? nil { additionalGoals = v }
        if let v = (try? c.decodeIfPresent([IntakeChild].self, forKey: .children)) ?? nil { children = v }
        if let v = (try? c.decodeIfPresent([IntakeEducationGoal].self, forKey: .educationGoals)) ?? nil { educationGoals = v }
        // Legacy migration: synthesize children from the old childrenBirthYears list.
        if children.isEmpty, let ys = (try? c.decodeIfPresent([Int].self, forKey: .childrenBirthYears)) ?? nil {
            children = ys.map { var ch = IntakeChild(); ch.birthYear = $0; return ch }
        }
        if let v = (try? c.decodeIfPresent(Int.self, forKey: .heirCount)) ?? nil { heirCount = v }
        if let v = (try? c.decodeIfPresent(HeirTaxBracket.self, forKey: .expectedHeirBracket)) ?? nil { expectedHeirBracket = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .annualGivingUsd)) ?? nil { annualGivingUsd = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .qcdEligible)) ?? nil { qcdEligible = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .qcdPlannedUsd)) ?? nil { qcdPlannedUsd = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .dafExists)) ?? nil { dafExists = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .dafBalanceUsd)) ?? nil { dafBalanceUsd = v }
        if let v = (try? c.decodeIfPresent(BequestSource.self, forKey: .charitableBequestSource)) ?? nil { charitableBequestSource = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .hasWill)) ?? nil { hasWill = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .hasRevocableTrust)) ?? nil { hasRevocableTrust = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .hasFinancialPOA)) ?? nil { hasFinancialPOA = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .hasHealthcareDirective)) ?? nil { hasHealthcareDirective = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .beneficiaryDesignationsCurrent)) ?? nil { beneficiaryDesignationsCurrent = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .disabilityGroupMonthlyUsd)) ?? nil { disabilityGroupMonthlyUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .disabilityIndividualMonthlyUsd)) ?? nil { disabilityIndividualMonthlyUsd = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .disabilityBenefitsTaxable)) ?? nil { disabilityBenefitsTaxable = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .disabilityOwnOccupation)) ?? nil { disabilityOwnOccupation = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .disabilityCoversBonus)) ?? nil { disabilityCoversBonus = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .lifeInForceUsd)) ?? nil { lifeInForceUsd = v }
        if let v = (try? c.decodeIfPresent(LifeKind.self, forKey: .lifeKind)) ?? nil { lifeKind = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .lifeInIrrevocableTrust)) ?? nil { lifeInIrrevocableTrust = v }
        if let v = (try? c.decodeIfPresent(LtcApproach.self, forKey: .ltcApproach)) ?? nil { ltcApproach = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .ltcDedicatedReserveUsd)) ?? nil { ltcDedicatedReserveUsd = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .ltcEstimatedAnnualCostUsd)) ?? nil { ltcEstimatedAnnualCostUsd = v }
        if let v = (try? c.decodeIfPresent(Int.self, forKey: .ltcEstimatedDurationYears)) ?? nil { ltcEstimatedDurationYears = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .umbrellaLimitUsd)) ?? nil { umbrellaLimitUsd = v }
        if let v = (try? c.decodeIfPresent([EquityGrantType].self, forKey: .equityGrantTypes)) ?? nil { equityGrantTypes = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .isCompanyInsider)) ?? nil { isCompanyInsider = v }
        if let v = (try? c.decodeIfPresent(TradingWindowStatus.self, forKey: .tradingWindow)) ?? nil { tradingWindow = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .has10b51Plan)) ?? nil { has10b51Plan = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .isoUnexercisedValueUsd)) ?? nil { isoUnexercisedValueUsd = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .planningIsoExerciseAndHold)) ?? nil { planningIsoExerciseAndHold = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .isoBargainElementUsd)) ?? nil { isoBargainElementUsd = v }
        if let v = (try? c.decodeIfPresent(String.self, forKey: .pending83bGrantDate)) ?? nil { pending83bGrantDate = v }
        if let v = (try? c.decodeIfPresent(Usd.self, forKey: .esppAnnualContributionUsd)) ?? nil { esppAnnualContributionUsd = v }
        if let v = (try? c.decodeIfPresent(Bps.self, forKey: .esppDiscountBps)) ?? nil { esppDiscountBps = v }
        if let v = (try? c.decodeIfPresent(Bool.self, forKey: .esppLookback)) ?? nil { esppLookback = v }
        if let v = (try? c.decodeIfPresent(QsbsStatus.self, forKey: .qsbsStatus)) ?? nil { qsbsStatus = v }
        if adults.isEmpty { adults = [IntakeAdult()] }
    }

    // Derived conveniences
    public var totalInvestableUsd: Usd { taxableUsd + traditionalUsd + rothUsd }
    public var primaryAge: Int { max(0, Self.currentYear - (adults.first?.birthYear ?? 1975)) }
}

// MARK: - Persistence (on-device JSON)

public enum IntakeStore {
    private static var url: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("wealth-policy-intake.json")
    }
    public static func save(_ intake: IntakeModel) {
        guard let url else { return }
        if let data = try? JSONEncoder().encode(intake) { try? data.write(to: url) }
    }
    public static func load() -> IntakeModel? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard var m = try? JSONDecoder().decode(IntakeModel.self, from: data) else { return nil }
        if m.adults.isEmpty { m.adults = [IntakeAdult()] }   // invariant: ≥1 adult
        return m
    }
    public static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Derived risk profile

public struct RiskProfile: Sendable, Hashable {
    public var capacityEquityBps: Bps
    public var toleranceImpliedEquityBps: Bps
    public var bindingEquityBps: Bps
    public var gapBps: Bps
    public var bindingIsCapacity: Bool
    public init(capacityEquityBps: Bps, toleranceImpliedEquityBps: Bps, bindingEquityBps: Bps, gapBps: Bps, bindingIsCapacity: Bool) {
        self.capacityEquityBps = capacityEquityBps; self.toleranceImpliedEquityBps = toleranceImpliedEquityBps
        self.bindingEquityBps = bindingEquityBps; self.gapBps = gapBps; self.bindingIsCapacity = bindingIsCapacity
    }
}

// MARK: - Build a Household from the intake

public extension IntakeModel {

    // MARK: - Risk-tolerance composition (a glass box)

    /// The stated max-loss threshold snapped to the questionnaire's discrete grid,
    /// so the chip, the readout, and the composition can never disagree.
    var statedThresholdBps: Bps { [1000, 2000, 3000, 4000].min(by: { abs($0 - lossToleranceBps) < abs($1 - lossToleranceBps) }) ?? 2000 }

    /// The behavioral temper on the stated threshold: the blend of revealed history
    /// and a stated forward reaction, each cheaper than living through a real
    /// drawdown. Averaging (not multiplying) avoids double-penalizing.
    var behaviorTemperMultiplier: Double { (pastBehavior.toleranceMultiplier + forwardLossReaction.toleranceMultiplier) / 2 }

    /// The composed max single-year drawdown tolerance: the stated threshold,
    /// tempered by behavior, tilted by which failure the client fears more.
    var effectiveMaxDrawdownBps: Bps {
        let v = Double(statedThresholdBps) * behaviorTemperMultiplier * worry.toleranceTiltMultiplier
        return max(500, min(5000, Int(v.rounded())))
    }

    /// The equity ceiling that drawdown tolerance implies (equities fall ~50% in a
    /// crash, so ceiling ≈ 2×). Mirrors Engine.toleranceEquityBps; a frontier-derived
    /// mapping replaces the 2× rule once the frontier lands.
    var impliedEquityCeilingBps: Bps { min(10000, effectiveMaxDrawdownBps * 2) }

    func buildHousehold() -> Household {
        let yr = Self.currentYear
        let primaryAge = max(0, yr - (adults.first?.birthYear ?? 1975))
        let retireStartYear = max(1, retirementStartAge - primaryAge)
        let horizon = max(retireStartYear + 1, planToAge - primaryAge)

        // People + human capital + deferred comp.
        var people: [Person] = []
        var humanCapital: [HumanCapital] = []
        var deferredComp: [DeferredCompensation] = []
        var ssProfiles: [SocialSecurityProfile] = []
        for (i, a) in adults.enumerated() {
            let pid = "p_\(i)"
            let age = max(0, yr - a.birthYear)
            let role: PersonRole = i == 0 ? .primary : .spouse
            let longevity = a.health == .excellent ? 94 : (a.health == .good ? 92 : (a.health == .fair ? 88 : 84))
            people.append(Person(id: pid, label: a.name.isEmpty ? (i == 0 ? "You" : "Spouse") : a.name,
                                 birthDate: "\(a.birthYear)-01-01", role: role, expectedRetirementAge: a.retirementAge,
                                 healthStatus: a.health, longevityPercentileTarget: longevity))
            humanCapital.append(HumanCapital(personId: pid, baseSalaryUsd: a.salaryUsd, expectedBonusUsd: a.bonusUsd,
                                             bonusVolatilityBps: a.bonusStability.volatilityBps, character: a.incomeCharacter,
                                             impliedBeta: a.incomeCharacter.impliedBeta, sector: a.sector,
                                             yearsRemaining: max(0, a.retirementAge - age), realGrowthRateBps: 100,
                                             jobLossInDrawdownProbabilityBps: a.incomeCharacter == .equityLike || a.incomeCharacter == .leveredEquity ? 3000 : 1200))
            if a.employerStockUsd > 0 {
                deferredComp.append(DeferredCompensation(id: "dc_rsu_\(i)", personId: pid, kind: .rsu, ticker: "EMPLOYER", grantValueUsd: a.employerStockUsd, subjectToEmployerCredit: false, tradingRestricted: true))
            }
            if a.deferredCashUsd > 0 {
                deferredComp.append(DeferredCompensation(id: "dc_cash_\(i)", personId: pid, kind: .deferredCash, ticker: nil, grantValueUsd: a.deferredCashUsd, subjectToEmployerCredit: true, tradingRestricted: false))
            }
            ssProfiles.append(SocialSecurityProfile(personId: pid, estimatedPIAUsd: Self.estimatedMonthlyPIA(a.salaryUsd + a.bonusUsd),
                                                    fullRetirementAge: 67, plannedClaimingAge: ssClaimAge,
                                                    eligibleForSpousalBenefit: i > 0, survivorBenefitApplies: adults.count > 1))
        }

        // Dependents on the roster (no human capital).
        for (i, ch) in children.enumerated() {
            people.append(Person(id: "c_\(i)", label: ch.name.isEmpty ? "Child \(i + 1)" : ch.name,
                                 birthDate: "\(ch.birthYear)-01-01", role: .dependent, expectedRetirementAge: 65,
                                 healthStatus: .good, longevityPercentileTarget: 90))
        }

        // Income profile.
        let sameSector = adults.count > 1 && adults[0].sector != nil && adults[0].sector == adults[1].sector
        let incomes = adults.map { $0.salaryUsd + $0.bonusUsd }
        let primaryShare = incomes.reduce(0, +) > 0 ? (incomes.first ?? 0) / incomes.reduce(0, +) : 1
        let incomeProfile = HouseholdIncomeProfile(incomeCorrelation: sameSector ? 0.75 : 0.4,
                                                   primaryShareOfIncomeBps: primaryShare.bps, survivableOnSingleIncome: survivableOnOneIncome)

        // Goals.
        let spendingOutflows = (retireStartYear...horizon).map { Outflow(year: $0, amountUsd: retirementSpendingUsd, inflationLinked: true) }
        let flex = GoalFlexibility(deferrableYears: spendingFlexibility.deferrableYears, scalableDownBps: spendingFlexibility.scalableDownBps, abandonable: false)
        var goals: [Goal] = [
            Goal(id: "g_spending", label: "Retirement spending", kind: .spending, tier: .essential, horizonYears: horizon,
                 outflows: spendingOutflows, inflationSeries: .cpi, maxShortfallProbabilityBps: 300, holdToStepUp: false,
                 flexibility: flex, policyId: "spending-glide"),
            Goal(id: "g_legacy", label: "Generational corpus", kind: .legacy, tier: .aspirational, horizonYears: nil,
                 outflows: [], inflationSeries: .cpi, maxShortfallProbabilityBps: 4000, holdToStepUp: true,
                 flexibility: GoalFlexibility(deferrableYears: 0, scalableDownBps: 5000, abandonable: false), policyId: "legacy-perpetual"),
        ]
        if emergencyReserveUsd > 0 {
            goals.append(Goal(id: "g_reserve", label: "Emergency reserve", kind: .reserve, tier: .essential, horizonYears: nil,
                              outflows: [Outflow(year: 1, amountUsd: emergencyReserveUsd, inflationLinked: false)],
                              inflationSeries: .cpi, maxShortfallProbabilityBps: 100, holdToStepUp: false, flexibility: .rigid, policyId: "legacy-perpetual"))
        }
        // Additional goals beyond retirement — each a dated spending claim.
        for (i, ag) in additionalGoals.enumerated() where ag.amountUsd > 0 {
            let start = max(1, ag.targetYear - yr)
            let span = max(1, ag.spanYears)
            let per = ag.amountUsd / Double(span)
            let outflows = (0..<span).map { Outflow(year: start + $0, amountUsd: per, inflationLinked: true) }
            goals.append(Goal(id: "g_extra_\(i)", label: ag.label.isEmpty ? ag.type.label : ag.label, kind: .spending, tier: ag.tier,
                              horizonYears: start + span - 1, outflows: outflows, inflationSeries: ag.type.defaultInflation,
                              maxShortfallProbabilityBps: ag.tier.defaultShortfallBps, holdToStepUp: false,
                              flexibility: GoalFlexibility(deferrableYears: ag.deferrableYears, scalableDownBps: ag.scalableDownBps, abandonable: ag.abandonable),
                              policyId: "spending-glide"))
        }

        // External assets: home equity + pension PV.
        var externalAssets: [ExternalAsset] = []
        let homeEquity = max(0, homeValueUsd - mortgageBalanceUsd)
        if homeEquity > 0 {
            externalAssets.append(ExternalAsset(id: "ext_home", label: "Primary residence equity", kind: .homeEquity, valueUsd: homeEquity,
                                                offsetsClaimId: "g_spending", offsetsFromYear: max(retireStartYear, horizon - 10), displacesSleeveId: "real_assets", liquidityClass: .locked))
        }
        if pensionAnnualUsd > 0 {
            externalAssets.append(ExternalAsset(id: "ext_pension", label: "Pension", kind: .pension, valueUsd: pensionAnnualUsd / 0.06,
                                                offsetsClaimId: "g_spending", offsetsFromYear: retireStartYear, displacesSleeveId: nil, liquidityClass: .selfLiquidating))
        }
        // Education goals → inflated tuition ladders (education series), offset by any 529.
        for g in educationGoals where g.annualCostTodayUsd > 0 {
            let startOffset = max(1, g.startYear - yr)
            let yrs = max(1, g.years)
            let gid = "g_edu_\(g.id.uuidString.prefix(8))"
            let childName = children.first(where: { $0.id == g.childId }).map { $0.name.isEmpty ? "Child" : $0.name }
            goals.append(Goal(id: gid, label: childName.map { "\($0) — \(g.label)" } ?? g.label, kind: .spending, tier: .lifestyle,
                              horizonYears: startOffset + yrs - 1,
                              outflows: (0..<yrs).map { Outflow(year: startOffset + $0, amountUsd: g.annualCostTodayUsd, inflationLinked: true) },
                              inflationSeries: .education, maxShortfallProbabilityBps: GoalTier.lifestyle.defaultShortfallBps, holdToStepUp: false,
                              flexibility: GoalFlexibility(deferrableYears: 1, scalableDownBps: 3000, abandonable: false), policyId: "spending-glide"))
            if g.five29BalanceUsd > 0 {
                externalAssets.append(ExternalAsset(id: "ext_529_\(g.id.uuidString.prefix(8))", label: "\(g.label) 529", kind: .education529,
                                                    valueUsd: g.five29BalanceUsd, offsetsClaimId: gid, offsetsFromYear: startOffset,
                                                    displacesSleeveId: nil, liquidityClass: .selfLiquidating))
            }
        }

        // Accounts + positions. Itemized held-away holdings are placed as REAL
        // positions (real ticker/basis/disposition); the rest of each account
        // balance is synthesized into a policy-shaped proxy.
        var accounts: [Account] = []
        var positions: [Position] = []
        var itemizedByTreatment: [AccountTaxTreatment: Usd] = [:]
        var realizedGain: Usd = 0
        func acctId(_ t: AccountTaxTreatment) -> String {
            switch t { case .taxable: return "acct_taxable"; case .taxDeferred: return "acct_trad"; case .taxFree: return "acct_roth" }
        }
        for (i, hp) in heldAwayPositions.enumerated() where hp.marketValueUsd > 0 {
            let acct = acctId(hp.treatment)
            let (disp, hold, draws) = Self.heldDisposition(plan: hp.plan, treatment: hp.treatment)
            // A dated lot makes the holding period (short vs long term) real for this holding.
            let lots: [TaxLot] = (hp.acquisitionDate?.isEmpty == false)
                ? [TaxLot(id: "\(acct)_held_\(i)_lot", marketValueUsd: hp.marketValueUsd, costBasisUsd: hp.costBasisUsd, acquisitionDate: hp.acquisitionDate!)]
                : []
            positions.append(Position(id: "\(acct)_held_\(i)_\(hp.ticker)", accountId: acct, ticker: hp.ticker.isEmpty ? "HELD\(i)" : hp.ticker,
                                      sleeveId: nil, marketValueUsd: hp.marketValueUsd, costBasisUsd: hp.costBasisUsd,
                                      layer: .strategic, disposition: disp, holdToStepUp: hold, isConcentrated: hp.isConcentrated, lots: lots))
            itemizedByTreatment[hp.treatment, default: 0] += hp.marketValueUsd
            if draws && hp.treatment == .taxable {
                let gain = max(0, hp.unrealizedGainUsd)
                realizedGain += hp.plan == .unwindImmediate ? gain : gain / Double(max(1, hp.unwindYears))
            }
        }
        func addAccount(_ id: String, _ label: String, _ treatment: AccountTaxTreatment, _ balance: Usd, _ ownership: AccountOwnership) {
            let itemized = itemizedByTreatment[treatment] ?? 0
            guard balance > 0 || itemized > 0 else { return }
            if !accounts.contains(where: { $0.id == id }) { accounts.append(Account(id: id, label: label, treatment: treatment, ownership: ownership)) }
            let remainder = max(0, balance - itemized)   // synthesize only what the client didn't itemize
            if remainder > 0 {
                positions.append(contentsOf: Self.synthesizePositions(accountId: id, treatment: treatment, balance: remainder, gainPct: taxableUnrealizedGainPct, equityPct: currentEquityPct))
            }
        }
        // Titling defaults: a taxable account is joint for a couple — community property
        // in the nine CP states (full double step-up) — else individual; retirement
        // accounts are always individually owned by the primary.
        // The nine community-property states by code AND full name — the state field is
        // free text, so "California" must resolve the same as "CA".
        let cpStates: Set<String> = ["CA", "CALIFORNIA", "TX", "TEXAS", "WA", "WASHINGTON",
                                     "AZ", "ARIZONA", "NV", "NEVADA", "NM", "NEW MEXICO",
                                     "ID", "IDAHO", "LA", "LOUISIANA", "WI", "WISCONSIN"]
        let stateKey = state.uppercased().trimmingCharacters(in: .whitespaces)
        let hasSpouse = people.contains { $0.role == .spouse }
        let autoTitling: OwnershipKind = hasSpouse ? (cpStates.contains(stateKey) ? .communityProperty : .jointWROS) : .individual
        let titling = taxableTitling ?? autoTitling                // the client's explicit choice wins
        let taxableOwnership = AccountOwnership(kind: titling, ownerPersonId: titling == .individual ? "p_0" : nil)
        let individualPrimary = AccountOwnership(kind: .individual, ownerPersonId: "p_0")
        addAccount("acct_taxable", "Taxable brokerage", .taxable, taxableUsd, taxableOwnership)
        addAccount("acct_trad", "Traditional (IRA/401k)", .taxDeferred, traditionalUsd, individualPrimary)
        addAccount("acct_roth", "Roth", .taxFree, rothUsd, individualPrimary)

        // Liabilities.
        var liabilities: [Liability] = []
        if mortgageBalanceUsd > 0 {
            liabilities.append(Liability(id: "liab_mortgage", kind: .mortgagePrimary, balanceUsd: mortgageBalanceUsd, rateBps: mortgageRateBps,
                                         fixed: mortgageFixed, maturityDate: nil, durationYears: mortgageFixed ? 7.5 : 2.0, interestDeductible: true,
                                         afterTaxRateBps: mortgageRateBps, revocable: false))
        }
        if helocUsd > 0 {
            liabilities.append(Liability(id: "liab_heloc", kind: .heloc, balanceUsd: helocUsd, rateBps: 780, fixed: false, maturityDate: nil,
                                         durationYears: 0.25, interestDeductible: false, afterTaxRateBps: 780, revocable: true))
        }
        if otherDebtUsd > 0 {
            liabilities.append(Liability(id: "liab_other", kind: .auto, balanceUsd: otherDebtUsd, rateBps: otherDebtRateBps, fixed: true, maturityDate: nil,
                                         durationYears: 3.0, interestDeductible: false, afterTaxRateBps: otherDebtRateBps, revocable: false))
        }

        // Personality → legacy floor default + effective risk tolerance.
        var floor = legacyFloorUsd
        if floor == 0 && legacyPriority == .essential { floor = totalInvestableUsd }   // preserve real principal
        if floor == 0 && legacyPriority == .niceToHave { floor = totalInvestableUsd * 0.5 }
        let effectiveTolerance = effectiveMaxDrawdownBps

        let tier = Self.tier(forInvestable: totalInvestableUsd)

        // Charitable bequest routing. Default routes the IRA (IRD) to charity;
        // choosing .taxable is the misrouting the disposition engine flags.
        if charitableBequestSource == .taxable {
            let treat = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.treatment) })
            for i in positions.indices {
                switch treat[positions[i].accountId] {
                case .taxable: positions[i].disposition = .charitableAtDeath
                case .taxDeferred: positions[i].disposition = .stepUpThenSell   // → heirs (IRD; no step-up)
                default: break
                }
            }
        }
        let estateInputs = EstateInputs(heirCount: heirCount, heirBracketBps: expectedHeirBracket.bracketBps,
                                        bequestSource: charitableBequestSource, annualGivingUsd: annualGivingUsd,
                                        qcdPlannedUsd: qcdPlannedUsd, dafBalanceUsd: dafExists ? dafBalanceUsd : 0,
                                        hasWill: hasWill, hasRevocableTrust: hasRevocableTrust, hasFinancialPOA: hasFinancialPOA,
                                        hasHealthcareDirective: hasHealthcareDirective, beneficiaryDesignationsCurrent: beneficiaryDesignationsCurrent)

        // Protection: coverage-gap profile. Each domain is assessed ONLY when the client
        // actually engaged it, so a household that filled one field (e.g. umbrella) never
        // gets phantom gaps computed from default assumptions in the domains it skipped.
        let diEngaged = disabilityGroupMonthlyUsd > 0 || disabilityIndividualMonthlyUsd > 0
        let lifeEngaged = lifeInForceUsd > 0 || lifeKind != .none
        let ltcEngaged = ltcApproach != .none || ltcDedicatedReserveUsd > 0
        let umbrellaEngaged = umbrellaLimitUsd > 0
        var protectionProfile: ProtectionProfile? = nil
        if diEngaged || lifeEngaged || ltcEngaged || umbrellaEngaged {
            let monthlyIncome = adults.reduce(0) { $0 + $1.salaryUsd + $1.bonusUsd } / 12
            let diNeed = diEngaged ? monthlyIncome * 0.60 : 0                     // 60% replacement target
            let diCoverage = diEngaged ? (disabilityIndividualMonthlyUsd + disabilityGroupMonthlyUsd * (disabilityBenefitsTaxable ? 0.72 : 1.0)) : 0
            let totalDebt = mortgageBalanceUsd + helocUsd + otherDebtUsd
            let primaryIncome = adults.first.map { $0.salaryUsd + $0.bonusUsd } ?? 0
            let survivorYears = Double(max(0, retirementStartAge - primaryAge))
            let lifeNeed = lifeEngaged ? max(0, totalDebt + 150_000 * Double(children.count) + survivorYears * primaryIncome - totalInvestableUsd) : 0
            let ltcExposure = ltcEngaged ? ltcEstimatedAnnualCostUsd * Double(max(1, ltcEstimatedDurationYears)) * (adults.count > 1 ? 2 : 1) : 0
            let ltcUnfunded: Usd
            if !ltcEngaged {
                ltcUnfunded = 0
            } else {
                switch ltcApproach {
                case .selfFund, .none: ltcUnfunded = max(0, ltcExposure - ltcDedicatedReserveUsd)  // .none w/ a reserve nets it
                case .traditionalLtc, .hybrid: ltcUnfunded = 0
                }
            }
            protectionProfile = ProtectionProfile(
                disabilityNeedMonthlyUsd: diNeed, disabilityCoverageMonthlyUsd: diCoverage, disabilityGapMonthlyUsd: max(0, diNeed - diCoverage),
                disabilityOwnOccupation: disabilityOwnOccupation,
                disabilityGroupOnlyTaxable: diEngaged && disabilityIndividualMonthlyUsd == 0 && disabilityBenefitsTaxable && disabilityGroupMonthlyUsd > 0,
                lifeNeedUsd: lifeNeed, lifeInForceUsd: lifeInForceUsd, lifeGapUsd: max(0, lifeNeed - lifeInForceUsd),
                ltcApproach: ltcApproach, ltcTotalExposureUsd: ltcExposure, ltcUnfundedUsd: ltcUnfunded, umbrellaLimitUsd: umbrellaLimitUsd)
        }

        // Equity comp mechanics + options/ESPP legs (single-employer exposure).
        var equityMechanics: EquityCompMechanics? = nil
        if !equityGrantTypes.isEmpty {
            equityMechanics = EquityCompMechanics(grantTypes: equityGrantTypes, isInsider: isCompanyInsider, tradingWindow: tradingWindow,
                                                  has10b51Plan: has10b51Plan, plannedExerciseAndHold: planningIsoExerciseAndHold,
                                                  isoBargainElementUsd: isoBargainElementUsd, pending83bGrantDate: pending83bGrantDate, qsbs: qsbsStatus)
            let pid = people.first(where: { $0.role == .primary })?.id ?? "p_0"
            if (equityGrantTypes.contains(.iso) || equityGrantTypes.contains(.nso)) && isoUnexercisedValueUsd > 0 {
                deferredComp.append(DeferredCompensation(id: "dc_opt", personId: pid, kind: .options, ticker: "EMPLOYER", grantValueUsd: isoUnexercisedValueUsd, subjectToEmployerCredit: false, tradingRestricted: tradingWindow != .open))
            }
            if equityGrantTypes.contains(.espp) && esppAnnualContributionUsd > 0 {
                deferredComp.append(DeferredCompensation(id: "dc_espp", personId: pid, kind: .espp, ticker: "EMPLOYER", grantValueUsd: esppAnnualContributionUsd, subjectToEmployerCredit: false, tradingRestricted: false))
            }
        }

        return Household(
            id: "hh_custom", name: adults.first?.name.isEmpty == false ? "\(adults[0].name)'s plan" : "Your plan",
            filingStatus: filingStatus, stateOfResidence: state, people: people, humanCapital: humanCapital,
            deferredComp: deferredComp, incomeProfile: incomeProfile, socialSecurity: ssProfiles, goals: goals,
            externalAssets: externalAssets, eligibilityTierId: tier, accounts: accounts, positions: positions,
            liabilities: liabilities, annualSavingsUsd: annualSavingsUsd, legacyFloorUsd: floor,
            statedToleranceMaxDrawdownBps: effectiveTolerance,
            transitionGainBudgetUsd: annualGainBudgetUsd, transitionAnnualRealizedGainUsd: realizedGain,
            permanentHoldPolicy: permanentHoldPolicy, estate: estateInputs, protection: protectionProfile, equityComp: equityMechanics)
    }

    /// (Disposition, holdToStepUp, drawsTaxableGainBudget) for a held-away plan.
    /// Step-up earmarks are taxable-only; unwinds are `.consume` (never step-up).
    static func heldDisposition(plan: HeldPositionTreatment, treatment: AccountTaxTreatment) -> (Disposition, Bool, Bool) {
        switch plan {
        case .keepAsCore, .keepAsTlhPartner:
            return (treatment == .taxDeferred ? .charitableAtDeath : .stepUpThenSell, false, false)
        case .unwindScheduled, .unwindImmediate:
            return (.consume, false, true)
        case .permanentHold:
            if treatment == .taxable { return (.holdToStepUp, true, false) }
            return (treatment == .taxDeferred ? .charitableAtDeath : .stepUpThenSell, false, false)
        case .giftOrDonate:
            return (.giftDuringLife, false, false)
        }
    }

    // MARK: builder helpers

    /// Rough Social Security PIA (monthly, at FRA) from current earnings — a
    /// replacement-rate heuristic capped near the program maximum.
    static func estimatedMonthlyPIA(_ annualIncome: Usd) -> Usd {
        let capped = min(annualIncome, 176_100)          // ~2025 SS wage base
        return min(4_000, 0.34 * capped / 12)
    }

    static func tier(forInvestable v: Usd) -> String {
        if v >= 10_000_000 { return "tier_4" }
        if v >= 2_000_000 { return "tier_3" }
        if v >= 350_000 { return "tier_2" }
        return "tier_1"
    }

    /// Synthesize the account's CURRENT holdings from the client's actual equity
    /// share (`equityPct`) — not the policy target — so the as-is-vs-target gap on
    /// the Allocation tab is real, not zero-by-construction. Within each bucket the
    /// shape follows policy (the client knows their stock/bond split, not the
    /// sub-sleeve detail); taxable lots carry the entered gain; core is step-up-held.
    static func synthesizePositions(accountId: String, treatment: AccountTaxTreatment, balance: Usd, gainPct: Double, equityPct: Double) -> [Position] {
        let sleeves = Seed.legacyPolicy.sleeves
        guard balance > 0 else { return [] }
        let eq = max(0, min(1, equityPct))
        let core = sleeves.first { $0.id == "us_large_core" } ?? sleeves[0]
        var out: [Position] = []

        // Two buckets by role. Each holds exactly its dollars: distribute across the
        // bucket's sleeves by structural weight, drop sub-ticket sleeves, and
        // RE-NORMALIZE the survivors to the full bucket — so the growth share stays
        // exactly eq (what feeds resilience/risk) and only sub-sleeve detail coarsens.
        out += fillBucket(sleeves.filter { $0.role == .growth }, dollars: balance * eq,
                          accountId: accountId, treatment: treatment, gainPct: gainPct)
        out += fillBucket(sleeves.filter { $0.role != .growth }, dollars: balance * (1 - eq),
                          accountId: accountId, treatment: treatment, gainPct: gainPct)
        return out.isEmpty ? [position(core, accountId: accountId, treatment: treatment, value: balance, gainPct: gainPct)] : out
    }

    /// Fill one asset-role bucket with `dollars`, split by the sleeves' structural
    /// weights (survivors ≥ $500 renormalized to the exact bucket total).
    private static func fillBucket(_ bucket: [Sleeve], dollars: Usd, accountId: String, treatment: AccountTaxTreatment, gainPct: Double) -> [Position] {
        guard dollars > 0, !bucket.isEmpty else { return [] }
        let weight = Double(max(1, bucket.reduce(0) { $0 + $1.targetBps }))
        let survivors = bucket.map { ($0, dollars * Double($0.targetBps) / weight) }.filter { $0.1 >= 500 }
        let sum = survivors.reduce(0) { $0 + $1.1 }
        if sum > 0 {
            return survivors.map { position($0.0, accountId: accountId, treatment: treatment, value: $0.1 * dollars / sum, gainPct: gainPct) }
        }
        return [position(bucket[0], accountId: accountId, treatment: treatment, value: dollars, gainPct: gainPct)]
    }

    private static func position(_ s: Sleeve, accountId: String, treatment: AccountTaxTreatment, value: Usd, gainPct: Double) -> Position {
        let disposition: Disposition
        let holdToStepUp: Bool
        switch treatment {
        case .taxable:
            holdToStepUp = (s.id == "us_large_core")
            disposition = holdToStepUp ? .holdToStepUp : .stepUpThenSell
        case .taxDeferred:
            holdToStepUp = false; disposition = .charitableAtDeath
        case .taxFree:
            holdToStepUp = false; disposition = .stepUpThenSell
        }
        let basis = treatment == .taxable ? value * (1 - max(0, min(0.95, gainPct))) : value
        return Position(id: "\(accountId)_\(s.id)", accountId: accountId, ticker: s.primaryTicker, sleeveId: s.id,
                        marketValueUsd: value, costBasisUsd: basis, layer: .strategic, disposition: disposition, holdToStepUp: holdToStepUp)
    }
}
