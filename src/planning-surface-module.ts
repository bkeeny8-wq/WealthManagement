/**
 * PLANNING SURFACE MODULE — v1
 * ============================
 *
 * The pieces outside allocation that determine whether a plan survives
 * contact with a real client. Each was flagged as an open item; all are
 * encoded here rather than left in conversation.
 *
 * Sections:
 *   1. Transition management — how a prospect's portfolio becomes yours
 *   2. Risk tolerance vs capacity — the constraint the rest of the schema lacks
 *   3. Insurance — the largest unmodeled tail
 *   4. Equity comp mechanics
 *   5. Charitable vehicles
 *   6. 529-to-Roth (verified 2026 rules)
 *   7. Practice continuity
 */

import type { Bps, Usd, IsoDate } from "./policy-schema-v2";

// ============================================================
// 1. TRANSITION MANAGEMENT
// ============================================================

/**
 * THE GAP THE FRAMEWORK HAD: it describes a target state with no path to it.
 *
 * Clients do not arrive with cash. They arrive with twenty-odd fragmented
 * positions carrying embedded gains. Getting from their portfolio to the
 * policy is a multi-year, tax-budgeted project — and it is the part prospects
 * ask about first. Year one is won or lost here.
 */
interface TransitionPlan {
  householdId: string;
  startDate: IsoDate;
  targetCompletionYears: number;

  /** Annual realized gain the client will tolerate. The binding constraint. */
  annualGainBudgetUsd: Usd;

  positions: TransitionPosition[];

  /**
   * Legacy positions kept permanently because the embedded gain is too large
   * to ever justify realizing. These become part of the policy, not
   * exceptions to it — a step-up earmark, with the exposure matrix adjusted
   * around them rather than fighting them.
   */
  permanentHoldPolicy: "absorb_into_matrix" | "hedge" | "unwind_at_death";
}

interface TransitionPosition {
  ticker: string;
  marketValueUsd: Usd;
  costBasisUsd: Usd;
  unrealizedGainBps: Bps;

  disposition:
    | "keep_as_core"          // already fits policy; retag, don't trade
    | "keep_as_tlh_partner"   // close enough to serve a role
    | "unwind_scheduled"      // sell over N years within the gain budget
    | "unwind_immediate"      // loss or small gain; no reason to wait
    | "permanent_hold"        // gain too large; earmark to step-up
    | "gift_or_donate";       // appreciated shares to DAF or family

  /** Years over which to unwind, if scheduled. */
  unwindYears?: number;

  /**
   * Concentration risk while waiting. A permanent-hold position that is 25%
   * of the portfolio is a policy violation the plan has chosen to accept —
   * it should be visible as such, not silently excluded.
   */
  isConcentrated: boolean;
}

/**
 * Accelerators. Each removes gain from the budget without realizing it.
 */
type TransitionAccelerator =
  | "loss_harvesting"          // pair gains against harvested losses
  | "charitable_appreciated"   // donate the lowest-basis lots, deduct at FMV
  | "gifting_to_family"        // carryover basis, but to a lower bracket
  | "gain_in_low_income_year"  // job change, sabbatical, retirement gap
  | "exchange_fund";           // diversify without realizing; long lockup

// ============================================================
// 2. RISK CAPACITY VS TOLERANCE
// ============================================================

/**
 * The framework computes CAPACITY — what the goals can withstand. It says
 * nothing about what the client will actually sit through.
 *
 * A plan abandoned in March 2020 is worth less than a worse plan held. So
 * tolerance is a genuine CONSTRAINT on allocation, not a soft overlay.
 *
 * The gap between the two numbers is itself the most useful client
 * conversation available: "your goals can support 70% equity; your stated
 * tolerance supports 50%. Closing that gap is worth more than any investment
 * decision we will make."
 */
interface RiskProfile {
  householdId: string;

  /** Derived from goals, funding status, horizon, human capital. */
  capacityEquityBps: Bps;

  /** Elicited. Max drawdown the client says they would hold through. */
  statedToleranceMaxDrawdownBps: Bps;
  toleranceImpliedEquityBps: Bps;

  /**
   * Observed, not stated. Did they sell in a past drawdown? Behavior beats
   * questionnaires — every questionnaire is administered in a calm market.
   */
  observedBehavior: "held" | "sold_partially" | "sold_out" | "unknown";

  /** Binding constraint is the LOWER of capacity and tolerance. */
  bindingEquityBps: Bps;
  bindingConstraint: "capacity" | "tolerance";

  /**
   * Gap in basis points. Large gaps mean the plan needs either goal
   * flexibility, more savings, or a real conversation — not more risk.
   */
  gapBps: Bps;
}

// ============================================================
// 3. INSURANCE — the largest unmodeled tail
// ============================================================

