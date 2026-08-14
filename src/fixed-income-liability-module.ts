/**
 * FIXED INCOME & LIABILITY MODULE — v1
 * ====================================
 *
 * These are ONE module, not two.
 *
 * NET FIXED INCOME = FI ASSETS - DEBT
 *
 * A 30-year fixed mortgage is a large short bond position. A household with
 * $500k in bonds and a $600k mortgage has NEGATIVE net fixed income exposure
 * and almost certainly does not know it. Every statement they have ever
 * received showed the $500k and omitted the offset.
 *
 * This is the correct, defensible version of the original "home equity is
 * bond allocation" intuition — it lives on the LIABILITY side, not the asset
 * side.
 *
 * Sections:
 *   1. Fixed income vehicles
 *   2. Instrument types and their account homes
 *   3. Duration derived from liabilities
 *   4. The liability side of the balance sheet
 *   5. Deferred tax liability — the largest unstated liability
 *   6. The component view
 */

import type { Bps, Usd, IsoDate } from "./policy-schema-v2";

type AccountTaxTreatment = "taxable" | "tax_deferred" | "tax_free";

// ============================================================
// 1. VEHICLES
// ============================================================

/**
 * Three ways to own fixed income, each right for a different job.
 *
 * INDIVIDUAL BONDS — the only vehicle with a DEFINED MATURITY. Hold to
 *   maturity and interim price moves are irrelevant; you receive par on a
 *   known date. That is precisely what liability matching requires, and no
 *   fund can replicate it. Use for the ladder.
 *
 *   Cost caveat: retail bond markups are embedded in price and effectively
 *   invisible, and odd lots (under ~$100k per position) price meaningfully
 *   worse than institutional blocks. Below a certain ladder size the markup
 *   exceeds the benefit.
 *
 * BOND ETFs — perpetual duration, no maturity date, so NAV risk never
 *   resolves. Wrong for liability matching, right for the rebalancing
 *   reserve where daily liquidity is the whole point.
 *
 * DEFINED-MATURITY ETFs (iShares iBonds, Invesco BulletShares) — the bridge.
 *   A fund that terminates on a stated date and distributes proceeds. Gives
 *   ladder mechanics WITH diversification at small account sizes, avoiding
 *   the odd-lot penalty. Usually the right answer below roughly $500k of
 *   fixed income.
 */
type FiVehicle = "individual_bond" | "bond_etf" | "defined_maturity_etf";

interface VehicleSelection {
  /** Ladder rungs need defined maturity. Reserve needs daily liquidity. */
  purpose: "ladder_rung" | "rebalance_reserve" | "duration_exposure";

  /** Below this, individual bonds lose to markups and odd-lot pricing. */
  individualBondMinimumPerPositionUsd: Usd;   // ~100_000

  /** Below this total FI, use defined-maturity ETFs for the whole ladder. */
  definedMaturityEtfThresholdUsd: Usd;        // ~500_000

  selected: FiVehicle;
  rationale: string;
}

// ============================================================
// 2. INSTRUMENTS AND ACCOUNT LOCATION
// ============================================================

/**
 * Account location for fixed income is more consequential than for equities,
 * because the tax characteristics differ sharply BY INSTRUMENT rather than
 * uniformly across the sleeve.
 */
type FiInstrument =
  | "treasury"
  | "tips"
  | "agency"
  | "corporate_ig"
  | "corporate_hy"
  | "muni_national"
  | "muni_in_state"
  | "cash_equivalent";

interface InstrumentProfile {
  instrument: FiInstrument;

  /** Federal, state, or both. */
  federallyTaxable: boolean;
  stateTaxable: boolean;

  /**
   * Whether income counts toward MAGI. Muni interest does NOT — which keeps
   * it out of the SALT phase-down band, IRMAA, and NIIT. That is a benefit
   * BEYOND the headline tax exemption and is routinely omitted from crossover
   * math.
   *
   * Caveat: muni interest IS included in the Social Security taxability
   * calculation, so it is not fully invisible.
   */
  countsTowardMagi: boolean;

  /**
   * TIPS accrue inflation adjustments as CURRENT TAXABLE INCOME without a
   * cash distribution — "phantom income." Holding them in taxable means
   * paying tax on money not received. TIPS belong in tax-deferred, nearly
   * without exception.
   */
  hasPhantomIncome: boolean;

