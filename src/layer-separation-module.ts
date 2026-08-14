/**
 * LAYER SEPARATION MODULE — v1
 * ============================
 *
 * Resolves a direct conflict between two rules already in the schema:
 *
 *   policy-schema-v2.ts  -> correctionFractionBps: 6000
 *                           Partial correction, let drift run. Premised on
 *                           mean reversion operating over 3-5 years.
 *
 *   exposure-matrix      -> country and sector tilts are SHORT TERM,
 *                           roughly 6-18 months.
 *
 * Left as one system these fight each other. The slow strategic rebalancer
 * will partially unwind a tilt you deliberately put on, or keep holding one
 * you meant to exit. Neither layer does its job.
 *
 * RESOLUTION: every holding carries a layer tag. Two rebalancing regimes run
 * independently against the same portfolio, and neither is permitted to
 * touch the other's positions.
 */

import type { Bps, Usd, IsoDate } from "./policy-schema-v2";
import type { Tilt, TiltAxis } from "./exposure-matrix-module";

// ============================================================
// THE TAG
// ============================================================

/**
 * strategic: policy sleeves. Perpetual horizon, annual bands, partial
 *   correction, step-up earmarks respected, gains budgeted or forbidden.
 *
 * tactical: overlay expressing an active view. Finite horizon, hard exit,
 *   own cost accounting, sheltered accounts only.
 *
 * ladder: liability-matched fixed income. Held to maturity by construction —
 *   NOT rebalanced by either engine, only rolled forward.
 *
 * A position may not be in two layers. If a strategic sleeve and a tactical
 * tilt both want XLK, they are separate tax lots under separate tags. This
 * is bookkeeping discipline, not a technicality: without it, an exit sells
 * shares the strategic layer was holding to step-up.
 */
type Layer = "strategic" | "tactical" | "ladder";

interface TaggedLot {
  lotId: string;
  ticker: string;
  layer: Layer;
  accountId: string;
  acquiredAt: IsoDate;
  quantity: number;
  costBasisUsd: Usd;

  /** Tactical lots reference the tilt that created them. */
  tiltId?: string;

  /** Strategic lots may carry a step-up earmark. Tactical lots never do. */
  holdToStepUp: boolean;
}

// ============================================================
// HOLDING PERIOD — separate from thesis review
// ============================================================

/**
 * reviewBy and maxHoldingPeriod do DIFFERENT jobs, and the difference only
 * matters in the case where discipline is hardest:
 *
 *   reviewBy         asks "is the thesis still valid?"
 *   maxHoldingPeriod asserts a ceiling REGARDLESS of the answer.
 *
 * They diverge precisely when the thesis is intact, the position is working,
 * and the horizon has elapsed. Re-entry with a freshly written thesis is
 * legitimate. Drifting past the horizon without deciding is not — that is how
 * a tactical sleeve silently becomes a strategic allocation nobody chose.
 */
interface HoldingPeriodPolicy {
  axis: TiltAxis;

  /** Thesis re-examination cadence. */
  reviewIntervalDays: number;

  /** Hard ceiling. Exit or documented re-entry — no third option. */
  maxHoldingDays: number;

  /**
   * Re-entry requires a NEW thesis, written before the exit executes.
   * Reusing the original text is prohibited: if it still reads as written,
   * the position was never tactical.
   */
  requiresFreshThesisOnReentry: true;

  /**
   * Minimum days out of the position before re-entry. Prevents a paper
   * round-trip that satisfies the letter of the ceiling and nothing else.
   * Set to 0 to allow immediate documented re-entry.
   */
  reentryCooldownDays: number;
}

export const HOLDING_PERIODS: HoldingPeriodPolicy[] = [
  {
    axis: "sector",
    reviewIntervalDays: 90,
    maxHoldingDays: 548,          // ~18 months
    requiresFreshThesisOnReentry: true,
    reentryCooldownDays: 0,
  },
  {
    axis: "geo",
    reviewIntervalDays: 90,
    maxHoldingDays: 548,
    requiresFreshThesisOnReentry: true,
    reentryCooldownDays: 0,
  },
];