/**
 * A plan that models sequence risk but not health-shock risk is modeling the
 * smaller problem. A multi-year care event can exceed anything the tactical
 * sleeve will ever produce, and it lands precisely when the portfolio can
 * least absorb it.
 */
interface InsuranceProfile {
  householdId: string;

  /**
   * DISABILITY. During accumulation, human capital is the dominant asset —
   * so the dominant risk is its loss, not portfolio volatility. Group
   * coverage is usually inadequate for high earners: it caps out, often
   * excludes bonus, and benefits are taxable when the employer pays premiums.
   */
  disability: {
    groupCoverageUsd: Usd;
    individualCoverageUsd: Usd;
    coversBonus: boolean;
    ownOccupation: boolean;
    benefitsTaxable: boolean;
    humanCapitalAtRiskUsd: Usd;
    coverageGapUsd: Usd;
  };

  /** LIFE. Sized to the survivor's funding gap, not to a salary multiple. */
  life: {
    inForceUsd: Usd;
    /** Liabilities less assets less survivor Social Security PV. */
    needUsd: Usd;
    kind: "term" | "permanent" | "mixed";
    /** Permanent policies inside an ILIT sit outside the taxable estate. */
    inIrrevocableTrust: boolean;
  };

  /**
   * LONG-TERM CARE. The tail that breaks perpetual-corpus plans.
   *
   * Three funding paths, each with a different failure mode:
   *   - self-fund: requires a dedicated, liquid, ring-fenced reserve, or the
   *     "reserve" is really the legacy claim being spent
   *   - traditional LTC: premiums are not guaranteed level; carriers have
   *     repriced in force
   *   - hybrid life/LTC: pricier per dollar of benefit but no use-it-or-lose-it
   */
  longTermCare: {
    approach: "self_fund" | "traditional_ltc" | "hybrid" | "none";
    /** If self-funding, this must be a ring-fenced claim, not a vague plan. */
    dedicatedReserveClaimId: string | null;
    estimatedAnnualCostUsd: Usd;
    estimatedDurationYears: number;
    /**
     * Model BOTH spouses needing care. Sequential events are the scenario
     * that empties a corpus, and single-event modeling misses it.
     */
    modelsSequentialEvents: boolean;
  };

  /** UMBRELLA. Cheap, and the one that protects against a plan-ending judgment. */
  umbrellaUsd: Usd;
}

// ============================================================
// 4. EQUITY COMPENSATION MECHANICS
// ============================================================

interface EquityCompMechanics {
  personId: string;

  /**
   * 10b5-1 plans allow scheduled sales for insiders and those under blackout,
   * with a mandatory cooling-off period between adoption and first trade.
   * The planning consequence: diversification must be SCHEDULED WELL AHEAD,
   * not executed when the client decides they are uncomfortable.
   */
  requires10b51: boolean;
  coolingOffDays: number;

  /**
   * ISOs create AMT exposure on exercise-and-hold: the bargain element is an
   * AMT preference item even though no cash was received. The classic
   * disaster is exercising, holding for long-term treatment, and watching the
   * stock fall below the AMT liability.
   */
  hasISOs: boolean;
  amtExposureUsd: Usd;

  /**
   * 83(b) election on restricted stock: pay ordinary tax on grant value now,
   * convert future appreciation to capital gain. 30-DAY WINDOW, IRREVOCABLE,
   * and worthless if the stock declines. Timing-critical and easy to miss.
   */
  eligible83b: boolean;
  election83bDeadline: IsoDate | null;

  /** ESPP discount is ordinary income; holding period governs the rest. */
  hasESPP: boolean;

  /**
   * QSBS: qualifying small business stock can exclude a substantial amount
   * of gain. Relevant for founder and early-employee clients. Rules are
   * specific and were modified recently — VERIFY before relying on it.
   */
  potentialQSBS: boolean;
}

// ============================================================
// 5. CHARITABLE VEHICLES
// ============================================================

/**
 * QCD is the single most efficient charitable move available to an RMD-age
 * client: it satisfies the RMD, is excluded from AGI entirely (better than a
 * deduction — it lowers MAGI and therefore IRMAA and the SALT phase-down),
 * and requires no itemizing.
 *
 * DAF bunching pairs directly with the SALT window: concentrate several years
 * of giving into one year to clear the standard deduction while the enlarged
 * cap is available. Fund it with the lowest-basis appreciated lots from the
 * transition plan — deduct at fair value, never realize the gain.
 */
interface CharitableProfile {
  householdId: string;

  annualGivingUsd: Usd;

  qcd: {
    eligible: boolean;              // IRA owners at qualifying age
    annualLimitUsd: Usd;            // indexed; verify current figure
    plannedUsd: Usd;
    /** Excluded from AGI — reduces IRMAA and SALT phase-down exposure. */
    reducesMagi: true;
  };

