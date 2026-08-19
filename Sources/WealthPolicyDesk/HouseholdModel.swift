//  HouseholdModel.swift
//  WealthPolicyDesk
//
//  Ported from src/household-module.ts and the goal-claim / external-asset
//  types of src/policy-schema-v2.ts.
//
//  The household is a TOTAL BALANCE SHEET. Human capital (future income) is an
//  asset with an equity beta and a sector. Goals are claims on the corpus, and
//  goal flexibility — deferring, scaling, abandoning — is a stronger risk lever
//  than allocation.

import Foundation

// MARK: - People and human capital

public enum PersonRole: String, CaseIterable, Sendable, Hashable { case primary, spouse, dependent }
public enum HealthStatus: String, CaseIterable, Sendable, Hashable { case excellent, good, fair, poor }

public struct Person: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var birthDate: IsoDate
    public var role: PersonRole
    public var expectedRetirementAge: Int
    public var healthStatus: HealthStatus
    /// Plan to a high percentile, not life expectancy.
    public var longevityPercentileTarget: Int
    public init(id: String, label: String, birthDate: IsoDate, role: PersonRole, expectedRetirementAge: Int, healthStatus: HealthStatus, longevityPercentileTarget: Int) {
        self.id = id; self.label = label; self.birthDate = birthDate; self.role = role
        self.expectedRetirementAge = expectedRetirementAge; self.healthStatus = healthStatus
        self.longevityPercentileTarget = longevityPercentileTarget
    }
}

/// THE field meant to drive portfolio equity capacity.
public enum IncomeCharacter: String, CaseIterable, Sendable, Hashable {
    case bondLike = "bond_like", moderate, equityLike = "equity_like", leveredEquity = "levered_equity"
    public var label: String {
        switch self {
        case .bondLike: return "Bond-like"
        case .moderate: return "Moderate"
        case .equityLike: return "Equity-like"
        case .leveredEquity: return "Levered equity"
        }
    }
    /// Income beta to equities implied by character (a default; overridable).
    public var impliedBeta: Double {
        switch self {
        case .bondLike: return 0.10
        case .moderate: return 0.35
        case .equityLike: return 0.70
        case .leveredEquity: return 1.10
        }
    }
}

/// Income as an asset. Present value is computed by the engine.
public struct HumanCapital: Identifiable, Sendable, Hashable {
    public var id: String { personId }
    public var personId: String
    public var baseSalaryUsd: Usd
    public var expectedBonusUsd: Usd
    public var bonusVolatilityBps: Bps
    public var character: IncomeCharacter
    public var impliedBeta: Double
    public var sector: Sector?
    public var yearsRemaining: Int
    public var realGrowthRateBps: Bps
    /// Correlation of job loss with a market drawdown.
    public var jobLossInDrawdownProbabilityBps: Bps
    public init(personId: String, baseSalaryUsd: Usd, expectedBonusUsd: Usd, bonusVolatilityBps: Bps, character: IncomeCharacter, impliedBeta: Double, sector: Sector?, yearsRemaining: Int, realGrowthRateBps: Bps, jobLossInDrawdownProbabilityBps: Bps) {
        self.personId = personId; self.baseSalaryUsd = baseSalaryUsd; self.expectedBonusUsd = expectedBonusUsd
        self.bonusVolatilityBps = bonusVolatilityBps; self.character = character; self.impliedBeta = impliedBeta
        self.sector = sector; self.yearsRemaining = yearsRemaining; self.realGrowthRateBps = realGrowthRateBps
        self.jobLossInDrawdownProbabilityBps = jobLossInDrawdownProbabilityBps
    }
    public var annualIncomeUsd: Usd { baseSalaryUsd + expectedBonusUsd }
}

