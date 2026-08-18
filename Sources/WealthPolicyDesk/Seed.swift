//  Seed.swift
//  WealthPolicyDesk
//
//  The seeded policy instances (ported from the exported consts in src/*.ts)
//  plus a realistic sample household — the "decumulation client" the README
//  names as specified-but-unbuilt.
//
//  NOTE ON TAX NUMBERS: the TypeScript TAX_2026 leaves brackets/standard
//  deduction/LTCG breakpoints as TODO (structure is the deliverable, not the
//  values). To make the engine run, this file fills them with representative
//  2026 federal figures. They are ESTIMATES stamped with lastVerifiedAt and
//  MUST be verified before any client use — see the README's "verify" list.

import Foundation

public enum Seed {

    // ========================================================
    // Fund lineup (LINEUP) and geography tree (GEO_TREE)
    // ========================================================

    public static let lineup = FundLineup(
        domesticCore: .init(ticker: "IVV", label: "S&P 500", feeBps: 3),
        domesticMid: .init(ticker: "IJH", label: "S&P MidCap 400", feeBps: 5),
        domesticSmall: .init(ticker: "IJR", label: "S&P SmallCap 600", feeBps: 6),
        developedCore: .init(ticker: "IEFA", label: "MSCI EAFE IMI", feeBps: 7),
        emergingCore: .init(ticker: "IEMG", label: "MSCI EM IMI", feeBps: 9),
        tlhPartners: ["IVV": "VOO", "IJH": "VO", "IJR": "VB"]
    )

    public static let geoTree: [GeoNode] = [
        .init(id: "world", label: "World", level: .global, parentId: nil),
        .init(id: "us", label: "United States", level: .bloc, parentId: "world", isoCode: "US"),
        .init(id: "dev_exus", label: "Developed ex-US", level: .bloc, parentId: "world"),
        .init(id: "em", label: "Emerging Markets", level: .bloc, parentId: "world"),
        .init(id: "europe_dev", label: "Europe (developed)", level: .region, parentId: "dev_exus"),
        .init(id: "asia_dev", label: "Asia (developed)", level: .region, parentId: "dev_exus"),
        .init(id: "americas_dev", label: "Americas (developed)", level: .region, parentId: "dev_exus"),
        .init(id: "asia_em", label: "Asia (emerging)", level: .region, parentId: "em"),
        .init(id: "latam_em", label: "Latin America (emerging)", level: .region, parentId: "em"),
        .init(id: "emea_em", label: "EMEA (emerging)", level: .region, parentId: "em"),
        .init(id: "de", label: "Germany", level: .country, parentId: "europe_dev", isoCode: "DE"),
        .init(id: "fr", label: "France", level: .country, parentId: "europe_dev", isoCode: "FR"),
        .init(id: "gb", label: "United Kingdom", level: .country, parentId: "europe_dev", isoCode: "GB"),
        .init(id: "ch", label: "Switzerland", level: .country, parentId: "europe_dev", isoCode: "CH"),
        .init(id: "jp", label: "Japan", level: .country, parentId: "asia_dev", isoCode: "JP"),
        .init(id: "tw", label: "Taiwan", level: .country, parentId: "asia_em", isoCode: "TW"),
        .init(id: "kr", label: "South Korea", level: .country, parentId: "asia_em", isoCode: "KR"),
        .init(id: "in", label: "India", level: .country, parentId: "asia_em", isoCode: "IN"),
        .init(id: "br", label: "Brazil", level: .country, parentId: "latam_em", isoCode: "BR"),
        .init(id: "mx", label: "Mexico", level: .country, parentId: "latam_em", isoCode: "MX"),
    ]

    // ========================================================
    // Sleeves (shared by both seeded policies)
    // ========================================================

