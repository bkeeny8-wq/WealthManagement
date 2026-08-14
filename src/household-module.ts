/**
 * HOUSEHOLD & HUMAN CAPITAL MODULE — v1
 * =====================================
 *
 * The intake layer. Everything downstream — goal claims, funding status,
 * required return, allocation capacity — is derived from here.
 *
 * TWO IDEAS DO MOST OF THE WORK:
 *
 * 1. HUMAN CAPITAL IS AN ASSET WITH A BETA. For most households it is the
 *    largest thing on the balance sheet, and its character determines how
 *    much equity the PORTFOLIO can carry. A tenured professor's income is
 *    bond-like. A structured products VP's income is levered equity beta —
 *    bonus, deferred comp, and job security all fall together, in the same
 *    drawdown that hits the portfolio, in the same sector the portfolio may
 *    already overweight.
 *
 * 2. GOAL FLEXIBILITY IS A RISK LEVER, AND A STRONGER ONE THAN ALLOCATION.
 *    Deferring a pool by three years does more for plan resilience than any
 *    tilt. Tuition in 2031 cannot move. Modeling which goals can flex is
 *    worth more than modeling which assets to hold.
 */

import type { Bps, Usd, IsoDate } from "./policy-schema-v2";
import type { Sector } from "./sector-tilt-module";

type FilingStatus = "single" | "mfj" | "mfs" | "hoh";

// ============================================================
// PEOPLE
// ============================================================

interface Person {
  id: string;
  label: string;
  birthDate: IsoDate;
  role: "primary" | "spouse" | "dependent";
  expectedRetirementAge: number;

  /**
   * Drives longevity modeling. Planning to life expectancy underfunds roughly
   * half of clients by construction — model to a high percentile instead.
   */
  healthStatus: "excellent" | "good" | "fair" | "poor";
  longevityPercentileTarget: number;   // e.g. 90
}

// ============================================================
// HUMAN CAPITAL
// ============================================================

/**
 * Income character. THE field that should drive portfolio equity capacity.
 *
 * The standard lifecycle result — "young people should hold more equity
 * because their bond-like human capital dominates" — INVERTS for finance
 * professionals. Their human capital is equity-like and sector-concentrated,
 * so the portfolio should hold LESS equity and specifically underweight
 * their own sector, not more.
 *
 * This is the same total-balance-sheet logic already applied to home equity,
 * applied to the asset that is actually largest mid-career. Almost no tool
 * does it.
 */
type IncomeCharacter =
  | "bond_like"        // tenured, government, utility — stable, low beta
  | "moderate"         // typical corporate salary
  | "equity_like"      // bonus-driven, cyclical
  | "levered_equity";  // finance, sales, carry — high beta, drawdown-correlated

interface HumanCapital {
  personId: string;

  baseSalaryUsd: Usd;
  /** Expected, not last year's. Bonus variance is the point. */
  expectedBonusUsd: Usd;
  bonusVolatilityBps: Bps;

  character: IncomeCharacter;

  /**
   * Implied beta of income to equity markets. Used to compute total-balance-
   * sheet equity exposure. A levered_equity earner may already be running
   * equivalent equity exposure through their job before owning a single share.
   */
  impliedBeta: number;

  /** Sector the income is concentrated in. Feeds the exposure matrix. */
  sectorConcentration: Sector | null;

  /**
   * Years of remaining earning power. Human capital PV declines toward zero
   * at retirement, which is the real driver of the glide — not age itself.
   */
  yearsRemaining: number;
  realGrowthRateBps: Bps;

  /** Computed. Often the largest asset on the balance sheet mid-career. */
  presentValueUsd: Usd;

  /**
   * Probability of job loss in a market drawdown. For levered_equity earners
   * this is materially above the unconditional rate — the correlation is the
   * risk, not the level.
   */
  jobLossInDrawdownProbabilityBps: Bps;
}

/**
 * Unvested equity comp. A concentrated, illiquid, employer-credit-exposed
 * position that most clients do not count as part of their portfolio.
 *
 * Compounds the human capital problem: the RSUs vest in the same company
 * whose bonus pool and headcount fall in the same drawdown.
 */
interface DeferredCompensation {
  personId: string;
  kind: "rsu" | "options" | "deferred_cash" | "carry" | "espp";
  ticker: string | null;
  grantValueUsd: Usd;
  vestingSchedule: { date: IsoDate; amountUsd: Usd }[];

  /** Deferred cash comp is an UNSECURED CLAIM on the employer. Credit risk. */
  subjectToEmployerCredit: boolean;

  /** Blackout windows and 10b5-1 requirements constrain diversification. */
  tradingRestricted: boolean;
}