public struct DeferredCompensation: Identifiable, Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable, Hashable { case rsu, options, deferredCash = "deferred_cash", carry, espp }
    public var id: String
    public var personId: String
    public var kind: Kind
    public var ticker: String?
    public var grantValueUsd: Usd
    /// Deferred cash = an unsecured claim on the employer.
    public var subjectToEmployerCredit: Bool
    public var tradingRestricted: Bool
    public init(id: String, personId: String, kind: Kind, ticker: String?, grantValueUsd: Usd, subjectToEmployerCredit: Bool, tradingRestricted: Bool) {
        self.id = id; self.personId = personId; self.kind = kind; self.ticker = ticker
        self.grantValueUsd = grantValueUsd; self.subjectToEmployerCredit = subjectToEmployerCredit
        self.tradingRestricted = tradingRestricted
    }
}

public struct HouseholdIncomeProfile: Sendable, Hashable {
    /// 0–1 correlation between the two earners' incomes.
    public var incomeCorrelation: Double
    public var primaryShareOfIncomeBps: Bps
    public var survivableOnSingleIncome: Bool
    public init(incomeCorrelation: Double, primaryShareOfIncomeBps: Bps, survivableOnSingleIncome: Bool) {
        self.incomeCorrelation = incomeCorrelation; self.primaryShareOfIncomeBps = primaryShareOfIncomeBps
        self.survivableOnSingleIncome = survivableOnSingleIncome
    }
}

public struct SocialSecurityProfile: Identifiable, Sendable, Hashable {
    public var id: String { personId }
    public var personId: String
    /// Monthly primary insurance amount at full retirement age.
    public var estimatedPIAUsd: Usd
    public var fullRetirementAge: Int
    public var plannedClaimingAge: Int
    public var eligibleForSpousalBenefit: Bool
    public var survivorBenefitApplies: Bool
    public init(personId: String, estimatedPIAUsd: Usd, fullRetirementAge: Int, plannedClaimingAge: Int, eligibleForSpousalBenefit: Bool, survivorBenefitApplies: Bool) {
        self.personId = personId; self.estimatedPIAUsd = estimatedPIAUsd; self.fullRetirementAge = fullRetirementAge
        self.plannedClaimingAge = plannedClaimingAge; self.eligibleForSpousalBenefit = eligibleForSpousalBenefit
        self.survivorBenefitApplies = survivorBenefitApplies
    }
}

// MARK: - Goals as claims on the corpus

public enum GoalKind: String, CaseIterable, Sendable, Hashable {
    case spending    // funds a known outflow schedule
    case legacy      // perpetual; the generational corpus
    case reserve     // emergency liquidity, never invested at risk
    public var label: String { rawValue.capitalized }
}

public enum GoalTier: String, CaseIterable, Sendable, Hashable {
    case essential, lifestyle, aspirational
    /// Default shortfall tolerance in bps by tier (overridable per goal).
    public var defaultShortfallBps: Bps {
        switch self {
        case .essential: return 300
        case .lifestyle: return 1500
        case .aspirational: return 3500
        }
    }
}

public enum InflationSeries: String, CaseIterable, Sendable, Hashable {
    case cpi, education, healthcare, construction
    /// Real growth rate above CPI in bps (education and healthcare outrun CPI).
    public var realExcessBps: Bps {
        switch self {
        case .cpi: return 0
        case .education: return 250
        case .healthcare: return 200
        case .construction: return 100
        }
    }
}

public struct Outflow: Sendable, Hashable {
    public var year: Int
    public var amountUsd: Usd
    public var inflationLinked: Bool
    public init(year: Int, amountUsd: Usd, inflationLinked: Bool) {
        self.year = year; self.amountUsd = amountUsd; self.inflationLinked = inflationLinked
    }
}

/// The underused lever.
public struct GoalFlexibility: Sendable, Hashable {
    public var deferrableYears: Int
    public var scalableDownBps: Bps
    public var abandonable: Bool
    public init(deferrableYears: Int, scalableDownBps: Bps, abandonable: Bool) {
        self.deferrableYears = deferrableYears; self.scalableDownBps = scalableDownBps; self.abandonable = abandonable
    }
    public static let rigid = GoalFlexibility(deferrableYears: 0, scalableDownBps: 0, abandonable: false)
}