    static let sleeves: [Sleeve] = [
        // --- Growth (equities) — the return engine, bound by the risk ceiling ---
        Sleeve(id: "us_large_core", label: "US Large Core", tier: .core, role: .growth, targetBps: 2000, bandBps: 500, maxBps: nil,
               taxEfficiency: .high, locationPreference: [.taxable, .taxFree, .taxDeferred], liquidityClass: .daily,
               instruments: [.init(ticker: "VOO", role: .primary), .init(ticker: "SPLG", role: .tlhPartner)],
               rationale: "Beta anchor. Held in taxable and never sold under a step-up earmark."),
        Sleeve(id: "us_sector_tilt", label: "SPDR Sector Tilt", tier: .satellite, role: .growth, targetBps: 700, bandBps: 300, maxBps: 1200,
               taxEfficiency: .moderate, locationPreference: [.taxDeferred], liquidityClass: .daily,
               instruments: [.init(ticker: "XLK", role: .primary),
                             .init(ticker: "XLF", role: .option), .init(ticker: "XLV", role: .option),
                             .init(ticker: "XLE", role: .option), .init(ticker: "XLI", role: .option),
                             .init(ticker: "XLY", role: .option), .init(ticker: "XLP", role: .option),
                             .init(ticker: "XLU", role: .option), .init(ticker: "XLB", role: .option),
                             .init(ticker: "XLRE", role: .option), .init(ticker: "XLC", role: .option)],
               rationale: "An overweight to one of the 11 S&P sectors — implemented with its Select Sector SPDR. Which sector is the tactical call (set on the Tilts tab), not a permanent bet on tech. The bold ticker is what's held today; the rest are the menu. Tax-deferred only — rotation throws short-term gains."),
        Sleeve(id: "us_mid_small", label: "US Mid/Small", tier: .core, role: .growth, targetBps: 700, bandBps: 200, maxBps: nil,
               taxEfficiency: .moderate, locationPreference: [.taxFree, .taxDeferred, .taxable], liquidityClass: .daily,
               instruments: [.init(ticker: "VO", role: .primary), .init(ticker: "VB", role: .primary)],
               rationale: "Completion exposure below large cap."),
        Sleeve(id: "intl_developed", label: "International Developed", tier: .core, role: .growth, targetBps: 800, bandBps: 250, maxBps: nil,
               taxEfficiency: .moderate, locationPreference: [.taxable, .taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "VEA", role: .primary)],
               rationale: "Taxable for the foreign tax credit — a location decision, not just allocation."),
        Sleeve(id: "intl_small", label: "Intl Small-Cap", tier: .satellite, role: .growth, targetBps: 400, bandBps: 150, maxBps: nil,
               taxEfficiency: .moderate, locationPreference: [.taxDeferred, .taxFree, .taxable], liquidityClass: .daily,
               instruments: [.init(ticker: "VSS", role: .primary)],
               rationale: "Small-cap outside the US — the least-covered corner of public equity, where structural premia are largest."),
        Sleeve(id: "emerging", label: "Emerging Markets", tier: .satellite, role: .growth, targetBps: 600, bandBps: 200, maxBps: nil,
               taxEfficiency: .moderate, locationPreference: [.taxDeferred, .taxFree, .taxable], liquidityClass: .daily,
               instruments: [.init(ticker: "VWO", role: .primary)],
               rationale: "Dispersion and valuation exposure unavailable in developed markets."),
        Sleeve(id: "real_assets", label: "Real Assets / REIT", tier: .diversifier, role: .growth, targetBps: 400, bandBps: 150, maxBps: 700,
               taxEfficiency: .low, locationPreference: [.taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "VNQ", role: .primary)],
               rationale: "Equity-like real estate — non-qualified dividends, so sheltered accounts only. DISPLACED by home equity."),
        // --- Defensive (nominal bonds) — liability ballast ---
        Sleeve(id: "fixed_income_liquid", label: "Core Bonds", tier: .liquidity, role: .defensive, targetBps: 900, bandBps: 300, maxBps: nil,
               taxEfficiency: .low, locationPreference: [.taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "BND", role: .primary)],
               rationale: "Intermediate-duration investment-grade bonds — the liability ballast and the asset you rebalance FROM in an equity drawdown."),
        Sleeve(id: "tips", label: "TIPS / Inflation-Linked", tier: .diversifier, role: .defensive, targetBps: 400, bandBps: 150, maxBps: nil,
               taxEfficiency: .low, locationPreference: [.taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "SCHP", role: .primary), .init(ticker: "VTIP", role: .tlhPartner)],
               rationale: "Inflation-linked Treasuries — the real-rate hedge. Phantom income makes them tax-inefficient; hold sheltered."),
        Sleeve(id: "credit_hy", label: "Credit / High-Yield", tier: .satellite, role: .defensive, targetBps: 300, bandBps: 150, maxBps: 600,
               taxEfficiency: .low, locationPreference: [.taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "HYG", role: .primary), .init(ticker: "JNK", role: .tlhPartner)],
               rationale: "Credit-spread / high-yield — a return-SEEKING bond sleeve. It correlates with equities in a crisis, so it is not true ballast; capped accordingly."),
        Sleeve(id: "em_debt", label: "EM Debt", tier: .satellite, role: .defensive, targetBps: 200, bandBps: 100, maxBps: 500,
               taxEfficiency: .low, locationPreference: [.taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "EMB", role: .primary)],
               rationale: "Emerging-market sovereign & corporate debt — yield and diversification, carrying currency and default risk."),
        // --- Real diversifier (commodities/gold) — the inflation-shock hedge ---
        Sleeve(id: "commodities", label: "Commodities / Gold", tier: .diversifier, role: .realDiversifier, targetBps: 300, bandBps: 150, maxBps: 600,
               taxEfficiency: .low, locationPreference: [.taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "DBC", role: .primary), .init(ticker: "GLD", role: .option)],
               rationale: "Broad commodities & gold — the one asset that tends to RISE in an inflation shock, when both stocks and bonds fall. A crisis diversifier, not a return engine."),
        // --- Cash — the zero-duration reserve behind the liquidity floor ---
        Sleeve(id: "cash", label: "Cash / Short Reserve", tier: .liquidity, role: .cash, targetBps: 300, bandBps: 200, maxBps: nil,
               taxEfficiency: .moderate, locationPreference: [.taxable, .taxDeferred, .taxFree], liquidityClass: .daily,
               instruments: [.init(ticker: "SGOV", role: .primary), .init(ticker: "BIL", role: .tlhPartner)],
               rationale: "Short T-bills — the zero-duration reserve that backs the near-term liquidity floor. Sized to what you'll spend soon, not a strategic weight."),
    ]


    static let altBudgets: [AltFunctionBudget] = [
        .init(fn: .convexity, targetBps: 700, bandBps: 200,
              rationale: "The only function that addresses the stated problem: works in inflation shocks, where bonds fail.",
              maxFeeBps: 150, fallbackSleeveId: "fixed_income_liquid"),
        .init(fn: .shapedPayoff, targetBps: 800, bandBps: 200,
              rationale: "Defined outcome with known maturity dates. Gets MORE useful in decumulation.",
              maxFeeBps: 100, fallbackSleeveId: "us_large_core"),
        .init(fn: .illiquidityPremium, targetBps: 500, bandBps: 200,
              rationale: "Earns its place on illiquidity premium and manager access ONLY — credit/equity beta with smoothed marks.",
              maxFeeBps: 250, fallbackSleeveId: "us_large_core"),
    ]

    static let altWrappers: [AltWrapper] = [
        .init(id: "buffer_etf", fn: .shapedPayoff, label: "Defined Outcome ETF", minTicketUsd: 1_000, liquidityClass: .daily, feeBps: 79,
              requiresAccredited: false, requiresQualifiedPurchaser: false, volatilityOverrideBps: nil, returnsAreSmoothed: false,
              hasCapitalCalls: false, hasOutcomePeriod: true),
        .init(id: "structured_note", fn: .shapedPayoff, label: "Structured Note", minTicketUsd: 10_000, liquidityClass: .secondaryHaircut, feeBps: 0,
              requiresAccredited: false, requiresQualifiedPurchaser: false, volatilityOverrideBps: nil, returnsAreSmoothed: false,
              hasCapitalCalls: false, hasOutcomePeriod: false),
        .init(id: "trend_mutual_fund", fn: .convexity, label: "Managed Futures Fund", minTicketUsd: 2_500, liquidityClass: .daily, feeBps: 125,
              requiresAccredited: false, requiresQualifiedPurchaser: false, volatilityOverrideBps: nil, returnsAreSmoothed: false,
              hasCapitalCalls: false, hasOutcomePeriod: false),
        .init(id: "interval_pc", fn: .illiquidityPremium, label: "Private Credit Interval Fund", minTicketUsd: 25_000, liquidityClass: .gated, feeBps: 225,
              requiresAccredited: true, requiresQualifiedPurchaser: false, volatilityOverrideBps: 1200, returnsAreSmoothed: true,
              hasCapitalCalls: false, hasOutcomePeriod: false),
        .init(id: "pe_fund", fn: .illiquidityPremium, label: "Private Equity Fund", minTicketUsd: 250_000, liquidityClass: .locked, feeBps: 250,
              requiresAccredited: true, requiresQualifiedPurchaser: true, volatilityOverrideBps: 2200, returnsAreSmoothed: true,
              hasCapitalCalls: true, hasOutcomePeriod: false),
    ]

    static let eligibilityTiers: [EligibilityTier] = [
        .init(id: "tier_1", label: "Liquid wrappers only", minInvestableUsd: 0, accredited: false, qualifiedPurchaser: false,
              availableWrapperIds: ["buffer_etf", "trend_mutual_fund"]),
        .init(id: "tier_2", label: "Individual notes viable", minInvestableUsd: 350_000, accredited: false, qualifiedPurchaser: false,
              availableWrapperIds: ["buffer_etf", "structured_note", "trend_mutual_fund"]),
        .init(id: "tier_3", label: "Accredited", minInvestableUsd: 2_000_000, accredited: true, qualifiedPurchaser: false,
              availableWrapperIds: ["structured_note", "trend_mutual_fund", "interval_pc"]),
        .init(id: "tier_4", label: "Qualified purchaser", minInvestableUsd: 10_000_000, accredited: true, qualifiedPurchaser: true,
              availableWrapperIds: ["structured_note", "trend_mutual_fund", "interval_pc", "pe_fund"]),
    ]

    static let rebalance = RebalancePolicy(
        reviewCadence: "annual", trigger: "band", outerBandMultiplier: 2.0, correctionFractionBps: 6000,
        minTradeUsd: 1_000, preferCashFlowRebalancing: true, washSaleWindowDays: 31,
        realizedGainBudgetBps: nil, excludedLiquidityClasses: [.locked, .gated])

    static let withdrawal = WithdrawalPolicy(
        mode: .flagOpportunities, strategy: "bracket_fill", targetBracketRateBps: 2200,
        conversionWindow: (fromAge: 62, toAge: 73), cliffAwareness: ["niit", "irmaa", "ltcg_breakpoint"])

    static let regime = RegimePolicy(enabled: false, evaluationCadence: "quarterly", maxTiltBps: 300, restrictToTreatments: [.taxDeferred])

    static let policyConstraints: [PolicyRule] = [
        .init(id: "smoothed_marks_guard", severity: .hard, description: "No wrapper with returnsAreSmoothed may enter a projection without a volatilityOverrideBps or an unsmoothed series. Otherwise the optimizer allocates 60% to private credit."),
        .init(id: "step_up_violation", severity: .hard, description: "No taxable sale of a lot earmarked to a holdToStepUp claim. Over 30+ years the difference between 0 and 100bps of annual tax drag dwarfs any tilt."),
        .init(id: "liquidity_floor", severity: .hard, description: "Daily-liquid assets must cover the ladder plus rebalanceReserve plus 12 months of outflows. Illiquid alts can only ever fund long-horizon claims."),
        .init(id: "outcome_period_display", severity: .hard, description: "Any wrapper with hasOutcomePeriod must display REMAINING buffer and cap computed from current NAV vs. period reference price."),
        .init(id: "note_issuer_concentration", severity: .hard, description: "No single note issuer above 5% of household, inclusive of other credit exposure to that name."),
        .init(id: "capital_call_coverage", severity: .hard, description: "Unfunded commitments are a liability. Liquid assets must cover the full remaining call schedule."),
        .init(id: "home_equity_misclassification", severity: .soft, description: "Home equity offsets long-dated housing outflows and displaces real assets. It is not fixed income."),
        .init(id: "alt_fee_budget", severity: .soft, description: "Weighted alt sleeve fee above budget. Against 5bps bonds, the hurdle is real."),
    ]

    static let statement = """
    The corpus is perpetual. Claims against it are not — so allocation is an output of funding \
    those claims, never an input. Bonds are a conditional diversifier, positively correlated to \
    equities under inflation shocks and negatively under growth shocks; since the regime isn't \
    knowable in advance, fixed income is sized to liquidity and liability rather than to a share. \
    Alternatives are bought for a function, not a label. Most of the durable value here comes from \
    tax and structure, not from being right about markets.
    """

    // ========================================================
    // The two seeded policies
    // ========================================================

    /// legacyPolicy — perpetual, never glides (from src/policy-schema-v2.ts).
    public static let legacyPolicy = InvestmentPolicy(
        id: "legacy-perpetual", version: "2.0.0", effectiveDate: "2026-08-11", taxModuleVersion: "us-fed-2026.1",
        sleeves: sleeves, altBudgets: altBudgets, altWrappers: altWrappers, eligibilityTiers: eligibilityTiers,
        ladder: LadderPolicy(yearsCovered: 0, minCreditQuality: "AA", allowCredit: false, rollForward: false, rebalanceReserveBps: 300),
        glide: nil, rebalance: rebalance, withdrawal: withdrawal, regime: regime,
        constraints: policyConstraints, statement: statement)

    /// spendingPolicy — the decumulation instance the README leaves unbuilt:
    /// a 7-year liability ladder and a ratcheting, valuation-modulated glide.
    public static let spendingPolicy = InvestmentPolicy(
        id: "spending-glide", version: "2.0.0", effectiveDate: "2026-08-11", taxModuleVersion: "us-fed-2026.1",
        sleeves: sleeves, altBudgets: altBudgets, altWrappers: altWrappers, eligibilityTiers: eligibilityTiers,
        ladder: LadderPolicy(yearsCovered: 7, minCreditQuality: "AA", allowCredit: false, rollForward: true, rebalanceReserveBps: 300),
        glide: GlidePolicy(
            startDate: "2026-08-11", hardCompletionDate: "2038-01-01",
            fromEquityBps: 6500, toEquityBps: 4000, ratchet: true,
            valuationSignal: ValuationSignal(metric: .cape, richThreshold: 30, cheapThreshold: 18, maxScheduleDeviationYears: 3),
            altCompositionShift: [(fn: .illiquidityPremium, deltaBps: -300), (fn: .shapedPayoff, deltaBps: 300)]),
        rebalance: rebalance, withdrawal: withdrawal, regime: regime,
        constraints: policyConstraints,
        statement: "The spending claim glides on a ratchet toward a hard deadline; the ladder pre-funds seven years of net outflows so no drawdown ever forces a sale into weakness.")

    public static let policies: [InvestmentPolicy] = [legacyPolicy, spendingPolicy]
    public static func policy(_ id: String) -> InvestmentPolicy { policies.first { $0.id == id } ?? legacyPolicy }

    // ========================================================
    // Tactical overlay policy (tiltPolicy)
    // ========================================================

    public static let tiltPolicy = TiltPolicy(
        enabled: true, mode: "manual", coreShareOfEquityBps: 8300,
        maxTotalAbsoluteDeviationBps: 1000, maxSingleSectorDeviationBps: 400, maxLookThroughSectorBps: 3800,
        restrictToTreatments: [.taxDeferred, .taxFree],
        activeTilts: [
            Tilt(id: "tilt_energy", axis: .sector, nodeId: Sector.energy.rawValue, deviationBps: 300, funding: .paired,
                 offsetNodeId: Sector.utilities.rawValue, currency: .noView,
                 thesis: "Real-asset convexity into a fiscally-dominant, higher-for-longer regime; funded from rate-sensitive utilities.",
                 openedAt: "2026-05-01", reviewBy: "2026-11-01", exitCondition: "Real 10y back below 1.5% or thesis invalidated",
                 acknowledgedCrossExposure: ["Overweight materials via energy complex"]),
        ])

    public static let axisRules: [AxisRules] = [
        .init(axis: .sector, restrictToTreatments: [.taxDeferred, .taxFree], minExpectedRelativeReturnBps: 100, maxSingleDeviationBps: 400, maxTotalAbsoluteDeviationBps: 1000),
        .init(axis: .geo, restrictToTreatments: [.taxDeferred, .taxFree], minExpectedRelativeReturnBps: 300, maxSingleDeviationBps: 300, maxTotalAbsoluteDeviationBps: 800),
    ]

    public static let matrixConstraints: [MatrixConstraint] = [
        .init(id: "cell_concentration", severity: .hard, scope: .cell, limitBps: 800, description: "No country×sector cell above 8% of equity — the joint-exposure catch a per-axis view misses."),
        .init(id: "sector_lookthrough", severity: .hard, scope: .sectorMargin, limitBps: 3800, description: "Sector look-through inclusive of country-fund contribution."),
        .init(id: "single_country", severity: .hard, scope: .geoMargin, limitBps: 700, description: "Single-country exposure inclusive of core."),
        .init(id: "em_ceiling", severity: .soft, scope: .geoMargin, limitBps: 1500, description: "Emerging markets core + overlay."),
        .init(id: "stale_matrix", severity: .hard, scope: .total, limitBps: 0, description: "Refuse to evaluate against a decomposition older than maxAgeDays."),
    ]

    // ========================================================
    // Layer separation
    // ========================================================

    public static let holdingPeriods: [HoldingPeriodPolicy] = [
        .init(axis: .sector, reviewIntervalDays: 90, maxHoldingDays: 548, requiresFreshThesisOnReentry: true, reentryCooldownDays: 0),
        .init(axis: .geo, reviewIntervalDays: 90, maxHoldingDays: 548, requiresFreshThesisOnReentry: true, reentryCooldownDays: 0),
    ]

    public static let layerBudget = LayerBudget(maxTacticalShareOfEquityBps: 1700, maxTacticalShareOfPortfolioBps: 900, maxConcurrentTilts: 4, annualCostBudgetBps: 40)

    public static let layerConstraints: [PolicyRule] = [
        .init(id: "layer_isolation", severity: .hard, description: "The strategic engine may not transact tactical lots, or vice versa."),
        .init(id: "no_tactical_step_up", severity: .hard, description: "Tactical lots never carry a holdToStepUp earmark."),
        .init(id: "holding_period_ceiling", severity: .hard, description: "A tactical lot past maxHoldingDays must exit or re-enter with a fresh thesis."),
        .init(id: "entry_gate", severity: .soft, description: "A tilt whose expected return is below its round-trip cost; override is logged and surfaced."),
        .init(id: "annual_cost_budget", severity: .hard, description: "Trailing 12-month tactical cost over budget pauses new entries."),
    ]

    // ========================================================
    // Fixed income & liability constraints, instrument profiles
    // ========================================================

    public static let instrumentProfiles: [InstrumentProfile] = [
        .init(instrument: .treasury, federallyTaxable: true, stateTaxable: false, countsTowardMagi: true, hasPhantomIncome: false, preferredLocation: [.taxable], prohibitedLocation: []),
        .init(instrument: .tips, federallyTaxable: true, stateTaxable: false, countsTowardMagi: true, hasPhantomIncome: true, preferredLocation: [.taxDeferred, .taxFree], prohibitedLocation: []),
        .init(instrument: .corporateIg, federallyTaxable: true, stateTaxable: true, countsTowardMagi: true, hasPhantomIncome: false, preferredLocation: [.taxDeferred, .taxFree], prohibitedLocation: []),
        .init(instrument: .corporateHy, federallyTaxable: true, stateTaxable: true, countsTowardMagi: true, hasPhantomIncome: false, preferredLocation: [.taxDeferred, .taxFree], prohibitedLocation: []),
        .init(instrument: .muniNational, federallyTaxable: false, stateTaxable: true, countsTowardMagi: false, hasPhantomIncome: false, preferredLocation: [.taxable], prohibitedLocation: [.taxDeferred, .taxFree]),
        .init(instrument: .muniInState, federallyTaxable: false, stateTaxable: false, countsTowardMagi: false, hasPhantomIncome: false, preferredLocation: [.taxable], prohibitedLocation: [.taxDeferred, .taxFree]),
    ]

    public static let fiLiabilityConstraints: [PolicyRule] = [
        .init(id: "muni_in_sheltered_account", severity: .hard, description: "Municipal bonds held in a tax-deferred or tax-free account. Paying for an exemption inside an already-sheltered account, then converting to ordinary income on withdrawal."),
        .init(id: "tips_in_taxable", severity: .soft, description: "TIPS in a taxable account. Inflation accruals are taxed currently without a cash distribution — tax due on money not received."),
        .init(id: "negative_net_fixed_income", severity: .soft, description: "Debt exceeds fixed income assets. The household believes it holds a defensive allocation while running net short duration."),
        .init(id: "revocable_credit_in_liquidity_floor", severity: .hard, description: "HELOC or SBLOC counted toward the liquidity floor. Both were withdrawn or called in past drawdowns — exactly when needed."),
        .init(id: "duration_mismatch", severity: .soft, description: "FI duration materially different from the duration of the liabilities it funds."),
        .init(id: "odd_lot_ladder", severity: .soft, description: "Individual bond positions below the odd-lot threshold. Markups likely exceed the benefit over a defined-maturity ETF."),
        .init(id: "gross_net_worth_displayed", severity: .soft, description: "Presentation showing gross rather than after-tax net worth. Overstates available wealth, commonly by 15–25%."),
    ]

    // ========================================================
    // Disposition
    // ========================================================

    public static let assetDispositionProfiles: [AssetDispositionProfile] = [
        .init(assetClass: .taxableAppreciated, receivesStepUp: true, erasesDepreciationRecapture: false, heirsGetFreshDepreciationSchedule: false, isIRD: false, subjectToTenYearRule: false, heirPreferenceRank: 1, charityPreferenceRank: 3),
        .init(assetClass: .taxableHighBasis, receivesStepUp: true, erasesDepreciationRecapture: false, heirsGetFreshDepreciationSchedule: false, isIRD: false, subjectToTenYearRule: false, heirPreferenceRank: 2, charityPreferenceRank: 4),
        .init(assetClass: .taxDeferred, receivesStepUp: false, erasesDepreciationRecapture: false, heirsGetFreshDepreciationSchedule: false, isIRD: true, subjectToTenYearRule: true, heirPreferenceRank: 5, charityPreferenceRank: 1),
        .init(assetClass: .roth, receivesStepUp: false, erasesDepreciationRecapture: false, heirsGetFreshDepreciationSchedule: false, isIRD: false, subjectToTenYearRule: true, heirPreferenceRank: 1, charityPreferenceRank: 5),
        .init(assetClass: .realProperty, receivesStepUp: true, erasesDepreciationRecapture: true, heirsGetFreshDepreciationSchedule: true, isIRD: false, subjectToTenYearRule: false, heirPreferenceRank: 2, charityPreferenceRank: 3),
        .init(assetClass: .illiquidAlt, receivesStepUp: true, erasesDepreciationRecapture: false, heirsGetFreshDepreciationSchedule: false, isIRD: false, subjectToTenYearRule: false, heirPreferenceRank: 4, charityPreferenceRank: 2),
    ]

    public static let dispositionConstraints: [PolicyRule] = [
        .init(id: "ird_to_charity", severity: .soft, description: "Charity should receive the IRA (IRD), not the taxable account. The charity pays no income tax; heirs would."),
        .init(id: "gift_low_basis", severity: .soft, description: "Gift high-basis lots, not low-basis. Low-basis lots should be held for the step-up."),
        .init(id: "partition_risk", severity: .soft, description: "An indivisible asset left to multiple heirs with no governing entity invites a forced partition sale."),
        .init(id: "step_up_sale", severity: .hard, description: "A taxable sale of a hold_to_step_up lot forfeits the basis step-up that is the whole point of holding it."),
        .init(id: "estate_liquidity", severity: .hard, description: "Projected estate tax exceeds liquid assets; the 9-month filing deadline forces a distressed sale."),
        .init(id: "orphaned_commitments", severity: .hard, description: "Unfunded capital calls pass to heirs who lack the liquidity or accreditation to meet them."),
    ]

    // ========================================================
    // Household intake constraints & planning constraints
    // ========================================================

    public static let householdConstraints: [PolicyRule] = [
        .init(id: "human_capital_sector_stacking", severity: .soft, description: "The portfolio overweights the same sector the client's income depends on; employer stock + unvested comp + sector tilt stack into one undeclared bet."),
        .init(id: "equity_capacity_exceeded", severity: .soft, description: "Total-balance-sheet equity exceeds capacity once human-capital beta and unvested comp are included."),
        .init(id: "correlated_dual_income", severity: .soft, description: "Both earners in correlated industries with no single-income survivability; size the reserve to joint income loss."),
        .init(id: "employer_credit_concentration", severity: .hard, description: "Deferred cash comp is an unsecured claim stacked on salary, bonus, and employer stock — aggregate single-employer credit + equity exposure."),
        .init(id: "inflexible_goal_cluster", severity: .soft, description: "Multiple non-deferrable goals in a narrow window remove the cheapest risk lever."),
    ]

    public static let planningConstraints: [PolicyRule] = [
        .init(id: "transition_gain_budget_exceeded", severity: .hard, description: "Scheduled transition gains exceed the annual realized-gain budget."),
        .init(id: "tolerance_below_capacity", severity: .soft, description: "Stated risk tolerance implies less equity than capacity allows — bind to the lower number."),
        .init(id: "ltc_unfunded", severity: .hard, description: "Long-term-care exposure is unfunded — the largest unmodeled tail for a long-lived household."),
        .init(id: "disability_gap", severity: .hard, description: "Disability coverage falls short of the human-capital it protects."),
        .init(id: "concentrated_permanent_hold", severity: .soft, description: "A concentrated legacy position is being held permanently without a hedge."),
        .init(id: "83b_window", severity: .hard, description: "An 83(b) election has a 30-day irrevocable window."),
        .init(id: "529_clock_not_started", severity: .soft, description: "The 15-year 529 account-age clock has not started; ~5 years minimum to move the full 529→Roth cap."),
    ]

    // ========================================================
    // TAX_2026 — representative 2026 federal figures (VERIFY before client use)
    // ========================================================

    public static let tax2026 = TaxParameterSet(
        version: "us-fed-2026.1",
        effectiveFrom: "2026-01-01", effectiveTo: "2026-12-31",
        lastVerifiedAt: "2026-08-11",
        sources: ["OBBBA (P.L. 119-21)", "26 U.S.C. §164(b)(7)", "IRS inflation adjustments (est.)"],
        standardDeduction: [.single: 16_150, .mfj: 32_300, .mfs: 16_150, .hoh: 24_200],
        ordinaryBrackets: [
            .single: [
                .init(upToUsd: 12_000, rateBps: 1000), .init(upToUsd: 48_800, rateBps: 1200),
                .init(upToUsd: 104_150, rateBps: 2200), .init(upToUsd: 198_850, rateBps: 2400),
                .init(upToUsd: 252_500, rateBps: 3200), .init(upToUsd: 631_450, rateBps: 3500),
                .init(upToUsd: nil, rateBps: 3700),
            ],
            .mfj: [
                .init(upToUsd: 24_000, rateBps: 1000), .init(upToUsd: 97_600, rateBps: 1200),
                .init(upToUsd: 208_300, rateBps: 2200), .init(upToUsd: 397_700, rateBps: 2400),
                .init(upToUsd: 505_000, rateBps: 3200), .init(upToUsd: 757_700, rateBps: 3500),
                .init(upToUsd: nil, rateBps: 3700),
            ],
            .mfs: [
                .init(upToUsd: 12_000, rateBps: 1000), .init(upToUsd: 48_800, rateBps: 1200),
                .init(upToUsd: 104_150, rateBps: 2200), .init(upToUsd: 198_850, rateBps: 2400),
                .init(upToUsd: 252_500, rateBps: 3200), .init(upToUsd: 378_850, rateBps: 3500),
                .init(upToUsd: nil, rateBps: 3700),
            ],
            .hoh: [
                .init(upToUsd: 17_150, rateBps: 1000), .init(upToUsd: 65_300, rateBps: 1200),
                .init(upToUsd: 104_150, rateBps: 2200), .init(upToUsd: 198_850, rateBps: 2400),
                .init(upToUsd: 252_500, rateBps: 3200), .init(upToUsd: 631_450, rateBps: 3500),
                .init(upToUsd: nil, rateBps: 3700),
            ],
        ],
        ltcgBreakpoints: [
            .single: [.init(upToUsd: 49_550, rateBps: 0), .init(upToUsd: 551_350, rateBps: 1500), .init(upToUsd: nil, rateBps: 2000)],
            .mfj: [.init(upToUsd: 99_100, rateBps: 0), .init(upToUsd: 618_800, rateBps: 1500), .init(upToUsd: nil, rateBps: 2000)],
            .mfs: [.init(upToUsd: 49_550, rateBps: 0), .init(upToUsd: 309_400, rateBps: 1500), .init(upToUsd: nil, rateBps: 2000)],
            .hoh: [.init(upToUsd: 66_300, rateBps: 0), .init(upToUsd: 585_050, rateBps: 1500), .init(upToUsd: nil, rateBps: 2000)],
        ],
        salt: SaltParameters(
            capUsd: [.single: 40_400, .mfj: 40_400, .mfs: 20_200, .hoh: 40_400],
            phaseDownThresholdUsd: [.single: 505_000, .mfj: 505_000, .mfs: 252_500, .hoh: 505_000],
            phaseDownRatePerDollar: 0.30,
            phaseDownFloorUsd: [.single: 10_000, .mfj: 10_000, .mfs: 5_000, .hoh: 10_000],
            topBracketBenefitCapBps: 3500, mortgageInterestAcquisitionDebtLimitUsd: 750_000),
        estate: EstateParameters(lifetimeExemptionUsd: 15_000_000, portabilityAvailable: true, topRateBps: 4000, annualGiftExclusionUsd: 19_000, inflationIndexed: true),
        niitThreshold: [.single: 200_000, .mfj: 250_000, .mfs: 125_000, .hoh: 200_000],
        niitRateBps: 380,
        irmaaTiers: [
            .init(magiOverUsd: 212_000, monthlySurchargeUsd: 74),
            .init(magiOverUsd: 266_000, monthlySurchargeUsd: 185),
            .init(magiOverUsd: 334_000, monthlySurchargeUsd: 296),
            .init(magiOverUsd: 400_000, monthlySurchargeUsd: 407),
            .init(magiOverUsd: 750_000, monthlySurchargeUsd: 443),
        ],
        rmdStartAge: 73, bracketIndexation: "chained_cpi",
        scheduledChanges: [
            .init(effectiveFrom: "2030-01-01", parameter: "salt.capUsd", description: "SALT cap reverts to $10,000 ($5,000 MFS).", certainty: .scheduledSunset),
        ])

    // ========================================================
    // The sample household — the Harrisons, near-retirement, NJ, MFJ
    // ========================================================

    public static let sampleHousehold: Household = {
        let people = [
            Person(id: "p_robert", label: "Robert Harrison", birthDate: "1963-03-01", role: .primary, expectedRetirementAge: 65, healthStatus: .good, longevityPercentileTarget: 92),
            Person(id: "p_susan", label: "Susan Harrison", birthDate: "1965-06-15", role: .spouse, expectedRetirementAge: 64, healthStatus: .excellent, longevityPercentileTarget: 94),
        ]
        let humanCapital = [
            HumanCapital(personId: "p_robert", baseSalaryUsd: 220_000, expectedBonusUsd: 90_000, bonusVolatilityBps: 3500, character: .equityLike, impliedBeta: 0.75, sector: .financials, yearsRemaining: 2, realGrowthRateBps: 150, jobLossInDrawdownProbabilityBps: 3500),
            HumanCapital(personId: "p_susan", baseSalaryUsd: 140_000, expectedBonusUsd: 20_000, bonusVolatilityBps: 1500, character: .moderate, impliedBeta: 0.35, sector: .healthcare, yearsRemaining: 3, realGrowthRateBps: 100, jobLossInDrawdownProbabilityBps: 1200),
        ]
        let deferredComp = [
            DeferredCompensation(id: "dc_rsu", personId: "p_robert", kind: .rsu, ticker: "MEGABANK", grantValueUsd: 320_000, subjectToEmployerCredit: false, tradingRestricted: true),
            DeferredCompensation(id: "dc_defcash", personId: "p_robert", kind: .deferredCash, ticker: nil, grantValueUsd: 180_000, subjectToEmployerCredit: true, tradingRestricted: false),
        ]
        let ssProfiles = [
            SocialSecurityProfile(personId: "p_robert", estimatedPIAUsd: 3_500, fullRetirementAge: 67, plannedClaimingAge: 70, eligibleForSpousalBenefit: false, survivorBenefitApplies: true),
            SocialSecurityProfile(personId: "p_susan", estimatedPIAUsd: 2_400, fullRetirementAge: 67, plannedClaimingAge: 67, eligibleForSpousalBenefit: true, survivorBenefitApplies: true),
        ]
        // Retirement spending: $220k/yr in today's dollars, years 3..32 (post-retirement).
        let spendingOutflows = (3...32).map { Outflow(year: $0, amountUsd: 220_000, inflationLinked: true) }
        let goals = [
            Goal(id: "g_spending", label: "Retirement spending", kind: .spending, tier: .essential, horizonYears: 32,
                 outflows: spendingOutflows, inflationSeries: .cpi, maxShortfallProbabilityBps: 300, holdToStepUp: false,
                 flexibility: GoalFlexibility(deferrableYears: 2, scalableDownBps: 1500, abandonable: false), policyId: "spending-glide"),
            Goal(id: "g_legacy", label: "Generational corpus", kind: .legacy, tier: .aspirational, horizonYears: nil,
                 outflows: [], inflationSeries: .cpi, maxShortfallProbabilityBps: 4000, holdToStepUp: true,
                 flexibility: GoalFlexibility(deferrableYears: 0, scalableDownBps: 5000, abandonable: false), policyId: "legacy-perpetual"),
            Goal(id: "g_reserve", label: "Emergency reserve", kind: .reserve, tier: .essential, horizonYears: nil,
                 outflows: [Outflow(year: 1, amountUsd: 150_000, inflationLinked: false)], inflationSeries: .cpi,
                 maxShortfallProbabilityBps: 100, holdToStepUp: false, flexibility: .rigid, policyId: "legacy-perpetual"),
        ]
        let externalAssets = [
            ExternalAsset(id: "ext_home", label: "Primary residence equity", kind: .homeEquity, valueUsd: 720_000, offsetsClaimId: "g_spending", offsetsFromYear: 22, displacesSleeveId: "real_assets", liquidityClass: .locked),
            ExternalAsset(id: "ext_pension", label: "Robert defined-benefit pension", kind: .pension, valueUsd: 240_000, offsetsClaimId: "g_spending", offsetsFromYear: 4, displacesSleeveId: nil, liquidityClass: .selfLiquidating),
        ]
        let accounts = [
            Account(id: "acct_taxable", label: "Joint brokerage", treatment: .taxable),
            Account(id: "acct_ira", label: "Robert rollover IRA", treatment: .taxDeferred),
            Account(id: "acct_401k", label: "Susan 401(k)", treatment: .taxDeferred),
            Account(id: "acct_roth", label: "Roth IRA", treatment: .taxFree),
        ]
        let positions = [
            // Taxable — the low-basis, held-to-step-up core.
            Position(id: "pos_voo", accountId: "acct_taxable", ticker: "VOO", sleeveId: "us_large_core", marketValueUsd: 720_000, costBasisUsd: 250_000, layer: .strategic, disposition: .holdToStepUp, holdToStepUp: true),
            Position(id: "pos_vea", accountId: "acct_taxable", ticker: "VEA", sleeveId: "intl_developed", marketValueUsd: 310_000, costBasisUsd: 268_000, layer: .strategic, disposition: .holdToStepUp, holdToStepUp: false),
            Position(id: "pos_aapl", accountId: "acct_taxable", ticker: "AAPL", sleeveId: nil, marketValueUsd: 240_000, costBasisUsd: 28_000, layer: .strategic, disposition: .holdToStepUp, holdToStepUp: true, isConcentrated: true),
            Position(id: "pos_mub", accountId: "acct_taxable", ticker: "MUB", sleeveId: "fixed_income_liquid", marketValueUsd: 160_000, costBasisUsd: 158_000, layer: .strategic, disposition: .stepUpThenSell, holdToStepUp: false),
            // Tax-deferred — ordinary-income and phantom-income instruments.
            Position(id: "pos_bnd", accountId: "acct_ira", ticker: "BND", sleeveId: "fixed_income_liquid", marketValueUsd: 300_000, costBasisUsd: 300_000, layer: .ladder, disposition: .charitableAtDeath, holdToStepUp: false),
            Position(id: "pos_xlk", accountId: "acct_ira", ticker: "XLK", sleeveId: "us_sector_tilt", marketValueUsd: 175_000, costBasisUsd: 120_000, layer: .tactical, disposition: .charitableAtDeath, holdToStepUp: false),
            Position(id: "pos_vwo", accountId: "acct_ira", ticker: "VWO", sleeveId: "emerging", marketValueUsd: 150_000, costBasisUsd: 140_000, layer: .strategic, disposition: .charitableAtDeath, holdToStepUp: false),
            Position(id: "pos_vnq", accountId: "acct_401k", ticker: "VNQ", sleeveId: "real_assets", marketValueUsd: 90_000, costBasisUsd: 84_000, layer: .strategic, disposition: .charitableAtDeath, holdToStepUp: false),
            Position(id: "pos_pcred", accountId: "acct_401k", ticker: "PCRED", sleeveId: nil, marketValueUsd: 130_000, costBasisUsd: 120_000, layer: .strategic, disposition: .charitableAtDeath, holdToStepUp: false),
            // Roth — highest-growth, best held by heirs.
            Position(id: "pos_vb", accountId: "acct_roth", ticker: "VB", sleeveId: "us_mid_small", marketValueUsd: 120_000, costBasisUsd: 70_000, layer: .strategic, disposition: .stepUpThenSell, holdToStepUp: false),
            Position(id: "pos_bufr", accountId: "acct_roth", ticker: "BUFR", sleeveId: nil, marketValueUsd: 95_000, costBasisUsd: 88_000, layer: .strategic, disposition: .stepUpThenSell, holdToStepUp: false),
        ]
        let liabilities = [
            Liability(id: "liab_mortgage", kind: .mortgagePrimary, balanceUsd: 520_000, rateBps: 310, fixed: true, maturityDate: "2049-06-01", durationYears: 7.5, interestDeductible: true, afterTaxRateBps: 310, revocable: false, refinanceOptionValueUsd: 6_000),
            Liability(id: "liab_heloc", kind: .heloc, balanceUsd: 60_000, rateBps: 780, fixed: false, maturityDate: nil, durationYears: 0.25, interestDeductible: false, afterTaxRateBps: 780, revocable: true),
            Liability(id: "liab_commit", kind: .unfundedCommitment, balanceUsd: 45_000, rateBps: 0, fixed: false, maturityDate: nil, durationYears: 2.0, interestDeductible: false, afterTaxRateBps: 0, revocable: false),
        ]
        // Protection: a real household carrying live coverage gaps (a hard DI gap, a life shortfall, a thin umbrella).
        let protection = ProtectionProfile(
            disabilityNeedMonthlyUsd: 18_000, disabilityCoverageMonthlyUsd: 11_000, disabilityGapMonthlyUsd: 7_000,
            disabilityOwnOccupation: false, disabilityGroupOnlyTaxable: false,
            lifeNeedUsd: 2_500_000, lifeInForceUsd: 2_000_000, lifeGapUsd: 500_000,
            ltcApproach: .selfFund, ltcTotalExposureUsd: 600_000, ltcUnfundedUsd: 300_000,
            umbrellaLimitUsd: 1_000_000)
        // Equity comp: an insider mid-blackout planning an ISO exercise-and-hold with possible QSBS.
        let equityComp = EquityCompMechanics(
            grantTypes: [.rsu, .iso], isInsider: true, tradingWindow: .blackout, has10b51Plan: false,
            plannedExerciseAndHold: true, isoBargainElementUsd: 220_000, pending83bGrantDate: "", qsbs: .maybe)

        return Household(
            id: "hh_harrison", name: "The Harrisons", filingStatus: .mfj, stateOfResidence: "NJ",
            people: people, humanCapital: humanCapital, deferredComp: deferredComp,
            incomeProfile: HouseholdIncomeProfile(incomeCorrelation: 0.45, primaryShareOfIncomeBps: 6600, survivableOnSingleIncome: true),
            socialSecurity: ssProfiles, goals: goals, externalAssets: externalAssets,
            eligibilityTierId: "tier_3", accounts: accounts, positions: positions, liabilities: liabilities,
            annualSavingsUsd: 80_000, legacyFloorUsd: 1_000_000, protection: protection, equityComp: equityComp)
    }()
}