/**
 * TWO-EARNER CORRELATION — usually ignored, materially important.
 *
 * Two finance incomes are one income with extra steps: they fall together,
 * in the same shock. Two uncorrelated incomes (one finance, one healthcare
 * or education) function as a partial bond position for the household and
 * genuinely increase equity capacity.
 *
 * Household equity capacity should be computed from the JOINT income
 * distribution, never from the sum of two independent ones.
 */
interface HouseholdIncomeProfile {
  incomeCorrelation: number;           // between earners, 0-1
  primaryShareOfIncomeBps: Bps;
  /** Can the household survive on one income? Drives reserve sizing. */
  survivableOnSingleIncome: boolean;
}

// ============================================================
// SOCIAL SECURITY
// ============================================================

/**
 * Frequently the largest inflation-linked, government-backed asset the
 * household owns — PV can rival the portfolio. Belongs in external assets
 * offsetting the spending claim, which shortens the required ladder.
 *
 * Two decisions worth real money:
 *
 * CLAIMING AGE. Delaying past full retirement age earns delayed retirement
 * credits until 70. The break-even is typically in the early 80s, so for a
 * healthy client the delay is usually right — but it is longevity insurance,
 * not a bet.
 *
 * SURVIVOR BENEFIT. For a couple, the survivor keeps the HIGHER of the two
 * benefits. So the higher earner delaying is insurance on the SURVIVOR's
 * income, not just their own. That reframes the decision entirely and is
 * routinely missed.
 */
interface SocialSecurityProfile {
  personId: string;
  estimatedPIAUsd: Usd;                // monthly primary insurance amount at FRA
  fullRetirementAge: number;
  plannedClaimingAge: number;

  /** Computed: PV as an inflation-linked annuity at the plan's discount rate. */
  presentValueUsd: Usd;

  /** Spousal benefit up to 50% of the higher earner's PIA at FRA. */
  eligibleForSpousalBenefit: boolean;
  /** Survivor receives the higher of the two benefits. */
  survivorBenefitApplies: boolean;

  /**
   * Benefits are partially taxable above income thresholds, and the
   * "tax torpedo" creates effective marginal rates well above the statutory
   * bracket in a band. Interacts with Roth conversion sizing.
   */
  taxTorpedoAware: true;
}

// ============================================================
// GOALS
// ============================================================

/**
 * Tier drives shortfall tolerance. Not all goals deserve the same certainty,
 * and treating them equally is how plans become needlessly conservative.
 */
type GoalTier =
  | "essential"      // housing, food, healthcare. Near-zero shortfall tolerance.
  | "lifestyle"      // travel, discretionary spending. Moderate.
  | "aspirational"   // pool, second home, legacy above baseline. High.
  ;

/**
 * FLEXIBILITY IS THE UNDERUSED LEVER.
 *
 * A goal that can be deferred, scaled, or abandoned costs far less to fund
 * than one that cannot. Most planning treats every goal as fixed, then solves
 * the resulting shortfall with allocation risk — which is backwards.
 */
interface GoalFlexibility {
  /** Can the date move? Tuition cannot. A pool can. */
  deferrableYears: number;
  /** Can the amount scale? A $80k wedding can be a $40k wedding. */
  scalableDownBps: Bps;
  /** Can it be dropped entirely under stress? */
  abandonable: boolean;
}

interface Goal {
  id: string;
  label: string;
  tier: GoalTier;

  targetDate: IsoDate;
  amountUsd: Usd;                      // today's dollars

  /**
   * Goal-specific inflation. Education and healthcare have historically run
   * meaningfully above headline CPI; construction costs run their own cycle.
   * Applying one CPI to every goal understates long-dated education funding.
   */
  inflationSeries: "cpi" | "education" | "healthcare" | "construction";

  recurring: boolean;
  recurringYears?: number;

  flexibility: GoalFlexibility;

  /** Derived from tier, overridable per goal. */
  maxShortfallProbabilityBps: Bps;

  /** Dedicated funding vehicle, if any. */
  fundingAccountId?: string;

  /** Which claim this rolls into. Generates the GoalClaim objects. */
  claimId: string;
}

/**
 * Education deserves its own object — the mechanics differ enough to matter.
 */
interface EducationGoal extends Goal {
  childId: string;
  startYear: number;
  years: number;

  /** 529 balance and state deduction status. */
  five29BalanceUsd: Usd;

  /**
   * Unused 529 funds may be rolled to the beneficiary's Roth IRA subject to
   * lifetime and annual caps and an account-age requirement. Materially
   * reduces the overfunding risk that historically deterred 529 use.
   * VERIFY current limits before relying on this.
   */
  rothRolloverEligible: boolean;

