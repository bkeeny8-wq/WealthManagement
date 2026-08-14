/**
 * SECTOR TILT MODULE — v1 (manual selection)
 * ==========================================
 *
 * Extends policy-schema-v2.ts. Governs the core/satellite split INSIDE the
 * equity sleeve: broad index core plus SPDR sector overlays.
 *
 * v1 IS DELIBERATELY MANUAL. The adviser selects tilts; nothing detects
 * regimes. This is not a placeholder for a "real" version — it produces the
 * training data the rules version would need. Every tilt is a dated decision
 * with a stated thesis and a scoreable outcome. Automate only after the log
 * says your judgment was worth automating.
 *
 * THE CENTRAL PROBLEM THIS SOLVES:
 * Sector SPDRs are carve-outs of the same index the core tracks, so exposures
 * STACK. 25% SPY + 5% XLK is not 5% tech — SPY already carries ~8pts of tech
 * on a 30pt equity sleeve, so the true figure is ~13pts, north of 40% of
 * equity against a ~33% neutral. A "5% tilt" is really a ~10pt overweight.
 *
 * Therefore: nominal weights are meaningless. Every constraint evaluates
 * against LOOK-THROUGH exposure.
 */

import type { Bps, IsoDate } from "./policy-schema-v2";

// ============================================================
// SECTORS
// ============================================================

/**
 * GICS sectors. Note the classification is not static — real estate was
 * carved out of financials in 2016, communication services created in 2018
 * (moving Alphabet and Meta out of tech, Amazon into discretionary).
 * Historical comparisons across those dates are not apples to apples.
 */
type Sector =
  | "technology"
  | "financials"
  | "healthcare"
  | "consumer_discretionary"
  | "consumer_staples"
  | "industrials"
  | "energy"
  | "materials"
  | "utilities"
  | "real_estate"
  | "communication_services";

const SECTOR_ETF: Record<Sector, string> = {
  technology: "XLK",
  financials: "XLF",
  healthcare: "XLV",
  consumer_discretionary: "XLY",
  consumer_staples: "XLP",
  industrials: "XLI",
  energy: "XLE",
  materials: "XLB",
  utilities: "XLU",
  real_estate: "XLRE",
  communication_services: "XLC",
};

// ============================================================
// NEUTRAL WEIGHTS — fetched, never stored as policy
// ============================================================

/**
 * Sector weights drift continuously with prices and shift discretely with
 * GICS reclassification. "Neutral" is a LIVE number.
 *
 * Hardcode it and your tilts silently change meaning as the index
 * concentrates — a +300bps energy tilt written when energy was 5% of the
 * index means something very different when energy is 3%.
 *
 * A tilt is always a deviation from CURRENT neutral, never a fixed percentage.
 */
interface SectorNeutralSnapshot {
  index: "sp500" | "total_market";
  asOf: IsoDate;
  source: string;
  weightsBps: Record<Sector, Bps>;
  /** Staleness guard — refuse to evaluate tilts against an old snapshot. */
  maxAgeDays: number;
}

// ============================================================
// LOOK-THROUGH
// ============================================================

/**
 * Every equity holding decomposed to sector. Broad-index holdings contribute
 * their full sector breakdown; sector ETFs contribute ~100% to one sector.
 * All concentration and tilt constraints evaluate against THIS, never against
 * nominal sleeve weights.
 */
interface LookThroughExposure {
  asOf: IsoDate;
  /** Sector exposure as share of total EQUITY (not of total portfolio). */
  bySectorBps: Record<Sector, Bps>;
  /** Same, as share of total portfolio — for household-level constraints. */
  bySectorOfPortfolioBps: Record<Sector, Bps>;
  contributions: {
    ticker: string;
    weightInEquityBps: Bps;
    sectorBreakdownBps: Record<Sector, Bps>;
  }[];
}

// ============================================================
// TILT
// ============================================================

/**
 * How the overweight is paid for.
 *
 * pro_rata: funded from the core, implicitly underweighting all other sectors.
 *   Simple, but every tilt carries ten views you never formed.
 *
 * paired: explicit offsetting underweight in a named sector, everything else
 *   held neutral. More honest about where the view actually is, cleanly
 *   attributable after the fact, and far easier to explain to a client.
 *   Preferred.
 */
type TiltFunding = "pro_rata" | "paired";

interface SectorTilt {
  sector: Sector;

  /** Signed deviation from CURRENT neutral. Positive = overweight. */
  deviationBps: Bps;

  funding: TiltFunding;
  /** Required when funding is "paired". */
  offsetSector?: Sector;

  /**
   * The thesis, in a sentence. Mandatory and not decoration — this is what
   * makes the decision scoreable later. If you can't write it, don't take
   * the tilt.
   */
  thesis: string;

  openedAt: IsoDate;

  /**
   * Forced re-decision date. Without it, tilts become permanent by inertia
   * and the "tactical" sleeve is just a different strategic allocation.
   */
  reviewBy: IsoDate;

