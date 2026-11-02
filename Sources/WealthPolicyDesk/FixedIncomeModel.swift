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
    /// The holder's state income rate. Municipal income is exempt from FEDERAL tax; a
    /// national muni fund — which is what this model's sleeves hold — is generally still
    /// taxable by the holder's own state, while Treasuries are the reverse: federally
    /// taxable and state-exempt. Ignoring the state rate entirely made the crossover
    /// identical in Texas, New Jersey and California.
    public var stateIncomeRateBps: Bps
    /// Yields net of every tax that actually applies to each instrument, which is what the
    /// preference verdict compares. A single grossed-up number cannot express the
    /// federal/state asymmetry between munis and Treasuries.
    public var muniAfterTaxBps: Bps
    public var treasuryAfterTaxBps: Bps
    public var corporateAfterTaxBps: Bps
    /// Includes NIIT and MAGI effects, not just the headline rate.
    public var taxableEquivalentYieldBps: Bps
    public var muniPreferred: Bool
    public init(muniYieldBps: Bps, treasuryYieldBps: Bps, corporateYieldBps: Bps, marginalOrdinaryRateBps: Bps, niitApplies: Bool, inSaltPhaseDownBand: Bool, stateIncomeRateBps: Bps = 0, muniAfterTaxBps: Bps = 0, treasuryAfterTaxBps: Bps = 0, corporateAfterTaxBps: Bps = 0, taxableEquivalentYieldBps: Bps, muniPreferred: Bool) {
        self.muniYieldBps = muniYieldBps; self.treasuryYieldBps = treasuryYieldBps; self.corporateYieldBps = corporateYieldBps
        self.marginalOrdinaryRateBps = marginalOrdinaryRateBps; self.niitApplies = niitApplies
        self.inSaltPhaseDownBand = inSaltPhaseDownBand; self.taxableEquivalentYieldBps = taxableEquivalentYieldBps
        self.stateIncomeRateBps = stateIncomeRateBps
        self.muniAfterTaxBps = muniAfterTaxBps; self.treasuryAfterTaxBps = treasuryAfterTaxBps
        self.corporateAfterTaxBps = corporateAfterTaxBps
        self.muniPreferred = muniPreferred
    }
}

// MARK: - Liabilities

