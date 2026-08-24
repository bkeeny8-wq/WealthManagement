//  FixedIncomeModel.swift
//  WealthPolicyDesk
//
//  Ported from src/fixed-income-liability-module.ts.
//
//  Fixed income and liabilities are ONE module, not two:
//
//      NET FIXED INCOME = FI ASSETS - DEBT
//
//  A 30-year fixed mortgage is a large short bond position. A household with
//  $500k in bonds and a $600k mortgage has NEGATIVE net fixed income exposure
//  and almost certainly does not know it. This is the correct, defensible
//  version of "home equity is bond allocation" — it lives on the LIABILITY side.

import Foundation

// MARK: - Vehicles

/// Muni crossover — often the largest single FI decision for a high-bracket
/// household in a high-tax state. Naive TEY = muni / (1 - rate) understates
/// munis (omits NIIT, state tax, MAGI effects) and overstates them (omits
/// de minimis, single-state concentration, AMT on PABs).
public struct MuniCrossover: Sendable, Hashable {
    public var muniYieldBps: Bps
    public var treasuryYieldBps: Bps
    public var corporateYieldBps: Bps
    public var marginalOrdinaryRateBps: Bps
    public var niitApplies: Bool
    public var inSaltPhaseDownBand: Bool
    /// Includes NIIT and MAGI effects, not just the headline rate.
    public var taxableEquivalentYieldBps: Bps
    public var muniPreferred: Bool
    public init(muniYieldBps: Bps, treasuryYieldBps: Bps, corporateYieldBps: Bps, marginalOrdinaryRateBps: Bps, niitApplies: Bool, inSaltPhaseDownBand: Bool, taxableEquivalentYieldBps: Bps, muniPreferred: Bool) {
        self.muniYieldBps = muniYieldBps; self.treasuryYieldBps = treasuryYieldBps; self.corporateYieldBps = corporateYieldBps
        self.marginalOrdinaryRateBps = marginalOrdinaryRateBps; self.niitApplies = niitApplies
        self.inSaltPhaseDownBand = inSaltPhaseDownBand; self.taxableEquivalentYieldBps = taxableEquivalentYieldBps
        self.muniPreferred = muniPreferred
    }
}

// MARK: - Liabilities

public enum LiabilityKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case mortgagePrimary = "mortgage_primary", mortgageInvestment = "mortgage_investment"
    case heloc, sbloc, margin
    case studentFederal = "student_federal", studentPrivate = "student_private"
    case auto, creditCard = "credit_card", business
    case unfundedCommitment = "unfunded_commitment"
    case estateTaxProjected = "estate_tax_projected"
    case deferredTax = "deferred_tax"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .mortgagePrimary: return "Mortgage (primary)"
        case .mortgageInvestment: return "Mortgage (investment)"
        case .heloc: return "HELOC"
        case .sbloc: return "SBLOC"
        case .margin: return "Margin"
        case .studentFederal: return "Student (federal)"
        case .studentPrivate: return "Student (private)"
        case .auto: return "Auto"
        case .creditCard: return "Credit card"
        case .business: return "Business"
        case .unfundedCommitment: return "Unfunded commitment"
        case .estateTaxProjected: return "Estate tax (projected)"
        case .deferredTax: return "Deferred tax"
        }
    }
    /// HELOC/SBLOC are revocable — withdrawn or called in past drawdowns.
    public var revocable: Bool { self == .heloc || self == .sbloc || self == .margin }
}