  preferredLocation: AccountTaxTreatment[];

  /** Hard prohibitions, not preferences. */
  prohibitedLocation: AccountTaxTreatment[];
}

/**
 * LOCATION RULES. The prohibitions matter more than the preferences.
 *
 * MUNIS IN AN IRA IS A HARD ERROR. You are paying for a tax exemption inside
 *   an account where all income is already sheltered, then converting the
 *   distribution to ordinary income on the way out. Pure waste.
 *
 * TIPS IN TAXABLE is a soft error for the phantom income reason above.
 *
 * TREASURIES ARE STATE-TAX-EXEMPT — materially valuable in NJ/NY/CA and a
 *   reason to prefer them to comparable-yield corporates in TAXABLE accounts
 *   specifically. The advantage disappears inside an IRA.
 *
 * CORPORATES AND HIGH YIELD generate ordinary income and belong sheltered.
 */
export const INSTRUMENT_PROFILES: InstrumentProfile[] = [
  {
    instrument: "treasury",
    federallyTaxable: true, stateTaxable: false, countsTowardMagi: true,
    hasPhantomIncome: false,
    preferredLocation: ["taxable"], prohibitedLocation: [],
  },
  {
    instrument: "tips",
    federallyTaxable: true, stateTaxable: false, countsTowardMagi: true,
    hasPhantomIncome: true,
    preferredLocation: ["tax_deferred", "tax_free"], prohibitedLocation: [],
  },
  {
    instrument: "corporate_ig",
    federallyTaxable: true, stateTaxable: true, countsTowardMagi: true,
    hasPhantomIncome: false,
    preferredLocation: ["tax_deferred", "tax_free"], prohibitedLocation: [],
  },
  {
    instrument: "corporate_hy",
    federallyTaxable: true, stateTaxable: true, countsTowardMagi: true,
    hasPhantomIncome: false,
    preferredLocation: ["tax_deferred", "tax_free"], prohibitedLocation: [],
  },
  {
    instrument: "muni_national",
    federallyTaxable: false, stateTaxable: true, countsTowardMagi: false,
    hasPhantomIncome: false,
    preferredLocation: ["taxable"],
    prohibitedLocation: ["tax_deferred", "tax_free"],
  },
  {
    instrument: "muni_in_state",
    federallyTaxable: false, stateTaxable: false, countsTowardMagi: false,
    hasPhantomIncome: false,
    preferredLocation: ["taxable"],
    prohibitedLocation: ["tax_deferred", "tax_free"],
  },
];

/**
 * MUNI CROSSOVER. Often the largest single fixed income decision for a
 * high-bracket household in a high-tax state.
 *
 * Naive: taxable equivalent yield = muni yield / (1 - marginal rate).
 *
 * The naive version understates munis for high earners because it omits:
 *   - NIIT on taxable interest
 *   - state tax (in-state munis exempt from both)
 *   - the MAGI effect: muni interest stays out of the SALT phase-down band
 *     and IRMAA tiers entirely
 *
 * And it overstates them by omitting:
 *   - the de minimis rule, which can convert discount bond appreciation into
 *     ordinary income
 *   - single-state concentration risk (credit, not just tax)
 *   - AMT exposure on private activity bonds
 *
 * v1 scope is federal-only, so the state leg is flagged rather than computed.
 */
interface MuniCrossover {
  muniYieldBps: Bps;
  treasuryYieldBps: Bps;
  corporateYieldBps: Bps;

  marginalOrdinaryRateBps: Bps;
  niitApplies: boolean;
  inSaltPhaseDownBand: boolean;

  /** Includes NIIT and MAGI effects, not just the headline rate. */
  taxableEquivalentYieldBps: Bps;

  muniPreferred: boolean;
  /** Flagged, not computed, in federal-only v1. */
  stateEffectUnmodeled: true;
}

// ============================================================
// 3. DURATION — DERIVED, NOT CHOSEN
// ============================================================

/**
 * In a liability-matching framework, duration is an OUTPUT of the outflow
 * schedule, not an input from a risk questionnaire.
 *
 * Match the duration of the FI sleeve to the duration of the liabilities it
 * funds and interest rate risk is largely immunized: rates rise, bond prices
 * fall, but reinvestment improves and the liability's present value falls
 * too. This is a cleaner answer than "we prefer intermediate duration," and
 * it is the answer most firms cannot give.
 */