/// A goal AND a claim on the corpus (merging the intake `Goal` with the
/// `GoalClaim`). Everything the allocation and required-return engines need.
public struct Goal: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var kind: GoalKind
    public var tier: GoalTier
    /// Null horizon = perpetual. Only legacy claims may be null.
    public var horizonYears: Int?
    /// Outflow schedule in today's dollars. Inflated by the engine.
    public var outflows: [Outflow]
    public var inflationSeries: InflationSeries
    /// Shortfall tolerance — this, not volatility, is the risk definition.
    public var maxShortfallProbabilityBps: Bps
    /// Lots earmarked here are held to step-up; a taxable sale is a VIOLATION.
    public var holdToStepUp: Bool
    public var flexibility: GoalFlexibility
    /// Which policy governs this claim. Spending glides; legacy does not.
    public var policyId: String
    public init(id: String, label: String, kind: GoalKind, tier: GoalTier, horizonYears: Int?, outflows: [Outflow], inflationSeries: InflationSeries, maxShortfallProbabilityBps: Bps, holdToStepUp: Bool, flexibility: GoalFlexibility, policyId: String) {
        self.id = id; self.label = label; self.kind = kind; self.tier = tier; self.horizonYears = horizonYears
        self.outflows = outflows; self.inflationSeries = inflationSeries
        self.maxShortfallProbabilityBps = maxShortfallProbabilityBps; self.holdToStepUp = holdToStepUp
        self.flexibility = flexibility; self.policyId = policyId
    }
    /// Undiscounted, un-inflated sum of scheduled outflows (today's dollars).
    public var nominalTodayUsd: Usd { outflows.reduce(0) { $0 + $1.amountUsd } }
}

/// Assets outside the portfolio that offset claims. Home equity belongs here,
/// NOT in the bond sleeve: it can't fund a drawdown, can't be rebalanced from,
/// and HELOC access evaporates in exactly the scenario bonds exist for.
public struct ExternalAsset: Identifiable, Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable, Hashable {
        case homeEquity = "home_equity", pension, socialSecurity = "social_security", business, education529 = "education_529", other
        public var label: String {
            switch self {
            case .homeEquity: return "Home equity"
            case .pension: return "Pension"
            case .socialSecurity: return "Social Security"
            case .business: return "Business"
            case .education529: return "529 plan"
            case .other: return "Other"
            }
        }
    }
    public var id: String
    public var label: String
    public var kind: Kind
    public var valueUsd: Usd
    /// Which claim's outflows this reduces.
    public var offsetsClaimId: String?
    /// Only offsets outflows at or beyond this year.
    public var offsetsFromYear: Int
    /// Sleeve whose need this displaces, if any. Home equity → real assets.
    public var displacesSleeveId: String?
    public var liquidityClass: LiquidityClass
    public init(id: String, label: String, kind: Kind, valueUsd: Usd, offsetsClaimId: String?, offsetsFromYear: Int, displacesSleeveId: String?, liquidityClass: LiquidityClass) {
        self.id = id; self.label = label; self.kind = kind; self.valueUsd = valueUsd
        self.offsetsClaimId = offsetsClaimId; self.offsetsFromYear = offsetsFromYear
        self.displacesSleeveId = displacesSleeveId; self.liquidityClass = liquidityClass
    }
}

// MARK: - The current portfolio (accounts and positions)

public struct Account: Identifiable, Sendable, Hashable {
    public var id: String
    public var label: String
    public var treatment: AccountTaxTreatment
    /// Who owns it — titling drives the basis step-up at death. Defaults to individual.
    public var ownership: AccountOwnership = .individual
    public init(id: String, label: String, treatment: AccountTaxTreatment, ownership: AccountOwnership = .individual) {
        self.id = id; self.label = label; self.treatment = treatment; self.ownership = ownership
    }
}

