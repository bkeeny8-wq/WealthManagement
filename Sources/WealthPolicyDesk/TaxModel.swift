//  TaxModel.swift
//  WealthPolicyDesk
//
//  Ported from src/tax-disposition-module.ts.
//
//  Two things live here. First, US federal tax law as EDITABLE, EFFECTIVE-DATED
//  data (not year-keyed) — law changes mid-year, sometimes retroactively, and a
//  delivered plan must reproduce what it said under the law as it stood. Second,
//  the terminal-disposition types: for a perpetual corpus the death-treatment
//  decision (step-up vs IRD vs carryover) is worth more than most lifetime
//  decisions, and it propagates backward into what you hold and where.
//
//  Scope: federal only. State materially shifts the muni crossover and the Roth
//  conversion breakeven — the RANKING mostly survives, the magnitude doesn't.

import Foundation

// MARK: - Bracket data

public struct BracketRow: Sendable, Hashable {
    /// Upper edge of the bracket, or nil for the top (open-ended) bracket.
    public var upToUsd: Usd?
    public var rateBps: Bps
    public init(upToUsd: Usd?, rateBps: Bps) { self.upToUsd = upToUsd; self.rateBps = rateBps }
}

/// SALT cap mechanics, including the phase-down band where an extra dollar of
/// income both taxes that dollar AND erodes the deduction — a real cliff.
public struct SaltParameters: Sendable, Hashable {
    public var capUsd: [FilingStatus: Usd]
    public var phaseDownThresholdUsd: [FilingStatus: Usd]
    public var phaseDownRatePerDollar: Double
    public var phaseDownFloorUsd: [FilingStatus: Usd]
    /// Deduction value is rate-dependent; benefit capped at ~35c/$.
    public var topBracketBenefitCapBps: Bps
    public var mortgageInterestAcquisitionDebtLimitUsd: Usd
    public init(capUsd: [FilingStatus: Usd], phaseDownThresholdUsd: [FilingStatus: Usd], phaseDownRatePerDollar: Double, phaseDownFloorUsd: [FilingStatus: Usd], topBracketBenefitCapBps: Bps, mortgageInterestAcquisitionDebtLimitUsd: Usd) {
        self.capUsd = capUsd; self.phaseDownThresholdUsd = phaseDownThresholdUsd
        self.phaseDownRatePerDollar = phaseDownRatePerDollar; self.phaseDownFloorUsd = phaseDownFloorUsd
        self.topBracketBenefitCapBps = topBracketBenefitCapBps
        self.mortgageInterestAcquisitionDebtLimitUsd = mortgageInterestAcquisitionDebtLimitUsd
    }
}

public struct EstateParameters: Sendable, Hashable {
    /// Unified estate/gift/GST exemption per person.
    public var lifetimeExemptionUsd: Usd
    public var portabilityAvailable: Bool
    public var topRateBps: Bps
    public var annualGiftExclusionUsd: Usd
    public var inflationIndexed: Bool
    public init(lifetimeExemptionUsd: Usd, portabilityAvailable: Bool, topRateBps: Bps, annualGiftExclusionUsd: Usd, inflationIndexed: Bool) {
        self.lifetimeExemptionUsd = lifetimeExemptionUsd; self.portabilityAvailable = portabilityAvailable
        self.topRateBps = topRateBps; self.annualGiftExclusionUsd = annualGiftExclusionUsd; self.inflationIndexed = inflationIndexed
    }
}

public struct IrmaaTier: Sendable, Hashable {
    public var magiOverUsd: Usd
    public var monthlySurchargeUsd: Usd
    public init(magiOverUsd: Usd, monthlySurchargeUsd: Usd) { self.magiOverUsd = magiOverUsd; self.monthlySurchargeUsd = monthlySurchargeUsd }
}

public struct ScheduledChange: Identifiable, Sendable, Hashable {
    public enum Certainty: String, Sendable, Hashable { case enacted, scheduledSunset = "scheduled_sunset", proposed }
    public var id: String { effectiveFrom + parameter }
    public var effectiveFrom: IsoDate
    public var parameter: String
    public var description: String
    public var certainty: Certainty
    public init(effectiveFrom: IsoDate, parameter: String, description: String, certainty: Certainty) {
        self.effectiveFrom = effectiveFrom; self.parameter = parameter; self.description = description; self.certainty = certainty
    }
}