interface DurationTarget {
  claimId: string;
  /** Macaulay duration of the inflated, discounted outflow schedule. */
  liabilityDurationYears: number;
  currentAssetDurationYears: number;
  mismatchYears: number;

  /**
   * Debt shortens household net duration. A 30-year fixed mortgage is a large
   * negative duration position and belongs in this calculation.
   */
  liabilitySideDurationOffsetYears: number;
  netHouseholdDurationYears: number;
}

// ============================================================
// 4. LIABILITY SIDE OF THE BALANCE SHEET
// ============================================================

type LiabilityKind =
  | "mortgage_primary"
  | "mortgage_investment"
  | "heloc"
  | "sbloc"              // securities-backed line
  | "margin"
  | "student_federal"
  | "student_private"
  | "auto"
  | "credit_card"
  | "business"
  | "unfunded_commitment"
  | "estate_tax_projected"
  | "deferred_tax";

interface Liability {
  id: string;
  kind: LiabilityKind;
  balanceUsd: Usd;
  rateBps: Bps;
  fixed: boolean;
  maturityDate: IsoDate | null;

  /** Duration of the liability. Negative FI exposure to the household. */
  durationYears: number;

  /**
   * Interest deductibility. Mortgage interest on acquisition debt up to the
   * limit; investment interest deductible against investment income; consumer
   * interest not deductible at all.
   *
   * Deductibility only has value IF THE HOUSEHOLD ITEMIZES — see the SALT
   * window analysis. In the current window a high-tax-state homeowner has
   * SALT capped out on state and property tax alone, making mortgage interest
   * fully incremental.
   */
  interestDeductible: boolean;
  afterTaxRateBps: Bps;

  /**
   * REVOCABILITY. The 2008 lesson, encoded.
   *
   * HELOCs were frozen and reduced exactly when borrowers needed them. An
   * SBLOC can be called and the collateral liquidated when the collateral
   * has fallen. Contingent liquidity that disappears in a drawdown is not
   * liquidity — it must never be counted in the liquidity floor.
   */
  revocable: boolean;
  countsAsContingentLiquidity: false;

  /**
   * A fixed-rate mortgage is a callable bond the household is SHORT and holds
   * the call on. Refinance option value rises as rates fall — a real asset
   * that most plans ignore.
   */
  refinanceOptionValueUsd?: Usd;
}

/**
 * PAY DOWN OR INVEST — the most common client question, and it has a clean
 * answer inside this framework.
 *
 * Paying down debt is buying a bond yielding the after-tax debt rate, with
 * ZERO credit risk and ZERO duration risk. So the comparison is not
 * "mortgage rate vs expected equity return" — it is "after-tax debt rate vs
 * after-tax FIXED INCOME yield," risk-matched.
 *
 * Consequences that fall out:
 *   - Paying down a 6% mortgage while holding 4% bonds is strictly better
 *     than holding both. Retiring debt IS the fixed income allocation.
 *   - In the SALT window the after-tax mortgage rate DROPS, which weakens the
 *     paydown case — an argument for keeping mortgage debt through 2029,
 *     the opposite of default advice.
 *   - Liquidity has option value. Full paydown converts liquid assets into
 *     illiquid home equity that cannot fund a drawdown or be rebalanced from.
 */
interface PaydownAnalysis {
  liabilityId: string;
  afterTaxDebtRateBps: Bps;
  comparableFiYieldAfterTaxBps: Bps;
  spreadBps: Bps;

  liquidityCostOfPaydownUsd: Usd;
  saltWindowActive: boolean;
  recommendation: "pay_down" | "maintain" | "borrow_more" | "refinance";
  rationale: string;
}

// ============================================================
// 5. DEFERRED TAX — the largest unstated liability
// ============================================================

/**
 * A $2M traditional IRA and a $2M Roth are NOT the same asset. Every account
 * statement ever produced shows them as equal.
 *
 * The embedded tax on tax-deferred balances and on unrealized gains in
 * taxable accounts is a real liability. Showing gross net worth systematically
 * overstates what a household actually has — commonly by 15-25%.
 *
 * WHERE THIS FRAMEWORK DIVERGES: the deferred tax on a lot earmarked
 * hold_to_step_up is NOT a liability, because it is never paid. Step-up
 * extinguishes it. So the same unrealized gain is a liability or not
 * DEPENDING ON ITS DISPOSITION — which means the balance sheet and the
 * disposition engine are linked, and neither is complete alone.
 */
