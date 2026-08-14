/**
 * INVESTMENT POLICY SCHEMA — v2
 * =============================
 *
 * WHAT CHANGED FROM v1
 * v1 modeled a household allocation. v2 models goal claims against a corpus,
 * with allocation as an emergent property. The consequences ripple:
 *
 *   - Household weights are OUTPUTS, not targets
 *   - The alts sleeve is a FUNCTION budget, not a product list
 *   - Only the spending claim glides; the legacy claim is perpetual
 *   - Tax rates live outside policy entirely, in a versioned module
 *   - Liquidity is a first-class property, because half the sleeve can't be sold
 *
 * INVARIANT: policy states PREFERENCES and BELIEFS. The tax module states
 * NUMBERS. The regime engine states CONDITIONS. Never mix them — beliefs
 * should outlive both Congress and the business cycle.
 *
 * STATUS: federal tax only. Regime engine stubbed pending the sector belief.
 */

// ============================================================
// PRIMITIVES
// ============================================================

type Bps = number;
type Usd = number;
type IsoDate = string;

type AccountTaxTreatment = "taxable" | "tax_deferred" | "tax_free";
type FilingStatus = "single" | "mfj" | "mfs" | "hoh";

/**
 * Liquidity class. NOT a boolean — the rebalancing engine, the ladder, and
 * the eligibility tiers all need to distinguish these.
 */
type LiquidityClass =
  | "daily"              // ETFs, mutual funds
  | "secondary_haircut"  // structured notes: sellable pre-maturity at a cost
  | "self_liquidating"   // notes at maturity, bond ladder rungs — known date
  | "gated"              // interval funds: ~5%/quarter
  | "locked";            // PE, private credit — lockup + capital calls

// ============================================================
// GOAL CLAIMS — the organizing object
// ============================================================

/**
 * A claim on the corpus. Everything else derives from these.
 *
 * The key move: the legacy claim has infinite horizon and never glides. The
 * spending claim has a finite schedule and de-risks toward it. A blended
 * "40/40/20" at retirement is what the sum LOOKS like — never what you target.
 */
interface GoalClaim {
  id: string;
  label: string;

  kind:
    | "spending"    // funds a known outflow schedule
    | "legacy"      // perpetual; the generational corpus
    | "reserve";    // emergency liquidity, never invested at risk

  /** Null horizon = perpetual. Only legacy claims may be null. */
  horizonYears: number | null;

  /** Outflow schedule in today's dollars. Inflated by the projection engine. */
  outflows: { year: number; amountUsd: Usd; inflationLinked: boolean }[];

  /**
   * Shortfall tolerance. This — not volatility — is the risk definition.
   * A tuition goal might be 5%; a legacy goal might accept 40%, since
   * "failure" means heirs inherit less, not that anyone eats cat food.
   */
  maxShortfallProbabilityBps: Bps;

  /**
   * Policy governing this claim. Different claims can run different policies:
   * the spending claim glides, the legacy claim does not.
   */
  policyId: string;

  /**
   * Lots earmarked here are held to step-up. The withdrawal engine treats a
   * taxable sale of an earmarked lot as a VIOLATION, not a budgeted cost.
   * Over a multi-decade horizon this is worth more than any tilt.
   */
  holdToStepUp: boolean;
}

/**
 * Assets outside the portfolio that offset claims.
 *
 * Home equity belongs here, NOT in the bond sleeve. It cannot fund a drawdown,
 * cannot be rebalanced from, is geographically concentrated, and its access
 * (HELOC) evaporates in exactly the scenario bonds exist for. What it DOES do
 * is pre-fund a housing consumption stream — so it offsets long-dated housing
 * outflows and displaces REIT exposure, not fixed income.
 */
interface ExternalAsset {
  id: string;
  label: string;
  kind: "home_equity" | "pension" | "social_security" | "business" | "other";
  valueUsd: Usd;

  /** Which claim's outflows this reduces. Scoping is the whole point. */
  offsetsClaimId: string | null;

  /** Only offsets outflows at or beyond this year. Home equity ≠ near-term. */
  offsetsFromYear: number;