/// A held position (aggregated tax lot). Carries its sleeve mapping, its layer,
/// its terminal disposition, and whether it is earmarked to step-up.
public struct Position: Identifiable, Sendable, Hashable {
    public var id: String
    public var accountId: String
    public var ticker: String
    /// Which policy sleeve this maps to (nil = unclassified / legacy holding).
    public var sleeveId: String?
    public var marketValueUsd: Usd
    public var costBasisUsd: Usd
    public var layer: Layer
    public var disposition: Disposition
    public var holdToStepUp: Bool
    /// The advisor/client flagged this as a concentrated single-name risk.
    public var isConcentrated: Bool
    /// Explicit GICS sector, when known. nil = infer from the ticker (a Select
    /// Sector SPDR) or treat as broad/unclassified. Lets a within-sleeve sector
    /// rotation (XLK → XLP) be visible even though both share one policy sleeve.
    public var sector: Sector?
    /// Real tax lots, when known. Empty = a single aggregated lot of unknown vintage,
    /// treated as long-term (the app's original behaviour). When non-empty the lots
    /// detail the position — their market values and bases sum to this position's — and
    /// carry acquisition dates, so a realized gain splits into short- vs long-term.
    public var lots: [TaxLot] = []
    public init(id: String, accountId: String, ticker: String, sleeveId: String?, marketValueUsd: Usd, costBasisUsd: Usd, layer: Layer, disposition: Disposition, holdToStepUp: Bool, isConcentrated: Bool = false, sector: Sector? = nil, lots: [TaxLot] = []) {
        self.id = id; self.accountId = accountId; self.ticker = ticker; self.sleeveId = sleeveId
        self.marketValueUsd = marketValueUsd; self.costBasisUsd = costBasisUsd; self.layer = layer
        self.disposition = disposition; self.holdToStepUp = holdToStepUp; self.isConcentrated = isConcentrated
        self.sector = sector; self.lots = lots
    }
    public var unrealizedGainUsd: Usd { marketValueUsd - costBasisUsd }
    /// Best-effort sector: the explicit one, else inferred from a SPDR ticker.
    public var effectiveSector: Sector? { sector ?? Sector.fromSpdr(ticker) }
    public var basisRatioBps: Bps { marketValueUsd > 0 ? (costBasisUsd / marketValueUsd).bps : 10_000 }
}

// MARK: - Estate & giving inputs

/// Estate/charitable inputs captured at intake: who inherits and in what
/// bracket, the charitable machinery, and whether the documents to execute any
/// of it exist. Feeds the disposition routing and estate-readiness readouts.
public struct EstateInputs: Sendable, Hashable {
    public var heirCount: Int
    public var heirBracketBps: Bps
    public var bequestSource: BequestSource
    public var annualGivingUsd: Usd
    public var qcdPlannedUsd: Usd
    public var dafBalanceUsd: Usd
    public var hasWill: Bool
    public var hasRevocableTrust: Bool
    public var hasFinancialPOA: Bool
    public var hasHealthcareDirective: Bool
    public var beneficiaryDesignationsCurrent: Bool
    public init(heirCount: Int = 0, heirBracketBps: Bps = 0, bequestSource: BequestSource = .none, annualGivingUsd: Usd = 0, qcdPlannedUsd: Usd = 0, dafBalanceUsd: Usd = 0, hasWill: Bool = false, hasRevocableTrust: Bool = false, hasFinancialPOA: Bool = false, hasHealthcareDirective: Bool = false, beneficiaryDesignationsCurrent: Bool = false) {
        self.heirCount = heirCount; self.heirBracketBps = heirBracketBps; self.bequestSource = bequestSource
        self.annualGivingUsd = annualGivingUsd; self.qcdPlannedUsd = qcdPlannedUsd; self.dafBalanceUsd = dafBalanceUsd
        self.hasWill = hasWill; self.hasRevocableTrust = hasRevocableTrust; self.hasFinancialPOA = hasFinancialPOA
        self.hasHealthcareDirective = hasHealthcareDirective; self.beneficiaryDesignationsCurrent = beneficiaryDesignationsCurrent
    }
    /// The core documents a plan needs in place to execute.
    public var docsComplete: Bool { hasWill && hasFinancialPOA && hasHealthcareDirective && beneficiaryDesignationsCurrent }
    public var missingDocs: [String] {
        var m: [String] = []
        if !hasWill { m.append("will") }
        if !hasFinancialPOA { m.append("financial POA") }
        if !hasHealthcareDirective { m.append("healthcare directive") }
        if !beneficiaryDesignationsCurrent { m.append("current beneficiary designations") }
        return m
    }
}