// ============================================================
// TWO REBALANCING REGIMES
// ============================================================

/**
 * Strategic engine. Unchanged from v2 — annual review, partial correction,
 * momentum allowed to run, hard outer bands as backstop.
 *
 * MUST NOT see tactical lots. If it does, it reads the overlay as drift and
 * unwinds it.
 */
interface StrategicRebalanceRegime {
  layer: "strategic";
  reviewCadence: "annual";
  outerBandMultiplier: number;
  correctionFractionBps: Bps;
  preferCashFlowRebalancing: boolean;
  realizedGainBudgetBps: Bps | null;
  respectStepUpEarmarks: true;
  /** Enforced exclusion, not a convention. */
  excludesLayers: ["tactical"];
}

/**
 * Tactical engine. Different clock, different exit logic, different cost
 * accounting.
 *
 * No bands: a tilt is sized once at entry and exits on thesis, horizon, or
 * stop. Banding a tactical position would mean adding to a losing active
 * view mechanically, which is the opposite of what the layer is for.
 */
interface TacticalRebalanceRegime {
  layer: "tactical";
  reviewCadence: "quarterly";

  /** Position sized at entry. Not maintained by drift correction. */
  maintainTargetWeight: false;

  exitTriggers: ("thesis_invalidated" | "horizon_reached" | "stop_loss" | "constraint_breach")[];

  /** Optional stop, as relative underperformance vs the funding leg. */
  stopLossRelativeBps: Bps | null;

  restrictToTreatments: ("tax_deferred" | "tax_free")[];
  excludesLayers: ["strategic", "ladder"];
}

// ============================================================
// ROUND-TRIP COST — the hurdle this layer must clear
// ============================================================

/**
 * A 300bp country tilt held ~12 months pays:
 *   - fee differential (single-country ~50-65bps vs core single digits)
 *   - entry spread + exit spread
 *   - premium/discount slippage on BOTH ends for stale-NAV funds
 *
 * Plausibly 80-100bps of round-trip friction on the tilted portion. That is
 * the number the thesis has to beat, and it is why geo carries roughly ten
 * times the sector hurdle.
 *
 * Computed at ENTRY and displayed before the tilt is committed. A tilt whose
 * expected relative return doesn't clear estimated cost should not be
 * enterable without an override.
 */
interface RoundTripCost {
  tiltId: string;
  feeDifferentialBps: Bps;
  estimatedSpreadBps: Bps;
  estimatedPremiumDiscountSlippageBps: Bps;
  expectedHoldingDays: number;

  /** Sum, annualized to the expected holding period. */
  totalEstimatedBps: Bps;

  /**
   * Short-term gains only. Tactical is sheltered, so this is normally 0 —
   * it exists to make the taxable-account override visibly expensive.
   */
  estimatedTaxCostBps: Bps;
}

/**
 * Hard gate at entry.
 * Blocks when expected relative return < estimated round-trip cost.
 * Override permitted, logged, and surfaced in the decision log.
 */
interface EntryGate {
  tiltId: string;
  expectedRelativeReturnBps: Bps;   // adviser's stated expectation
  estimatedCost: RoundTripCost;
  passes: boolean;
  overrideReason?: string;
  overriddenBy?: string;
  overriddenAt?: IsoDate;
}

// ============================================================
// LAYER BUDGET
// ============================================================

/**
 * Ceiling on how much of the portfolio the tactical layer may control.
 *
 * The honest framing: of everything in this system, tactical rotation is the
 * component with the weakest evidence base and the highest cost hurdle. The
 * goal-claim structure, the step-up discipline, and the bracket management
 * pay off with high confidence. This one might not.
 *
 * That argues for small and rigorously scored, not for zero — but the budget
 * should be sized so that being wrong for a decade costs basis points rather
 * than the plan.
 */