  /** Sleeve whose need this displaces, if any. Home equity → real assets. */
  displacesSleeveId: string | null;

  liquidityClass: LiquidityClass;
}

// ============================================================
// ALTERNATIVES — function budget, not product list
// ============================================================

/**
 * The three jobs sold under one label. Sizing is by FUNCTION; the wrapper
 * varies by what the household can actually access.
 */
type AltFunction =
  | "convexity"            // trend, commodities, gold — works in inflation shocks
  | "illiquidity_premium"  // PE, private credit — paid for giving up access
  | "shaped_payoff";       // notes, buffer ETFs — defined outcome

interface AltFunctionBudget {
  fn: AltFunction;
  targetBps: Bps;
  bandBps: Bps;

  /**
   * Honest rationale. Note that illiquidity_premium does NOT get to claim the
   * correlation argument — private credit is credit beta with smoothed marks
   * and will fail the same shock bonds failed. It earns its place on
   * illiquidity premium and manager access, or not at all.
   */
  rationale: string;

  /** Sleeve-level fee ceiling. Against 5bps bonds, the hurdle is real. */
  maxFeeBps: Bps;

  /**
   * If no eligible wrapper exists at this household's tier, where does the
   * unfunded weight go? A belief, and it applies to most prospects.
   */
  fallbackSleeveId: string;
}

/**
 * Wrapper available at a given eligibility tier. Same function, different
 * vehicle as the household scales.
 */
interface AltWrapper {
  id: string;
  fn: AltFunction;
  label: string;
  minTicketUsd: Usd;
  liquidityClass: LiquidityClass;
  feeBps: Bps;

  requiresAccredited: boolean;
  requiresQualifiedPurchaser: boolean;

  /**
   * Reported vol is understated for appraisal-marked assets. Any projection
   * MUST use this override or unsmooth the series first — otherwise the
   * optimizer will happily allocate 60% here.
   */
  volatilityOverrideBps: Bps | null;
  returnsAreSmoothed: boolean;

  /** Locked wrappers carry unfunded commitments — a liability, not just a weight. */
  hasCapitalCalls: boolean;

  /**
   * Defined-outcome ETFs: stated buffer/cap apply only over a full outcome
   * period. Mid-period entry gets DIFFERENT economics. If true, the UI must
   * compute remaining buffer and remaining cap from current NAV vs. the
   * period reference price. Displaying the headline number is misleading.
   */
  hasOutcomePeriod: boolean;
}

/**
 * Tiers are DERIVED, not asserted. If notes cap at 3%/position and you want
 * 3 issuers, the sleeve needs 9% of the portfolio — with $10k tickets that
 * sets a hard floor on portfolio size before the function is even coherent.
 */
interface EligibilityTier {
  id: string;
  label: string;
  minInvestableUsd: Usd;   // computed from position-sizing math, not round numbers
  accredited: boolean;
  qualifiedPurchaser: boolean;
  availableWrapperIds: string[];
}

// ============================================================
// FIXED INCOME — sized to liability, not to a percentage
// ============================================================

/**
 * Liability matching for the near buckets; total return beyond.
 *
 * A client needing $200k/yr does NOT need $200k of coupons — they need $200k
 * of cash. Building the portfolio to YIELD the number rather than FUND it is
 * how you end up reaching for credit risk to hit a target.
 *
 * Ladder length is an OUTPUT of the funded-liability gap (spending need less
 * Social Security, pension, and other external income), not a risk-tolerance
 * conversation. Two clients with identical spending can need very different
 * ladders.
 */
interface LadderPolicy {
  /** Years of net outflows to pre-fund. Drives ladder length directly. */
  yearsCovered: number;

  minCreditQuality: string;
  allowCredit: boolean;

  /** Rolls forward annually, refilled from wherever the tax math says. */
  rollForward: boolean;

  /**
   * Liquid FI floor that exists purely for rebalancing ammunition — separate
   * from the ladder. Without this, a 30% FI sleeve alongside 20% illiquid alts
   * can leave LESS usable dry powder than the old 40% did.
   */
  rebalanceReserveBps: Bps;
}