  /**
   * Aid formulas treat parent assets far more favorably than student assets.
   * A 529 owned by a grandparent has different treatment again. Worth
   * modeling if aid is plausibly in scope.
   */
  aidSensitive: boolean;
}

// ============================================================
// CHILDREN — also heirs
// ============================================================

/**
 * Children appear TWICE in the model and the second appearance is usually
 * forgotten: they are goal recipients during life and beneficiaries at death.
 *
 * Their expected tax bracket at inheritance drives the IRD decision. Leaving
 * a large traditional IRA to a high-earning child means ordinary rates
 * compressed into ten years, during their peak earning years. Leaving it to a
 * lower-bracket child, or to charity, is a different outcome for the same
 * dollar.
 */
interface Child {
  personId: string;
  birthDate: IsoDate;
  expectedInheritanceBracketBps: Bps | null;
  /** Feeds the estate-liquidity and partition-risk checks. */
  likelyToWantLiquidity: boolean;
}

// ============================================================
// HOUSEHOLD
// ============================================================

interface HouseholdProfile {
  id: string;
  filingStatus: FilingStatus;
  stateOfResidence: string;            // v1 federal-only; recorded for later

  people: Person[];
  children: Child[];

  humanCapital: HumanCapital[];
  deferredComp: DeferredCompensation[];
  incomeProfile: HouseholdIncomeProfile;
  socialSecurity: SocialSecurityProfile[];

  goals: Goal[];

  /**
   * DERIVED, not entered.
   *
   * Total-balance-sheet equity exposure = portfolio equity
   *                                     + human capital PV x impliedBeta
   *                                     + unvested equity comp
   *                                     + levered real estate equity
   *
   * For a mid-career finance professional this frequently shows the household
   * ALREADY at or above its intended equity exposure before the portfolio is
   * considered — which is the argument for a lower portfolio equity weight
   * and an explicit underweight to their own sector.
   */
  totalBalanceSheetEquityBps?: Bps;
  portfolioEquityCapacityBps?: Bps;
}

// ============================================================
// REQUIRED RETURN — the anchor
// ============================================================

/**
 * Computed from goals and current assets. NO capital market assumptions
 * required — this is arithmetic.
 *
 * Report this FIRST, then let the CMA module answer the separate question of
 * how plausible it is. A single success probability launders enormous
 * assumption risk into a number clients read as precise; a required return
 * plus a plausibility range puts the uncertainty where it actually lives.
 */
interface RequiredReturn {
  claimId: string;
  currentAssetsUsd: Usd;
  externalAssetPvUsd: Usd;             // Social Security, pension, home equity
  futureSavingsPvUsd: Usd;
  liabilityPvUsd: Usd;                 // inflated goal outflows, discounted

  /** The number. Real, annualized. */
  requiredRealReturnBps: Bps;

  /** Same, after flexing every flexible goal to its most conservative setting. */
  requiredRealReturnWithFlexibilityBps: Bps;

  fundedRatioBps: Bps;                 // assets + PV inflows / liabilities
}

export const HOUSEHOLD_CONSTRAINTS = [
  {
    id: "human_capital_sector_stacking",
    severity: "soft" as const,
    description:
      "Portfolio overweights the same sector the client's income depends on. Employer stock, unvested comp, and a sector tilt can stack into a single undeclared bet that resolves in one drawdown.",
  },
  {
    id: "equity_capacity_exceeded",
    severity: "soft" as const,
    description:
      "Total-balance-sheet equity exposure exceeds capacity once human capital beta and unvested comp are included.",
  },
  {
    id: "correlated_dual_income",
    severity: "soft" as const,
    description:
      "Both earners in correlated industries with no single-income survivability. Reserve should be sized to joint income loss, not to one.",
  },
  {
    id: "employer_credit_concentration",
    severity: "hard" as const,
    description:
      "Deferred cash comp is an unsecured claim on the employer, stacked on salary, bonus, and any employer stock. Aggregate exposure to a single employer's credit and equity.",
  },
  {
    id: "inflexible_goal_cluster",
    severity: "soft" as const,
    description:
      "Multiple non-deferrable goals within a narrow window. Concentrated inflexible liabilities remove the cheapest risk lever available.",
  },
];

export type {
  Person,
  HumanCapital,
  IncomeCharacter,
  DeferredCompensation,
  HouseholdIncomeProfile,
  SocialSecurityProfile,
  Goal,
  GoalTier,
  GoalFlexibility,
  EducationGoal,
  Child,
  HouseholdProfile,
  RequiredReturn,
};