interface LayerBudget {
  maxTacticalShareOfEquityBps: Bps;
  maxTacticalShareOfPortfolioBps: Bps;

  /** Max simultaneous open tilts. Attention is a real constraint. */
  maxConcurrentTilts: number;

  /**
   * Rolling 12-month realized cost ceiling for the whole tactical layer.
   * Breach forces a pause on new entries until it rolls off. The layer has
   * to justify itself on net results, not gross ideas.
   */
  annualCostBudgetBps: Bps;
}

export const LAYER_BUDGET: LayerBudget = {
  maxTacticalShareOfEquityBps: 1700,   // ~17% of equity available for overlay
  maxTacticalShareOfPortfolioBps: 900,
  maxConcurrentTilts: 4,
  annualCostBudgetBps: 40,
};

// ============================================================
// ATTRIBUTION
// ============================================================

/**
 * Reported separately by layer. This is the whole point of the tag.
 *
 * Strategic return is beta and structure. Tactical return is the active bet.
 * Blending them makes the tactical layer unfalsifiable — a bull market hides
 * a decade of bad rotation.
 *
 * Score tactical against the FUNDING LEG, never against zero. A paired tilt
 * that made money while losing to what paid for it was a bad call that
 * happened during a rally.
 */
interface LayerAttribution {
  periodStart: IsoDate;
  periodEnd: IsoDate;

  strategicReturnBps: Bps;

  /** Tilt leg less funding leg, aggregated across closed and open tilts. */
  tacticalRelativeReturnBps: Bps;

  /** Fees, spreads, slippage, and any realized tax attributable to overlay. */
  tacticalCostBps: Bps;

  /** The number that decides whether this layer survives. */
  tacticalNetContributionBps: Bps;

  /** Hit rate and average win/loss — small samples, read with care. */
  tiltsClosed: number;
  tiltsProfitable: number;
}

// ============================================================
// EVALUATION
// ============================================================

declare function partitionByLayer(lots: TaggedLot[]): Record<Layer, TaggedLot[]>;

/** Strategic engine sees strategic lots only. Enforced, not conventional. */
declare function evaluateStrategic(
  lots: TaggedLot[],
  regime: StrategicRebalanceRegime
): { lotId: string; action: "hold" | "trim" | "add"; amountUsd: Usd }[];

declare function evaluateTactical(
  tilts: Tilt[],
  lots: TaggedLot[],
  regime: TacticalRebalanceRegime,
  holdingPeriods: HoldingPeriodPolicy[],
  asOf: IsoDate
): { tiltId: string; action: "hold" | "review" | "exit"; reason: string }[];

declare function computeRoundTripCost(tilt: Tilt, asOf: IsoDate): RoundTripCost;

export const LAYER_CONSTRAINTS = [
  {
    id: "layer_isolation",
    severity: "hard" as const,
    description:
      "Strategic rebalancing may not transact in tactical lots, and vice versa. Without enforcement the slow engine unwinds the fast layer's positions.",
  },
  {
    id: "no_tactical_step_up",
    severity: "hard" as const,
    description:
      "Tactical lots may never carry a holdToStepUp earmark. A finite-horizon position cannot also be a perpetual one.",
  },
  {
    id: "holding_period_ceiling",
    severity: "hard" as const,
    description:
      "Tilt held beyond maxHoldingDays must exit or re-enter with a freshly written thesis. Original text may not be reused.",
  },
  {
    id: "entry_gate",
    severity: "soft" as const,
    description:
      "Expected relative return below estimated round-trip cost. Override permitted but logged and surfaced in attribution.",
  },
  {
    id: "annual_cost_budget",
    severity: "hard" as const,
    description:
      "Trailing 12-month tactical cost above budget pauses new entries until it rolls off.",
  },
];

export type {
  Layer,
  TaggedLot,
  HoldingPeriodPolicy,
  StrategicRebalanceRegime,
  TacticalRebalanceRegime,
  RoundTripCost,
  EntryGate,
  LayerBudget,
  LayerAttribution,
};