// ============================================================
// SLEEVES
// ============================================================

interface Sleeve {
  id: string;
  label: string;
  tier: "core" | "satellite" | "diversifier" | "liquidity";
  targetBps: Bps;
  bandBps: Bps;
  maxBps: Bps | null;
  taxEfficiency: "high" | "moderate" | "low";
  locationPreference: AccountTaxTreatment[];
  liquidityClass: LiquidityClass;
  instruments: { ticker: string; role: "primary" | "tlh_partner" }[];
  rationale: string;
}

// ============================================================
// GLIDE — ratchet, valuation-modulated, hard deadline
// ============================================================

/**
 * Valuation timing is defensible HERE and almost nowhere else: valuation has
 * near-zero power at 1-2 years but real power at 10, and the glide transition
 * is itself a decade-scale decision. Slow signal, slow decision.
 *
 * Two guards:
 *   1. HARD DEADLINE. CAPE has read "expensive" almost continuously since the
 *      early 90s. A pure valuation trigger can leave a client at 50% equity
 *      at 68 because the signal never cleared. Valuation controls the PATH;
 *      the deadline controls the destination.
 *   2. RATCHET. De-risking is permanent. Without this the glide becomes market
 *      timing in a lifecycle costume — de-risk 2007, re-risk 2011, de-risk 2022.
 *
 * APPLIES TO THE SPENDING CLAIM ONLY. The legacy claim never glides.
 */
interface GlidePolicy {
  appliesToClaimKind: "spending";
  startDate: IsoDate;
  hardCompletionDate: IsoDate;

  fromEquityBps: Bps;
  toEquityBps: Bps;

  ratchet: true;

  valuationSignal: {
    metric: "cape" | "earnings_yield_real" | "equity_risk_premium";
    /** Rich → de-risk ahead of schedule. Cheap → delay toward the deadline. */
    richThreshold: number;
    cheapThreshold: number;
    /** Cap on how far valuation may pull the path off the linear baseline. */
    maxScheduleDeviationYears: number;
  };

  /**
   * The 20 holds its weight but rotates composition. Illiquidity premium is
   * actively wrong entering decumulation (capital calls, no rebalance access);
   * shaped payoff gets MORE useful (contractual cash flows on known dates).
   */
  altCompositionShift: { fn: AltFunction; deltaBps: Bps }[];
}

// ============================================================
// REBALANCING
// ============================================================

/**
 * Bands are ALREADY counter-cyclical — they mechanically sell what rose and
 * buy what fell with no forecast required. So cycle-conditioning only adds
 * value if deliberately asymmetric.
 *
 * The defensible version is horizon-based: momentum runs 6-12 months, mean
 * reversion runs 3-5 years. That argues for SLOWING the response — letting
 * drift persist rather than snapping back — with hard outer bands as backstop.
 * Not timing; a statement about the horizon at which reversion operates.
 *
 * On 1/n: it's hard to beat because estimation error in expected returns
 * swamps optimization gains out of sample. Cycle-conditioned weights
 * reintroduce that fragility, so deviation is bounded — a bad regime call
 * should cost basis points, not the plan.
 */
interface RebalancePolicy {
  reviewCadence: "annual";
  trigger: "band";

  /** Inner band: flag. Outer band: mandatory, no discretion. */
  outerBandMultiplier: number;

  /** Partial correction toward target, letting momentum run. 0-10000 bps. */
  correctionFractionBps: Bps;

  minTradeUsd: Usd;
  preferCashFlowRebalancing: boolean;
  washSaleWindowDays: number;

  /**
   * Realized gain budget for NON-earmarked lots only. Lots under a
   * holdToStepUp claim have no budget — selling them is a violation.
   */
  realizedGainBudgetBps: Bps | null;

  /** Locked/gated holdings sit outside bands; the rest absorbs their drift. */
  excludedLiquidityClasses: LiquidityClass[];
}

// ============================================================
// TAX MODULE — data, not policy
// ============================================================