public struct Liability: Identifiable, Sendable, Hashable {
    public var id: String
    public var kind: LiabilityKind
    public var balanceUsd: Usd
    public var rateBps: Bps
    public var fixed: Bool
    public var maturityDate: IsoDate?
    /// Duration of the liability. Negative FI exposure to the household.
    public var durationYears: Double
    public var interestDeductible: Bool
    public var afterTaxRateBps: Bps
    public var revocable: Bool
    /// A fixed-rate mortgage is a callable bond the household is short and holds
    /// the call on. Refinance option value rises as rates fall.
    public var refinanceOptionValueUsd: Usd?
    public init(id: String, kind: LiabilityKind, balanceUsd: Usd, rateBps: Bps, fixed: Bool, maturityDate: IsoDate?, durationYears: Double, interestDeductible: Bool, afterTaxRateBps: Bps, revocable: Bool, refinanceOptionValueUsd: Usd? = nil) {
        self.id = id; self.kind = kind; self.balanceUsd = balanceUsd; self.rateBps = rateBps
        self.fixed = fixed; self.maturityDate = maturityDate; self.durationYears = durationYears
        self.interestDeductible = interestDeductible; self.afterTaxRateBps = afterTaxRateBps
        self.revocable = revocable; self.refinanceOptionValueUsd = refinanceOptionValueUsd
    }
    /// A liability is a fixed-income asset the household is SHORT. Excludes the
    /// synthetic accrual liabilities (deferred/estate tax) from the FI offset.
    public var isFixedIncomeOffset: Bool {
        switch kind {
        case .deferredTax, .estateTaxProjected, .unfundedCommitment: return false
        default: return true
        }
    }
}

/// PAY DOWN OR INVEST. Paying down debt is buying a bond yielding the after-tax
/// debt rate with zero credit and zero duration risk. The comparison is
/// after-tax debt rate vs after-tax FI yield, risk-matched — not "mortgage rate
/// vs expected equity return."
public struct PaydownAnalysis: Identifiable, Sendable, Hashable {
    public enum Recommendation: String, Sendable, Hashable { case payDown = "pay_down", maintain, borrowMore = "borrow_more", refinance
        public var label: String {
            switch self { case .payDown: return "Pay down"; case .maintain: return "Maintain"; case .borrowMore: return "Borrow more"; case .refinance: return "Refinance" }
        }
    }
    public var liabilityId: String
    public var afterTaxDebtRateBps: Bps
    public var comparableFiYieldAfterTaxBps: Bps
    public var spreadBps: Bps
    public var liquidityCostOfPaydownUsd: Usd
    public var saltWindowActive: Bool
    public var recommendation: Recommendation
    public var rationale: String
    public var id: String { liabilityId }
    public init(liabilityId: String, afterTaxDebtRateBps: Bps, comparableFiYieldAfterTaxBps: Bps, spreadBps: Bps, liquidityCostOfPaydownUsd: Usd, saltWindowActive: Bool, recommendation: Recommendation, rationale: String) {
        self.liabilityId = liabilityId; self.afterTaxDebtRateBps = afterTaxDebtRateBps
        self.comparableFiYieldAfterTaxBps = comparableFiYieldAfterTaxBps; self.spreadBps = spreadBps
        self.liquidityCostOfPaydownUsd = liquidityCostOfPaydownUsd; self.saltWindowActive = saltWindowActive
        self.recommendation = recommendation; self.rationale = rationale
    }
}

/// A $2M traditional IRA and a $2M Roth are NOT the same asset. The embedded tax
/// on tax-deferred balances and unrealized gains is a real liability — commonly
/// 15–25% of gross. But the deferred tax on a hold_to_step_up lot is NOT a
/// liability, because step-up extinguishes it. Balance sheet and disposition
/// engine are linked; neither is complete alone.
public struct DeferredTaxLiability: Identifiable, Sendable, Hashable {
    public var accountId: String
    public var treatment: AccountTaxTreatment
    public var balanceUsd: Usd
    public var unrealizedGainUsd: Usd
    public var applicableRateBps: Bps
    public var extinguishedByStepUp: Bool
    public var estimatedLiabilityUsd: Usd
    public var id: String { accountId }
    public init(accountId: String, treatment: AccountTaxTreatment, balanceUsd: Usd, unrealizedGainUsd: Usd, applicableRateBps: Bps, extinguishedByStepUp: Bool, estimatedLiabilityUsd: Usd) {
        self.accountId = accountId; self.treatment = treatment; self.balanceUsd = balanceUsd
        self.unrealizedGainUsd = unrealizedGainUsd; self.applicableRateBps = applicableRateBps
        self.extinguishedByStepUp = extinguishedByStepUp; self.estimatedLiabilityUsd = estimatedLiabilityUsd
    }
}