// MARK: - Protection (coverage vs need)

/// Insurance coverage against the four tails, with derived gaps. The desk
/// detects gaps; it does not quote. All needs are documented heuristics.
public struct ProtectionProfile: Sendable, Hashable {
    public var disabilityNeedMonthlyUsd: Usd
    public var disabilityCoverageMonthlyUsd: Usd
    public var disabilityGapMonthlyUsd: Usd
    public var disabilityOwnOccupation: Bool
    public var disabilityGroupOnlyTaxable: Bool
    public var lifeNeedUsd: Usd
    public var lifeInForceUsd: Usd
    public var lifeGapUsd: Usd
    public var ltcApproach: LtcApproach
    public var ltcTotalExposureUsd: Usd
    public var ltcUnfundedUsd: Usd
    public var umbrellaLimitUsd: Usd
    public init(disabilityNeedMonthlyUsd: Usd, disabilityCoverageMonthlyUsd: Usd, disabilityGapMonthlyUsd: Usd, disabilityOwnOccupation: Bool, disabilityGroupOnlyTaxable: Bool, lifeNeedUsd: Usd, lifeInForceUsd: Usd, lifeGapUsd: Usd, ltcApproach: LtcApproach, ltcTotalExposureUsd: Usd, ltcUnfundedUsd: Usd, umbrellaLimitUsd: Usd) {
        self.disabilityNeedMonthlyUsd = disabilityNeedMonthlyUsd; self.disabilityCoverageMonthlyUsd = disabilityCoverageMonthlyUsd
        self.disabilityGapMonthlyUsd = disabilityGapMonthlyUsd; self.disabilityOwnOccupation = disabilityOwnOccupation
        self.disabilityGroupOnlyTaxable = disabilityGroupOnlyTaxable; self.lifeNeedUsd = lifeNeedUsd
        self.lifeInForceUsd = lifeInForceUsd; self.lifeGapUsd = lifeGapUsd; self.ltcApproach = ltcApproach
        self.ltcTotalExposureUsd = ltcTotalExposureUsd; self.ltcUnfundedUsd = ltcUnfundedUsd; self.umbrellaLimitUsd = umbrellaLimitUsd
    }
}

/// Timing-critical equity-comp mechanics — a flag-and-schedule surface, not a
/// tax calculator.
public struct EquityCompMechanics: Sendable, Hashable {
    public var grantTypes: [EquityGrantType]
    public var isInsider: Bool
    public var tradingWindow: TradingWindowStatus
    public var has10b51Plan: Bool
    public var plannedExerciseAndHold: Bool
    public var isoBargainElementUsd: Usd
    public var pending83bGrantDate: String   // empty = none pending
    public var qsbs: QsbsStatus
    public init(grantTypes: [EquityGrantType], isInsider: Bool, tradingWindow: TradingWindowStatus, has10b51Plan: Bool, plannedExerciseAndHold: Bool, isoBargainElementUsd: Usd, pending83bGrantDate: String, qsbs: QsbsStatus) {
        self.grantTypes = grantTypes; self.isInsider = isInsider; self.tradingWindow = tradingWindow
        self.has10b51Plan = has10b51Plan; self.plannedExerciseAndHold = plannedExerciseAndHold
        self.isoBargainElementUsd = isoBargainElementUsd; self.pending83bGrantDate = pending83bGrantDate; self.qsbs = qsbs
    }
}

// MARK: - The household aggregate root