/// Effective-dated, versioned snapshot of federal tax law. Stamp `version` into
/// every saved plan so it can be re-run under the law as it stood.
public struct TaxParameterSet: Identifiable, Sendable, Hashable {
    public var version: String
    public var effectiveFrom: IsoDate
    public var effectiveTo: IsoDate?
    public var lastVerifiedAt: IsoDate
    public var sources: [String]
    public var standardDeduction: [FilingStatus: Usd]
    public var ordinaryBrackets: [FilingStatus: [BracketRow]]
    public var ltcgBreakpoints: [FilingStatus: [BracketRow]]
    public var salt: SaltParameters
    public var estate: EstateParameters
    public var niitThreshold: [FilingStatus: Usd]
    public var niitRateBps: Bps
    public var irmaaTiers: [IrmaaTier]
    public var rmdStartAge: Int
    public var bracketIndexation: String
    public var scheduledChanges: [ScheduledChange]
    public var id: String { version }
    public init(version: String, effectiveFrom: IsoDate, effectiveTo: IsoDate?, lastVerifiedAt: IsoDate, sources: [String], standardDeduction: [FilingStatus: Usd], ordinaryBrackets: [FilingStatus: [BracketRow]], ltcgBreakpoints: [FilingStatus: [BracketRow]], salt: SaltParameters, estate: EstateParameters, niitThreshold: [FilingStatus: Usd], niitRateBps: Bps, irmaaTiers: [IrmaaTier], rmdStartAge: Int, bracketIndexation: String, scheduledChanges: [ScheduledChange]) {
        self.version = version; self.effectiveFrom = effectiveFrom; self.effectiveTo = effectiveTo
        self.lastVerifiedAt = lastVerifiedAt; self.sources = sources; self.standardDeduction = standardDeduction
        self.ordinaryBrackets = ordinaryBrackets; self.ltcgBreakpoints = ltcgBreakpoints; self.salt = salt
        self.estate = estate; self.niitThreshold = niitThreshold; self.niitRateBps = niitRateBps
        self.irmaaTiers = irmaaTiers; self.rmdStartAge = rmdStartAge; self.bracketIndexation = bracketIndexation
        self.scheduledChanges = scheduledChanges
    }
}

// MARK: - Terminal disposition

/// The terminal outcome of an asset at death or during life.
public enum Disposition: String, CaseIterable, Identifiable, Sendable, Hashable {
    case holdToStepUp = "hold_to_step_up"
    case stepUpThenSell = "step_up_then_sell"
    case giftDuringLife = "gift_during_life"      // carries over basis
    case charitableAtDeath = "charitable_at_death"
    case consume
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .holdToStepUp: return "Hold to step-up"
        case .stepUpThenSell: return "Step-up then sell"
        case .giftDuringLife: return "Gift during life"
        case .charitableAtDeath: return "Charitable at death"
        case .consume: return "Consume"
        }
    }
}

/// Death-treatment profile of an asset class. 1 = best recipient.
public struct AssetDispositionProfile: Identifiable, Sendable, Hashable {
    public enum AssetClass: String, CaseIterable, Sendable, Hashable {
        case taxableAppreciated = "taxable_appreciated"
        case taxableHighBasis = "taxable_high_basis"
        case taxDeferred = "tax_deferred"
        case roth
        case realProperty = "real_property"
        case illiquidAlt = "illiquid_alt"
        case primaryResidence = "primary_residence"
        public var label: String {
            switch self {
            case .taxableAppreciated: return "Taxable (appreciated)"
            case .taxableHighBasis: return "Taxable (high basis)"
            case .taxDeferred: return "Tax-deferred (IRA/401k)"
            case .roth: return "Roth"
            case .realProperty: return "Real property"
            case .illiquidAlt: return "Illiquid alt"
            case .primaryResidence: return "Primary residence"
            }
        }
    }
    public var assetClass: AssetClass
    public var receivesStepUp: Bool
    public var erasesDepreciationRecapture: Bool
    public var heirsGetFreshDepreciationSchedule: Bool
    public var isIRD: Bool
    public var subjectToTenYearRule: Bool
    public var heirPreferenceRank: Int
    public var charityPreferenceRank: Int
    public var id: String { assetClass.rawValue }
    public init(assetClass: AssetClass, receivesStepUp: Bool, erasesDepreciationRecapture: Bool, heirsGetFreshDepreciationSchedule: Bool, isIRD: Bool, subjectToTenYearRule: Bool, heirPreferenceRank: Int, charityPreferenceRank: Int) {
        self.assetClass = assetClass; self.receivesStepUp = receivesStepUp
        self.erasesDepreciationRecapture = erasesDepreciationRecapture
        self.heirsGetFreshDepreciationSchedule = heirsGetFreshDepreciationSchedule
        self.isIRD = isIRD; self.subjectToTenYearRule = subjectToTenYearRule
        self.heirPreferenceRank = heirPreferenceRank; self.charityPreferenceRank = charityPreferenceRank
    }
}