/**
 * Effective-dated, NOT year-keyed. Law changes mid-year and sometimes
 * retroactively; delivered plans must reproduce what they said under the law
 * as it stood. Stamp `version` into every saved plan.
 *
 * v1 scope: federal only. State materially shifts the muni crossover and the
 * Roth conversion breakeven — strategy RANKING mostly survives, magnitude
 * doesn't. Disclose before this reaches a prospect.
 */
interface TaxModule {
  version: string;
  effectiveFrom: IsoDate;
  effectiveTo: IsoDate | null;
  jurisdiction: "us_federal";

  ordinaryBrackets: Record<FilingStatus, { upToUsd: Usd | null; rateBps: Bps }[]>;
  ltcgBreakpoints: Record<FilingStatus, { upToUsd: Usd | null; rateBps: Bps }[]>;
  standardDeduction: Record<FilingStatus, Usd>;

  /**
   * Step functions where one extra dollar costs real money. Any optimizer
   * treating marginal rate as smooth will walk clients straight over these.
   */
  niitThreshold: Record<FilingStatus, Usd>;
  niitRateBps: Bps;
  irmaaTiers: { magiOverUsd: Usd; monthlySurchargeUsd: Usd }[];

  estateExemptionUsd: Usd;
  rmdStartAge: number;
  contributionLimits: Record<string, Usd>;

  /**
   * Brackets index to chained CPI. If the projection inflates income but holds
   * brackets fixed, every client lands in the top bracket by year 20 and the
   * conversion logic goes haywire. Chained CPI runs below headline, so model
   * genuine slow creep — just far less than the naive version produces.
   */
  bracketIndexation: "chained_cpi";

  /** Provisions with known future effective dates — facts, not surprises. */
  scheduledChanges: { effectiveFrom: IsoDate; description: string }[];
}

/**
 * v1 FLAGS opportunities rather than optimizing. "You have $40k of headroom
 * in the 22% bracket this year" captures most of the value at a fraction of
 * the build, and doesn't require being right about future tax law.
 *
 * The retirement-to-RMD window is worth more than any tilt will ever produce.
 */
interface WithdrawalPolicy {
  mode: "flag_opportunities" | "optimize";
  strategy: "bracket_fill";
  targetBracketRateBps: Bps;
  conversionWindow: { fromAge: number; toAge: number } | null;
  respectStepUpEarmarks: true;
  cliffAwareness: ("niit" | "irmaa" | "ltcg_breakpoint")[];
}

// ============================================================
// REGIME ENGINE — stub
// ============================================================

/**
 * ONE regime engine feeds BOTH the sector tilt and any conditional FI/alt
 * split. Two separately half-specified regime calls is how frameworks rot.
 *
 * Pending the sector belief: needs named indicator, threshold, tilt magnitude,
 * evaluation cadence, and cap — committed ex ante, or you'll rotate on
 * narrative. NBER dates recessions ~a year late; real-time identification is
 * where tactical sector programs quietly fail.
 *
 * Sector rotation throws off short-term gains — this belongs almost entirely
 * in tax-deferred space. The tactical layer and the location layer are not
 * independent.
 */
interface RegimePolicy {
  enabled: boolean;
  indicators: { id: string; source: string; threshold: number }[];
  evaluationCadence: "monthly" | "quarterly";
  maxTiltBps: Bps;
  restrictToTreatments: AccountTaxTreatment[];
}

// ============================================================
// POLICY
// ============================================================

interface InvestmentPolicy {
  id: string;
  version: string;
  effectiveDate: IsoDate;
  taxModuleVersion: string;

  sleeves: Sleeve[];
  altBudgets: AltFunctionBudget[];
  altWrappers: AltWrapper[];
  eligibilityTiers: EligibilityTier[];
  ladder: LadderPolicy;
  glide: GlidePolicy | null;
  rebalance: RebalancePolicy;
  withdrawal: WithdrawalPolicy;
  regime: RegimePolicy;
  constraints: { id: string; severity: "hard" | "soft"; description: string }[];

  /** Becomes IPS language and client explanation. Say it out loud first. */
  statement: string;
}