// MARK: - The presentable balance sheet

/// Assets and liabilities on one page, with the three numbers most statements
/// never show: after-tax net worth, net fixed income (frequently negative), and
/// total balance-sheet equity.
public struct BalanceSheetView: Sendable, Hashable {
    public struct Assets: Sendable, Hashable {
        public var portfolioUsd: Usd
        public var realEstateUsd: Usd
        public var humanCapitalPvUsd: Usd
        public var socialSecurityPvUsd: Usd
        public var pensionPvUsd: Usd
        public var businessUsd: Usd
        public var illiquidAltsUsd: Usd
        public init(portfolioUsd: Usd, realEstateUsd: Usd, humanCapitalPvUsd: Usd, socialSecurityPvUsd: Usd, pensionPvUsd: Usd, businessUsd: Usd, illiquidAltsUsd: Usd) {
            self.portfolioUsd = portfolioUsd; self.realEstateUsd = realEstateUsd; self.humanCapitalPvUsd = humanCapitalPvUsd
            self.socialSecurityPvUsd = socialSecurityPvUsd; self.pensionPvUsd = pensionPvUsd; self.businessUsd = businessUsd
            self.illiquidAltsUsd = illiquidAltsUsd
        }
    }
    public struct Liabilities: Sendable, Hashable {
        public var debtUsd: Usd
        public var unfundedCommitmentsUsd: Usd
        public var deferredTaxUsd: Usd
        public var projectedEstateTaxUsd: Usd
        public var goalLiabilityPvUsd: Usd
        public init(debtUsd: Usd, unfundedCommitmentsUsd: Usd, deferredTaxUsd: Usd, projectedEstateTaxUsd: Usd, goalLiabilityPvUsd: Usd) {
            self.debtUsd = debtUsd; self.unfundedCommitmentsUsd = unfundedCommitmentsUsd; self.deferredTaxUsd = deferredTaxUsd
            self.projectedEstateTaxUsd = projectedEstateTaxUsd; self.goalLiabilityPvUsd = goalLiabilityPvUsd
        }
    }
    public var householdId: String
    public var asOf: IsoDate
    public var assets: Assets
    public var liabilities: Liabilities
    public var grossNetWorthUsd: Usd
    public var afterTaxNetWorthUsd: Usd
    /// The number no statement shows. Frequently negative.
    public var netFixedIncomeUsd: Usd
    public var netHouseholdDurationYears: Double
    public var totalBalanceSheetEquityBps: Bps
    /// Assets + PV inflows over liabilities. The headline.
    public var fundedRatioBps: Bps
    public var deferredTaxDetail: [DeferredTaxLiability]
    public init(householdId: String, asOf: IsoDate, assets: Assets, liabilities: Liabilities, grossNetWorthUsd: Usd, afterTaxNetWorthUsd: Usd, netFixedIncomeUsd: Usd, netHouseholdDurationYears: Double, totalBalanceSheetEquityBps: Bps, fundedRatioBps: Bps, deferredTaxDetail: [DeferredTaxLiability]) {
        self.householdId = householdId; self.asOf = asOf; self.assets = assets; self.liabilities = liabilities
        self.grossNetWorthUsd = grossNetWorthUsd; self.afterTaxNetWorthUsd = afterTaxNetWorthUsd
        self.netFixedIncomeUsd = netFixedIncomeUsd; self.netHouseholdDurationYears = netHouseholdDurationYears
        self.totalBalanceSheetEquityBps = totalBalanceSheetEquityBps; self.fundedRatioBps = fundedRatioBps
        self.deferredTaxDetail = deferredTaxDetail
    }
}