/// Administrability constraints that break tax-optimal plans.
public struct HeirFeasibility: Sendable, Hashable {
    public var unfundedCommitmentsUsd: Usd
    public var heirsAreAccredited: Bool
    public var indivisibleAssetHeirCount: Int
    public var governingEntityExists: Bool
    public var estimatedEstateTaxDueUsd: Usd
    public var liquidAssetsAvailableUsd: Usd
    public var liquidityShortfallUsd: Usd
    public init(unfundedCommitmentsUsd: Usd, heirsAreAccredited: Bool, indivisibleAssetHeirCount: Int, governingEntityExists: Bool, estimatedEstateTaxDueUsd: Usd, liquidAssetsAvailableUsd: Usd, liquidityShortfallUsd: Usd) {
        self.unfundedCommitmentsUsd = unfundedCommitmentsUsd; self.heirsAreAccredited = heirsAreAccredited
        self.indivisibleAssetHeirCount = indivisibleAssetHeirCount; self.governingEntityExists = governingEntityExists
        self.estimatedEstateTaxDueUsd = estimatedEstateTaxDueUsd; self.liquidAssetsAvailableUsd = liquidAssetsAvailableUsd
        self.liquidityShortfallUsd = liquidityShortfallUsd
    }
}

/// Per-lot basis-vs-estate-tax tradeoff. Produced by the engine.
public struct DispositionDecision: Identifiable, Sendable, Hashable {
    public var lotId: String
    public var ticker: String
    public var currentDisposition: Disposition
    public var estimatedEstateValueUsd: Usd
    public var exemptionAvailableUsd: Usd
    public var aboveExemption: Bool
    public var unrealizedGainUsd: Usd
    public var basisRatioBps: Bps
    public var taxIfHeldUsd: Usd
    public var taxIfGiftedUsd: Usd
    public var estateTaxAvoidedUsd: Usd
    public var recommendation: Disposition
    public var rationale: String
    public var id: String { lotId }
    public init(lotId: String, ticker: String, currentDisposition: Disposition, estimatedEstateValueUsd: Usd, exemptionAvailableUsd: Usd, aboveExemption: Bool, unrealizedGainUsd: Usd, basisRatioBps: Bps, taxIfHeldUsd: Usd, taxIfGiftedUsd: Usd, estateTaxAvoidedUsd: Usd, recommendation: Disposition, rationale: String) {
        self.lotId = lotId; self.ticker = ticker; self.currentDisposition = currentDisposition
        self.estimatedEstateValueUsd = estimatedEstateValueUsd; self.exemptionAvailableUsd = exemptionAvailableUsd
        self.aboveExemption = aboveExemption; self.unrealizedGainUsd = unrealizedGainUsd; self.basisRatioBps = basisRatioBps
        self.taxIfHeldUsd = taxIfHeldUsd; self.taxIfGiftedUsd = taxIfGiftedUsd
        self.estateTaxAvoidedUsd = estateTaxAvoidedUsd; self.recommendation = recommendation; self.rationale = rationale
    }
}

// MARK: - Itemization / SALT window

public struct ItemizationInput: Sendable, Hashable {
    public var taxYear: Int
    public var filingStatus: FilingStatus
    public var magiUsd: Usd
    public var stateIncomeTaxUsd: Usd
    public var propertyTaxUsd: Usd
    public var mortgageInterestUsd: Usd
    public var charitableUsd: Usd
    public init(taxYear: Int, filingStatus: FilingStatus, magiUsd: Usd, stateIncomeTaxUsd: Usd, propertyTaxUsd: Usd, mortgageInterestUsd: Usd, charitableUsd: Usd) {
        self.taxYear = taxYear; self.filingStatus = filingStatus; self.magiUsd = magiUsd
        self.stateIncomeTaxUsd = stateIncomeTaxUsd; self.propertyTaxUsd = propertyTaxUsd
        self.mortgageInterestUsd = mortgageInterestUsd; self.charitableUsd = charitableUsd
    }
}

public struct ItemizationAnalysis: Sendable, Hashable {
    public var input: ItemizationInput
    public var effectiveSaltCapUsd: Usd
    public var saltDeductibleUsd: Usd
    public var totalItemizedUsd: Usd
    public var standardDeductionUsd: Usd
    public var itemizes: Bool
    /// The headline: value of the next dollar of mortgage interest.
    public var marginalValueOfMortgageInterestBps: Bps
    public var inPhaseDownBand: Bool
    public var effectiveMarginalRateInBandBps: Bps
    public var yearsUntilSaltReversion: Int?
    public init(input: ItemizationInput, effectiveSaltCapUsd: Usd, saltDeductibleUsd: Usd, totalItemizedUsd: Usd, standardDeductionUsd: Usd, itemizes: Bool, marginalValueOfMortgageInterestBps: Bps, inPhaseDownBand: Bool, effectiveMarginalRateInBandBps: Bps, yearsUntilSaltReversion: Int?) {
        self.input = input; self.effectiveSaltCapUsd = effectiveSaltCapUsd; self.saltDeductibleUsd = saltDeductibleUsd
        self.totalItemizedUsd = totalItemizedUsd; self.standardDeductionUsd = standardDeductionUsd; self.itemizes = itemizes
        self.marginalValueOfMortgageInterestBps = marginalValueOfMortgageInterestBps; self.inPhaseDownBand = inPhaseDownBand
        self.effectiveMarginalRateInBandBps = effectiveMarginalRateInBandBps; self.yearsUntilSaltReversion = yearsUntilSaltReversion
    }
}