interface Household {
  id: string;
  filingStatus: FilingStatus;
  claims: GoalClaim[];
  externalAssets: ExternalAsset[];
  eligibilityTierId: string;
}

// ============================================================
// SEED — legacy claim policy (perpetual, no glide)
// ============================================================

export const legacyPolicy: InvestmentPolicy = {
  id: "legacy-perpetual",
  version: "2.0.0",
  effectiveDate: "2026-08-11",
  taxModuleVersion: "us-fed-2026.1",

  sleeves: [
    {
      id: "us_large_core", label: "US Large Core", tier: "core",
      targetBps: 2600, bandBps: 500, maxBps: null,
      taxEfficiency: "high", locationPreference: ["taxable", "tax_free", "tax_deferred"],
      liquidityClass: "daily",
      instruments: [{ ticker: "VOO", role: "primary" }, { ticker: "SPLG", role: "tlh_partner" }],
      rationale: "Beta anchor. Held in taxable and never sold under a step-up earmark.",
    },
    {
      id: "us_sector_tilt", label: "SPDR Sector Tilt", tier: "satellite",
      targetBps: 900, bandBps: 300, maxBps: 1200,
      taxEfficiency: "moderate", locationPreference: ["tax_deferred"],
      liquidityClass: "daily",
      instruments: [{ ticker: "XLK", role: "primary" }],
      rationale: "Regime-conditioned tilt. Tax-deferred only — rotation throws short-term gains.",
    },
    {
      id: "us_mid_small", label: "US Mid/Small", tier: "core",
      targetBps: 800, bandBps: 200, maxBps: null,
      taxEfficiency: "moderate", locationPreference: ["tax_free", "tax_deferred", "taxable"],
      liquidityClass: "daily",
      instruments: [{ ticker: "VO", role: "primary" }, { ticker: "VB", role: "primary" }],
      rationale: "Completion exposure below large cap.",
    },
    {
      id: "intl_developed", label: "International Developed", tier: "core",
      targetBps: 1000, bandBps: 250, maxBps: null,
      taxEfficiency: "moderate", locationPreference: ["taxable", "tax_deferred", "tax_free"],
      liquidityClass: "daily",
      instruments: [{ ticker: "VEA", role: "primary" }],
      rationale: "Taxable for the foreign tax credit — a location decision, not just allocation.",
    },
    {
      id: "emerging", label: "Emerging Markets", tier: "satellite",
      targetBps: 700, bandBps: 200, maxBps: null,
      taxEfficiency: "moderate", locationPreference: ["tax_deferred", "tax_free", "taxable"],
      liquidityClass: "daily",
      instruments: [{ ticker: "VWO", role: "primary" }],
      rationale: "Dispersion and valuation exposure unavailable in developed markets.",
    },
    {
      id: "real_assets", label: "Real Assets / REIT", tier: "diversifier",
      targetBps: 400, bandBps: 150, maxBps: 700,
      taxEfficiency: "low", locationPreference: ["tax_deferred", "tax_free"],
      liquidityClass: "daily",
      instruments: [{ ticker: "VNQ", role: "primary" }],
      rationale:
        "Non-qualified dividends — sheltered accounts only. DISPLACED by home equity: a client with a paid-off house arguably shouldn't hold this at all.",
    },
    {
      id: "fixed_income_liquid", label: "Liquid Fixed Income", tier: "liquidity",
      targetBps: 1600, bandBps: 400, maxBps: null,
      taxEfficiency: "low", locationPreference: ["tax_deferred", "tax_free"],
      liquidityClass: "daily",
      instruments: [{ ticker: "BND", role: "primary" }],
      rationale:
        "Sized to liquidity and rebalancing need, NOT to a target percentage. Conditional diversifier: positive stock/bond correlation under inflation shocks, negative under growth shocks. You don't get to know which regime you're in.",
    },
  ],

  altBudgets: [
    {
      fn: "convexity", targetBps: 700, bandBps: 200,
      rationale:
        "The only function that addresses the stated problem: works specifically in inflation shocks, where bonds fail. Trend was long the 2022 move.",
      maxFeeBps: 150, fallbackSleeveId: "fixed_income_liquid",
    },
    {
      fn: "shaped_payoff", targetBps: 800, bandBps: 200,
      rationale:
        "Defined outcome with known maturity dates. Self-liquidating cash flows make this the alt function that gets MORE useful in decumulation.",
      maxFeeBps: 100, fallbackSleeveId: "us_large_core",
    },
    {
      fn: "illiquidity_premium", targetBps: 500, bandBps: 200,
      rationale:
        "Earns its place on illiquidity premium and manager access ONLY. Does not get to claim the correlation argument — this is credit and equity beta with smoothed marks and will fail the same shock bonds failed.",
      maxFeeBps: 250, fallbackSleeveId: "us_large_core",
    },
  ],

  altWrappers: [
    {
      id: "buffer_etf", fn: "shaped_payoff", label: "Defined Outcome ETF",
      minTicketUsd: 1000, liquidityClass: "daily", feeBps: 79,
      requiresAccredited: false, requiresQualifiedPurchaser: false,
      volatilityOverrideBps: null, returnsAreSmoothed: false,
      hasCapitalCalls: false, hasOutcomePeriod: true,
    },
    {
      id: "structured_note", fn: "shaped_payoff", label: "Structured Note",
      minTicketUsd: 10000, liquidityClass: "secondary_haircut", feeBps: 0,
      requiresAccredited: false, requiresQualifiedPurchaser: false,
      volatilityOverrideBps: null, returnsAreSmoothed: false,
      hasCapitalCalls: false, hasOutcomePeriod: false,
    },
    {
      id: "trend_mutual_fund", fn: "convexity", label: "Managed Futures Fund",
      minTicketUsd: 2500, liquidityClass: "daily", feeBps: 125,
      requiresAccredited: false, requiresQualifiedPurchaser: false,
      volatilityOverrideBps: null, returnsAreSmoothed: false,
      hasCapitalCalls: false, hasOutcomePeriod: false,
    },
    {
      id: "interval_pc", fn: "illiquidity_premium", label: "Private Credit Interval Fund",
      minTicketUsd: 25000, liquidityClass: "gated", feeBps: 225,
      requiresAccredited: true, requiresQualifiedPurchaser: false,
      volatilityOverrideBps: 1200, returnsAreSmoothed: true,
      hasCapitalCalls: false, hasOutcomePeriod: false,
    },
    {
      id: "pe_fund", fn: "illiquidity_premium", label: "Private Equity Fund",
      minTicketUsd: 250000, liquidityClass: "locked", feeBps: 250,
      requiresAccredited: true, requiresQualifiedPurchaser: true,
      volatilityOverrideBps: 2200, returnsAreSmoothed: true,
      hasCapitalCalls: true, hasOutcomePeriod: false,
    },
  ],

  // Boundaries DERIVED from position sizing: 3 issuers x 3% cap x $10k ticket
  // sets the floor at which the shaped-payoff function is even coherent.
  eligibilityTiers: [
    {
      id: "tier_1", label: "Liquid wrappers only", minInvestableUsd: 0,
      accredited: false, qualifiedPurchaser: false,
      availableWrapperIds: ["buffer_etf", "trend_mutual_fund"],
    },
    {
      id: "tier_2", label: "Individual notes viable", minInvestableUsd: 350000,
      accredited: false, qualifiedPurchaser: false,
      availableWrapperIds: ["buffer_etf", "structured_note", "trend_mutual_fund"],
    },
    {
      id: "tier_3", label: "Accredited", minInvestableUsd: 2000000,
      accredited: true, qualifiedPurchaser: false,
      availableWrapperIds: ["structured_note", "trend_mutual_fund", "interval_pc"],
    },
    {
      id: "tier_4", label: "Qualified purchaser", minInvestableUsd: 10000000,
      accredited: true, qualifiedPurchaser: true,
      availableWrapperIds: ["structured_note", "trend_mutual_fund", "interval_pc", "pe_fund"],
    },
  ],

  ladder: {
    yearsCovered: 0,          // legacy claim funds no near-term outflows
    minCreditQuality: "AA",
    allowCredit: false,
    rollForward: false,
    rebalanceReserveBps: 300,
  },

  glide: null,                // perpetual — never de-risks

  rebalance: {
    reviewCadence: "annual",
    trigger: "band",
    outerBandMultiplier: 2.0,
    correctionFractionBps: 6000,   // partial correction; let momentum run
    minTradeUsd: 1000,
    preferCashFlowRebalancing: true,
    washSaleWindowDays: 31,
    realizedGainBudgetBps: null,   // step-up earmarked: no budget, selling is a violation
    excludedLiquidityClasses: ["locked", "gated"],
  },

  withdrawal: {
    mode: "flag_opportunities",
    strategy: "bracket_fill",
    targetBracketRateBps: 2200,
    conversionWindow: { fromAge: 62, toAge: 73 },
    respectStepUpEarmarks: true,
    cliffAwareness: ["niit", "irmaa", "ltcg_breakpoint"],
  },

  regime: {
    enabled: false,                        // pending the sector belief
    indicators: [],
    evaluationCadence: "quarterly",
    maxTiltBps: 300,
    restrictToTreatments: ["tax_deferred"],
  },

  constraints: [
    {
      id: "smoothed_marks_guard", severity: "hard",
      description:
        "No wrapper with returnsAreSmoothed may enter a projection without a volatilityOverrideBps or an unsmoothed series. Otherwise the optimizer allocates 60% to private credit.",
    },
    {
      id: "step_up_violation", severity: "hard",
      description:
        "No taxable sale of a lot earmarked to a holdToStepUp claim. Over 30+ years the difference between 0 and 100bps of annual tax drag dwarfs any tilt.",
    },
    {
      id: "liquidity_floor", severity: "hard",
      description:
        "Daily-liquid assets must cover the ladder plus rebalanceReserve plus 12 months of outflows. Illiquid alts can only ever fund long-horizon claims.",
    },
    {
      id: "outcome_period_display", severity: "hard",
      description:
        "Any wrapper with hasOutcomePeriod must display REMAINING buffer and cap computed from current NAV vs. period reference price. Showing the headline number to a mid-period buyer is misleading.",
    },
    {
      id: "note_issuer_concentration", severity: "hard",
      description: "No single note issuer above 5% of household, inclusive of other credit exposure to that name.",
    },
    {
      id: "capital_call_coverage", severity: "hard",
      description: "Unfunded commitments are a liability. Liquid assets must cover the full remaining call schedule.",
    },
    {
      id: "home_equity_misclassification", severity: "soft",
      description:
        "Home equity offsets long-dated housing outflows and displaces real assets. It is not fixed income: it can't fund a drawdown, can't be rebalanced from, and HELOC access disappears in the scenario bonds exist for.",
    },
    {
      id: "alt_fee_budget", severity: "soft",
      description: "Weighted alt sleeve fee above budget. Against 5bps bonds, the hurdle is real.",
    },
  ],

  statement: `The corpus is perpetual. Claims against it are not — so allocation is an output
of funding those claims, never an input. Bonds are a conditional diversifier, positively
correlated to equities under inflation shocks and negatively under growth shocks; since the
regime isn't knowable in advance, fixed income is sized to liquidity and liability rather
than to a share. Alternatives are bought for a function, not a label: convexity that works
in the shock bonds fail, shaped payoffs with defined outcomes, and illiquidity premium held
on its own honest terms. Concentration is acceptable when chosen and sized. Most of the
durable value here comes from tax and structure, not from being right about markets.
TODO: rewrite in your own words before this reaches a client.`,
};

// ============================================================
// EXPORTS
// ============================================================

export type {
  Bps,
  Usd,
  IsoDate,
  AccountTaxTreatment,
  FilingStatus,
  LiquidityClass,
  GoalClaim,
  ExternalAsset,
  AltFunction,
  AltFunctionBudget,
  AltWrapper,
  EligibilityTier,
  LadderPolicy,
  Sleeve,
  GlidePolicy,
  RebalancePolicy,
  TaxModule,
  WithdrawalPolicy,
  RegimePolicy,
  InvestmentPolicy,
  Household,
};