public struct Household: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var filingStatus: FilingStatus
    public var stateOfResidence: String
    public var people: [Person]
    public var humanCapital: [HumanCapital]
    public var deferredComp: [DeferredCompensation]
    public var incomeProfile: HouseholdIncomeProfile
    public var socialSecurity: [SocialSecurityProfile]
    public var goals: [Goal]
    public var externalAssets: [ExternalAsset]
    public var eligibilityTierId: String
    public var accounts: [Account]
    public var positions: [Position]
    public var liabilities: [Liability]
    /// Real (above-inflation) savings added to the corpus each year until the
    /// primary earner retires. Drives the funding side of required return.
    public var annualSavingsUsd: Usd

    /// Terminal-wealth floor for the legacy claim (today's dollars). The required
    /// return solves so the corpus ENDS at this value rather than at zero.
    /// Defaults to 0 — a pure spend-down that prices the legacy claim at nothing.
    /// Raise it to fund a perpetual corpus and watch the required return climb.
    public var legacyFloorUsd: Usd

    /// Stated maximum single-year drawdown the household could tolerate (bps),
    /// after tempering for revealed past behavior. 0 = not elicited. Drives the
    /// tolerance-vs-capacity risk readout.
    public var statedToleranceMaxDrawdownBps: Bps

    /// Committed tactical tilts (sentiment-sourced sleeve deviations). Carried on the
    /// household so the engine can deviate the tactical target from the strategic one.
    /// Defaulted, so no construction site needs to change.
    public var tacticalTilts: [TacticalTiltAction] = []

    /// Transition: annual realized-gain budget (0 = not set), the currently
    /// scheduled annual realized gain from unwinding held-away positions, and
    /// the policy for positions that will never be sold.
    public var transitionGainBudgetUsd: Usd
    public var transitionAnnualRealizedGainUsd: Usd
    public var permanentHoldPolicy: PermanentHoldPolicy

    /// Estate & giving inputs (heirs, charitable, documents).
    public var estate: EstateInputs
    /// Insurance coverage-gap profile (nil = protection not assessed).
    public var protection: ProtectionProfile?
    /// Equity-comp mechanics for the primary earner (nil = none).
    public var equityComp: EquityCompMechanics?

    public init(id: String, name: String, filingStatus: FilingStatus, stateOfResidence: String, people: [Person], humanCapital: [HumanCapital], deferredComp: [DeferredCompensation], incomeProfile: HouseholdIncomeProfile, socialSecurity: [SocialSecurityProfile], goals: [Goal], externalAssets: [ExternalAsset], eligibilityTierId: String, accounts: [Account], positions: [Position], liabilities: [Liability], annualSavingsUsd: Usd, legacyFloorUsd: Usd = 0, statedToleranceMaxDrawdownBps: Bps = 0, transitionGainBudgetUsd: Usd = 0, transitionAnnualRealizedGainUsd: Usd = 0, permanentHoldPolicy: PermanentHoldPolicy = .absorbIntoMatrix, estate: EstateInputs = .init(), protection: ProtectionProfile? = nil, equityComp: EquityCompMechanics? = nil) {
        self.id = id; self.name = name; self.filingStatus = filingStatus; self.stateOfResidence = stateOfResidence
        self.people = people; self.humanCapital = humanCapital; self.deferredComp = deferredComp
        self.incomeProfile = incomeProfile; self.socialSecurity = socialSecurity; self.goals = goals
        self.externalAssets = externalAssets; self.eligibilityTierId = eligibilityTierId
        self.accounts = accounts; self.positions = positions; self.liabilities = liabilities
        self.annualSavingsUsd = annualSavingsUsd; self.legacyFloorUsd = legacyFloorUsd
        self.statedToleranceMaxDrawdownBps = statedToleranceMaxDrawdownBps
        self.transitionGainBudgetUsd = transitionGainBudgetUsd
        self.transitionAnnualRealizedGainUsd = transitionAnnualRealizedGainUsd
        self.permanentHoldPolicy = permanentHoldPolicy
        self.estate = estate
        self.protection = protection
        self.equityComp = equityComp
    }

    // Convenience aggregates used across the engine and UI.
    public var portfolioValueUsd: Usd { positions.reduce(0) { $0 + $1.marketValueUsd } }
    public func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    public func treatment(of position: Position) -> AccountTaxTreatment { account(position.accountId)?.treatment ?? .taxable }
    public var primary: Person? { people.first { $0.role == .primary } }
    public func positions(in treatment: AccountTaxTreatment) -> [Position] {
        positions.filter { account($0.accountId)?.treatment == treatment }
    }
    public func value(in treatment: AccountTaxTreatment) -> Usd {
        positions(in: treatment).reduce(0) { $0 + $1.marketValueUsd }
    }
}