  daf: {
    exists: boolean;
    balanceUsd: Usd;
    /** Bunch N years of giving into one to clear the standard deduction. */
    bunchingYears: number;
    fundedWithAppreciatedLots: boolean;
  };

  /** Bequest funded from the IRA, never from taxable. See disposition module. */
  charitableBequestSource: "ira" | "taxable" | "none";
}

// ============================================================
// 6. 529 -> ROTH ROLLOVER (verified 2026)
// ============================================================

/**
 * SECURE 2.0 Sec. 126. Materially reduces the overfunding risk that
 * historically deterred 529 use — but the conditions are strict.
 *
 * 2026 parameters:
 *   - $35,000 lifetime cap per beneficiary, across all 529s for that person
 *   - Annual cap = that year's IRA contribution limit: $7,500 under 50,
 *     $8,600 at 50+, REDUCED by the beneficiary's other IRA contributions
 *   - 529 must be open at least 15 years
 *   - Contributions (and their earnings) from the last 5 years are ineligible
 *   - Roth must belong to the 529 BENEFICIARY, not the account owner
 *   - Beneficiary must have earned income at least equal to the rollover
 *   - Roth income phase-outs DO NOT APPLY
 *
 * THE PLANNING CONSEQUENCE: the 15-year clock makes this a decision made at
 * the child's BIRTH, not at college. Open and fund early even if the college
 * need is uncertain — the account age is the scarce resource.
 *
 * THE HIGH-EARNER ANGLE: a household above the Roth phase-out cannot fund a
 * child's Roth directly, but can route $35,000 through this over 5+ years
 * regardless of income. Rare legal path to tax-free savings for children.
 *
 * CAVEAT: several states have indicated possible state income tax recapture
 * on rollovers. Out of scope for federal-only v1; flag before any use.
 */
interface FiveTwoNineRollover {
  childId: string;
  accountOpenedAt: IsoDate;

  lifetimeCapUsd: Usd;              // 35_000
  lifetimeUsedUsd: Usd;
  annualCapUsd: Usd;                // = IRA contribution limit for the year

  /** Hard gates. */
  accountAgeYears: number;          // must be >= 15
  fiveYearLookbackClear: boolean;   // recent contributions ineligible
  beneficiaryEarnedIncomeUsd: Usd;  // caps the rollover for the year
  beneficiaryOtherIraContributionsUsd: Usd;  // reduces available room

  incomePhaseOutsApply: false;

  /** Minimum years to move the full cap at current annual limits. */
  minimumYearsToFullRollover: number;   // ~5

  stateRecaptureRisk: boolean;
}

// ============================================================
// 7. PRACTICE CONTINUITY
// ============================================================

/**
 * If the philosophy lives in one head and one schema, clients are exposed to
 * a single point of failure. Matters for the business and for anyone
 * diligencing the practice.
 *
 * The schema itself is part of the answer: a written, versioned, executable
 * policy is far more transferable than an adviser's judgment. That is an
 * argument for keeping beliefs in data rather than in code or in memory.
 */
interface ContinuityPlan {
  successorAdviserNamed: boolean;
  policyDocumentedAndVersioned: boolean;
  clientAgreementsAssignable: boolean;
  dataPortable: boolean;
  reviewedAt: IsoDate;
}

export const PLANNING_CONSTRAINTS = [
  {
    id: "transition_gain_budget_exceeded",
    severity: "hard" as const,
    description: "Scheduled unwind exceeds the annual realized gain budget.",
  },
  {
    id: "tolerance_below_capacity",
    severity: "soft" as const,
    description:
      "Stated tolerance implies lower equity than goals require. Close with goal flexibility or savings, not with more risk.",
  },
  {
    id: "ltc_unfunded",
    severity: "hard" as const,
    description:
      "No LTC approach and no ring-fenced reserve. The largest tail in a perpetual-corpus plan is unmodeled.",
  },
  {
    id: "disability_gap",
    severity: "hard" as const,
    description:
      "Group disability coverage materially below human capital at risk. During accumulation this is the dominant risk, not portfolio volatility.",
  },
  {
    id: "concentrated_permanent_hold",
    severity: "soft" as const,
    description:
      "Permanent-hold legacy position exceeds concentration limits. An accepted violation must be visible, not silently excluded.",
  },
  {
    id: "83b_window",
    severity: "hard" as const,
    description: "83(b) election window closing. 30 days from grant, irrevocable.",
  },
  {
    id: "529_clock_not_started",
    severity: "soft" as const,
    description:
      "Child with no 529 open. The 15-year account-age requirement makes early opening the scarce resource, independent of funding level.",
  },
];

export type {
  TransitionPlan,
  TransitionPosition,
  TransitionAccelerator,
  RiskProfile,
  InsuranceProfile,
  EquityCompMechanics,
  CharitableProfile,
  FiveTwoNineRollover,
  ContinuityPlan,
};