interface DeferredTaxLiability {
  accountId: string;
  treatment: AccountTaxTreatment;

  balanceUsd: Usd;
  unrealizedGainUsd: Usd;

  /** Ordinary rate for tax-deferred; LTCG for taxable. */
  applicableRateBps: Bps;

  /** True for lots earmarked to step-up. Liability is zero. */
  extinguishedByStepUp: boolean;

  /** For IRD assets, the heir's bracket governs, not the client's. */
  heirRateAppliesBps: Bps | null;

  estimatedLiabilityUsd: Usd;
}

// ============================================================
// 6. COMPONENT VIEW
// ============================================================

/**
 * The presentable object. Assets and liabilities on one page, with the
 * three numbers most statements never show:
 *
 *   1. AFTER-TAX net worth (gross less deferred tax)
 *   2. NET fixed income exposure (FI assets less debt)
 *   3. TOTAL BALANCE SHEET equity (portfolio + human capital beta +
 *      unvested comp + levered real estate)
 *
 * Any one of these can reverse the conclusion a client drew from their
 * brokerage statement.
 */
interface BalanceSheetView {
  householdId: string;
  asOf: IsoDate;

  assets: {
    portfolioUsd: Usd;
    realEstateUsd: Usd;              // gross, not equity
    humanCapitalPvUsd: Usd;
    socialSecurityPvUsd: Usd;
    pensionPvUsd: Usd;
    businessUsd: Usd;
    illiquidAltsUsd: Usd;
  };

  liabilities: {
    debtUsd: Usd;
    unfundedCommitmentsUsd: Usd;
    deferredTaxUsd: Usd;
    projectedEstateTaxUsd: Usd;
    goalLiabilityPvUsd: Usd;         // inflated, discounted outflows
  };

  grossNetWorthUsd: Usd;
  afterTaxNetWorthUsd: Usd;

  /** The number no statement shows. Frequently negative. */
  netFixedIncomeUsd: Usd;
  netHouseholdDurationYears: number;

  totalBalanceSheetEquityBps: Bps;

  /** Assets + PV inflows over liabilities. The headline. */
  fundedRatioBps: Bps;
}

export const FI_LIABILITY_CONSTRAINTS = [
  {
    id: "muni_in_sheltered_account",
    severity: "hard" as const,
    description:
      "Municipal bonds held in a tax-deferred or tax-free account. Paying for an exemption inside an account that is already sheltered, then converting the proceeds to ordinary income on withdrawal.",
  },
  {
    id: "tips_in_taxable",
    severity: "soft" as const,
    description:
      "TIPS in a taxable account. Inflation accruals are taxed currently without a cash distribution — tax due on money not received.",
  },
  {
    id: "negative_net_fixed_income",
    severity: "soft" as const,
    description:
      "Debt exceeds fixed income assets. The household believes it holds a defensive allocation while running net short duration.",
  },
  {
    id: "revocable_credit_in_liquidity_floor",
    severity: "hard" as const,
    description:
      "HELOC or SBLOC counted toward the liquidity floor. Both were withdrawn or called in past drawdowns — exactly when needed.",
  },
  {
    id: "duration_mismatch",
    severity: "soft" as const,
    description:
      "FI duration materially different from the duration of the liabilities it funds. Duration should be derived from the outflow schedule, not chosen.",
  },
  {
    id: "odd_lot_ladder",
    severity: "soft" as const,
    description:
      "Individual bond positions below the odd-lot threshold. Markups likely exceed the benefit over a defined-maturity ETF.",
  },
  {
    id: "gross_net_worth_displayed",
    severity: "soft" as const,
    description:
      "Presentation showing gross rather than after-tax net worth. Overstates available wealth, commonly by 15-25%.",
  },
];

export type {
  FiVehicle,
  VehicleSelection,
  FiInstrument,
  InstrumentProfile,
  MuniCrossover,
  DurationTarget,
  LiabilityKind,
  Liability,
  PaydownAnalysis,
  DeferredTaxLiability,
  BalanceSheetView,
};