  /** Optional pre-committed exit. Stating it up front beats rationalizing later. */
  exitCondition?: string;
}

interface TiltPolicy {
  enabled: boolean;
  mode: "manual";   // v1. "signal_driven" is a later version.

  /** Broad-index core as a share of equity. Remainder available for overlay. */
  coreShareOfEquityBps: Bps;

  /**
   * Cap on TOTAL absolute deviation — sum of |deviationBps| across sectors.
   * This is the single number answering "how big is my active bet."
   *
   * The discipline that matters: estimation error swamps optimization gains
   * out of sample, so a wrong call must cost basis points, not the plan.
   */
  maxTotalAbsoluteDeviationBps: Bps;

  /** Cap on any single sector's deviation. */
  maxSingleSectorDeviationBps: Bps;

  /**
   * Look-through ceiling per sector as share of equity. Catches the stacking
   * problem directly — this is what stops a "small" tech tilt from becoming
   * 40%+ of equity.
   */
  maxLookThroughSectorBps: Bps;

  /**
   * Sector rotation generates short-term gains. This belongs almost entirely
   * in sheltered accounts — the tactical layer and the location layer are
   * not independent.
   */
  restrictToTreatments: ("taxable" | "tax_deferred" | "tax_free")[];

  /** Overlay may not be implemented in lots earmarked to a step-up claim. */
  respectStepUpEarmarks: true;

  activeTilts: SectorTilt[];
}

// ============================================================
// VALIDATION
// ============================================================

type TiltViolation = {
  code:
    | "stale_neutral_snapshot"
    | "exceeds_total_deviation"
    | "exceeds_single_sector"
    | "exceeds_lookthrough_ceiling"
    | "unpaired_tilt"
    | "missing_thesis"
    | "review_overdue"
    | "taxable_account_overlay"
    | "step_up_lot_used";
  severity: "hard" | "soft";
  detail: string;
};

/**
 * Pure function: (tilts, neutral, lookThrough, policy) -> violations.
 * No I/O, no state. Same discipline as the rest of the schema — beliefs are
 * data, evaluation is a function over that data.
 */
declare function validateTilts(
  policy: TiltPolicy,
  neutral: SectorNeutralSnapshot,
  lookThrough: LookThroughExposure
): TiltViolation[];

/**
 * Resolves tilts into target weights per sector ETF, given the core.
 * Paired tilts net to zero; pro_rata tilts scale the core down uniformly.
 */
declare function resolveTargets(
  policy: TiltPolicy,
  neutral: SectorNeutralSnapshot,
  equitySleeveBps: Bps
): { ticker: string; targetBps: Bps }[];

// ============================================================
// DECISION LOG — the actual output of v1
// ============================================================

/**
 * Closed tilts, scored. This is the asset manual mode produces: a record of
 * what you thought, when, and what happened.
 *
 * Score against the OFFSET, not against zero. "XLE returned 8%" is not a
 * result; "XLE beat the XLY leg by 340bps over the holding period" is. A
 * paired tilt that made money while losing to its funding leg was a bad call
 * that happened during a bull market.
 */
interface TiltOutcome {
  tilt: SectorTilt;
  closedAt: IsoDate;
  closeReason: "thesis_played_out" | "thesis_invalidated" | "review_lapsed" | "rebalance_forced";

  /** Tilt leg return less funding leg return, over the holding period. */
  relativeReturnBps: Bps;

  /** Realized short-term gain generated — the cost side of the ledger. */
  taxCostBps: Bps;

  /** Written after the fact, before seeing the number if you're honest. */
  postMortem: string;
}

// ============================================================
// SEED
// ============================================================

export const tiltPolicy: TiltPolicy = {
  enabled: true,
  mode: "manual",

  // 25/30 of the equity sleeve in broad core, ~17% available for overlay.
  coreShareOfEquityBps: 8300,

  maxTotalAbsoluteDeviationBps: 1000,
  maxSingleSectorDeviationBps: 400,

  // ~33% neutral tech + 400bps cap. Anything above this is a decision,
  // not a drift.
  maxLookThroughSectorBps: 3800,

  restrictToTreatments: ["tax_deferred", "tax_free"],
  respectStepUpEarmarks: true,

  activeTilts: [],
};

/**
 * IMPLEMENTATION NOTE — core vehicle
 *
 * SPY is a unit investment trust: it cannot reinvest dividends internally,
 * creating a small cash drag, and runs ~9bps against SPLG at ~2bps. SPLG is
 * also State Street, so family consistency is preserved. On the largest
 * position in a perpetual portfolio, 7bps compounds to real money at zero
 * cost in tracking.
 *
 * Keep SPY only where an options overlay needs its liquidity.
 */
export const CORE_VEHICLE = { primary: "SPLG", tlhPartner: "VOO", legacy: "SPY" };

export { SECTOR_ETF };
export type {
  Sector,
  SectorNeutralSnapshot,
  LookThroughExposure,
  SectorTilt,
  TiltPolicy,
  TiltViolation,
  TiltOutcome,
};