public enum LiabilityKind: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
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
    /// A PROMOTIONAL rate that EXPIRES. `rateBps` is the rate in force until this date;
    /// `postPromoRateBps` is what it reverts to. nil = the rate is the rate.
    ///
    /// This is the one fact about a household's card debt that a blended rate cannot carry,
    /// and it is the most important one: a 0% balance is the cheapest money they owe until a
    /// contractual date and the most expensive money they owe the day after. It is a DATED
    /// PLANNING EVENT, not a rate — which is why it lives here as a date rather than being
    /// averaged into `rateBps`.
    public var promoRateExpiry: IsoDate?
    /// The rate the promotional balance reverts to. Must EXCEED `rateBps` for the revert to
    /// be modelled: an expiry typed with no revert rate is a half-filled row, and letting it
    /// through would flip a paydown verdict on no information at all.
    public var postPromoRateBps: Bps
    /// Transactional float — a card balance paid in full every statement. Owed, and on the
    /// balance sheet, but it accrues no interest, so there is no rate to compare and no
    /// pay-down-or-invest decision to make about it.
    public var paidMonthlyInFull: Bool
    /// The client's own name for this item. Two items can share a kind — this household
    /// carries two cards and two student loans — so `kind.label` alone cannot identify a row.
    public var label: String?
    public init(id: String, kind: LiabilityKind, balanceUsd: Usd, rateBps: Bps, fixed: Bool, maturityDate: IsoDate?, durationYears: Double, interestDeductible: Bool, afterTaxRateBps: Bps, revocable: Bool, refinanceOptionValueUsd: Usd? = nil,
                promoRateExpiry: IsoDate? = nil, postPromoRateBps: Bps = 0, paidMonthlyInFull: Bool = false, label: String? = nil) {
        self.id = id; self.kind = kind; self.balanceUsd = balanceUsd; self.rateBps = rateBps
        self.fixed = fixed; self.maturityDate = maturityDate; self.durationYears = durationYears
        self.interestDeductible = interestDeductible; self.afterTaxRateBps = afterTaxRateBps
        self.revocable = revocable; self.refinanceOptionValueUsd = refinanceOptionValueUsd
        self.promoRateExpiry = promoRateExpiry; self.postPromoRateBps = postPromoRateBps
        self.paidMonthlyInFull = paidMonthlyInFull; self.label = label
    }
    /// The display name: the client's own, else the kind's.
    public var displayLabel: String { (label?.isEmpty == false ? label : nil) ?? kind.label }
    /// Whether this item carries a modelled promotional revert at all.
    public var hasPromoRevert: Bool {
        guard let e = promoRateExpiry, !e.isEmpty else { return false }
        return postPromoRateBps > rateBps
    }
    /// The rate actually in force on `asOf`. ISO dates compare lexicographically, which for
    /// YYYY-MM-DD is chronological — so this reads no clock and needs no Calendar.
    public func effectiveRateBps(asOf: IsoDate) -> Bps {
        guard hasPromoRevert, let e = promoRateExpiry else { return rateBps }
        return asOf < e ? rateBps : postPromoRateBps
    }
    /// Whole months from `asOf` to the revert, or nil when there is no revert still ahead.
    /// Zero means the revert lands in the plan's own month — already urgent, not "no promo".
    public func monthsToPromoRevert(asOf: IsoDate) -> Int? {
        guard hasPromoRevert, let e = promoRateExpiry, asOf < e else { return nil }
        return max(0, Engine.monthsBetween(asOf, e))
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
    /// Months from the plan date to a promotional revert, nil when there is none. When this
    /// is set and inside the decision horizon, `afterTaxDebtRateBps` above is the rate the
    /// balance is ABOUT TO carry, not the one it carries today — so the badge, the spread and
    /// the rationale all describe the same decision.
    public var monthsToPromoRevert: Int?
    /// The rate the promotional balance reverts to, and the rate in force today. Both are
    /// reported so a 0.00%-today / 22.90%-soon row can never be read as only one of them.
    public var postPromoRateBps: Bps
    public var currentRateBps: Bps
    public var id: String { liabilityId }
    public init(liabilityId: String, afterTaxDebtRateBps: Bps, comparableFiYieldAfterTaxBps: Bps, spreadBps: Bps, liquidityCostOfPaydownUsd: Usd, saltWindowActive: Bool, recommendation: Recommendation, rationale: String,
                monthsToPromoRevert: Int? = nil, postPromoRateBps: Bps = 0, currentRateBps: Bps = 0) {
        self.liabilityId = liabilityId; self.afterTaxDebtRateBps = afterTaxDebtRateBps
        self.comparableFiYieldAfterTaxBps = comparableFiYieldAfterTaxBps; self.spreadBps = spreadBps
        self.liquidityCostOfPaydownUsd = liquidityCostOfPaydownUsd; self.saltWindowActive = saltWindowActive
        self.recommendation = recommendation; self.rationale = rationale
        self.monthsToPromoRevert = monthsToPromoRevert; self.postPromoRateBps = postPromoRateBps
        self.currentRateBps = currentRateBps
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
        /// Unvested equity comp, NET of the withholding taken on vest, and CONTINGENT on staying
        /// until each tranche converts. Carried as an asset because the doctrine is total balance
        /// sheet or nothing — it was previously counted in the equity percentage and nowhere in
        /// net worth, so a client's own statement and this screen disagreed by the whole grant.
        public var unvestedCompUsd: Usd = 0
        public init(portfolioUsd: Usd, realEstateUsd: Usd, humanCapitalPvUsd: Usd, socialSecurityPvUsd: Usd, pensionPvUsd: Usd, businessUsd: Usd, illiquidAltsUsd: Usd) {
            self.portfolioUsd = portfolioUsd; self.realEstateUsd = realEstateUsd; self.humanCapitalPvUsd = humanCapitalPvUsd
            self.socialSecurityPvUsd = socialSecurityPvUsd; self.pensionPvUsd = pensionPvUsd; self.businessUsd = businessUsd
            self.illiquidAltsUsd = illiquidAltsUsd
        }
        /// Convenience for callers written before unvested comp was a line.
        public mutating func withUnvestedComp(_ usd: Usd) -> Assets { unvestedCompUsd = usd; return self }
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
