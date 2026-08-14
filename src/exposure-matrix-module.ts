/**
 * EXPOSURE MATRIX & GENERALIZED TILT MODULE — v1
 * ==============================================
 *
 * Supersedes the single-axis design in sector-tilt-module.ts. Same manual
 * mode, same decision logging, same zero-sum discipline — but tilts now run
 * on multiple axes and, critically, are evaluated JOINTLY.
 *
 * WHY THIS REPLACES THE VECTOR MODEL:
 * A country tilt is also a sector tilt whether you intended it or not. Taiwan
 * is heavily semiconductor. Germany is autos and industrials. Brazil is
 * materials and energy. Switzerland is pharma and staples.
 *
 * Hold a technology overweight AND a Taiwan overweight and your true
 * semiconductor concentration exceeds what either constraint sees — both read
 * compliant individually. Per-axis vectors cannot catch this. A COUNTRY x
 * SECTOR MATRIX can, with constraints on the margins AND on the cells.
 *
 * SECOND STRUCTURAL DIFFERENCE: geography NESTS. IEFA contains Europe contains
 * Germany. Overweighting Germany while holding IEFA stacks the same way XLK
 * stacks on IVV, but three levels deep. Requires a tree, not a flat enum.
 */

import type { Bps, IsoDate } from "./policy-schema-v2";
import type { Sector } from "./sector-tilt-module";

// ============================================================
// INDEX FAMILY ALIGNMENT
// ============================================================

/**
 * The reconciliation bug this prevents:
 *
 * FTSE classifies South Korea as DEVELOPED. MSCI classifies it EMERGING.
 * So VEA (FTSE) contains Korea and VWO (FTSE) does not — but EWY is an MSCI
 * country fund. Mixing families means Korea sits in the developed core and
 * the EM overlay simultaneously, and the matrix cannot reconcile. Greece,
 * Poland, and the Gulf states carry similar seams.
 *
 * Resolution: ONE FAMILY PER SIDE.
 *   Domestic    -> S&P.  Select Sector SPDRs are the S&P 500 sliced into 11
 *                  and sum exactly to the parent. They decompose cleanly
 *                  against an S&P 500 core and only against one.
 *   International -> MSCI. iShares core + iShares country funds.
 *
 * The US/non-US boundary between families is unambiguous, so no double count.
 */
export const LINEUP = {
  domestic: {
    family: "sp",
    core: { ticker: "IVV", index: "S&P 500", feeBps: 3 },
    midCap: { ticker: "IJH", index: "S&P MidCap 400", feeBps: 5 },
    smallCap: { ticker: "IJR", index: "S&P SmallCap 600", feeBps: 6 },
    // IVV + IJH + IJR = S&P 1500. No overlap, no gaps.
    sectorOverlay: "Select Sector SPDR (XL*)",
    tlhPartners: { IVV: "VOO", IJH: "VO", IJR: "VB" },
  },
  international: {
    family: "msci",
    developedCore: { ticker: "IEFA", index: "MSCI EAFE IMI", feeBps: 7 },
    emergingCore: { ticker: "IEMG", index: "MSCI EM IMI", feeBps: 9 },
    countryOverlay: "iShares MSCI single-country (EW*)",
  },
} as const;

// ============================================================
// GEOGRAPHY TREE
// ============================================================

type GeoLevel = "global" | "bloc" | "region" | "country";

/**
 * Nested taxonomy. Neutral weights must resolve at EVERY level — a Germany
 * tilt is simultaneously a Europe tilt and a developed-markets tilt, and all
 * three need evaluating.
 */
interface GeoNode {
  id: string;
  label: string;
  level: GeoLevel;
  parentId: string | null;
  /** ISO country code at leaf level. */
  isoCode?: string;
}

export const GEO_TREE: GeoNode[] = [
  { id: "world", label: "World", level: "global", parentId: null },
  { id: "us", label: "United States", level: "bloc", parentId: "world" },
  { id: "dev_exus", label: "Developed ex-US", level: "bloc", parentId: "world" },
  { id: "em", label: "Emerging Markets", level: "bloc", parentId: "world" },

  { id: "europe_dev", label: "Developed Europe", level: "region", parentId: "dev_exus" },
  { id: "asia_dev", label: "Developed Asia-Pacific", level: "region", parentId: "dev_exus" },
  { id: "americas_dev", label: "Developed Americas ex-US", level: "region", parentId: "dev_exus" },

  { id: "asia_em", label: "Emerging Asia", level: "region", parentId: "em" },
  { id: "latam_em", label: "Emerging Latin America", level: "region", parentId: "em" },
  { id: "emea_em", label: "Emerging EMEA", level: "region", parentId: "em" },

  { id: "de", label: "Germany", level: "country", parentId: "europe_dev", isoCode: "DE" },
  { id: "fr", label: "France", level: "country", parentId: "europe_dev", isoCode: "FR" },
  { id: "gb", label: "United Kingdom", level: "country", parentId: "europe_dev", isoCode: "GB" },
  { id: "ch", label: "Switzerland", level: "country", parentId: "europe_dev", isoCode: "CH" },
  { id: "jp", label: "Japan", level: "country", parentId: "asia_dev", isoCode: "JP" },
  { id: "tw", label: "Taiwan", level: "country", parentId: "asia_em", isoCode: "TW" },
  { id: "kr", label: "South Korea", level: "country", parentId: "asia_em", isoCode: "KR" },
  { id: "in", label: "India", level: "country", parentId: "asia_em", isoCode: "IN" },
  { id: "br", label: "Brazil", level: "country", parentId: "latam_em", isoCode: "BR" },
  { id: "mx", label: "Mexico", level: "country", parentId: "latam_em", isoCode: "MX" },
];

// ============================================================
// THE MATRIX
// ============================================================

/**
 * Full decomposition. Cells are share of total EQUITY in bps.
 *
 * Marginal sums give per-axis exposure; cells give the joint exposure that
 * per-axis vectors miss entirely.
 *
 * All values FETCHED, never stored as policy. Underlying concentrations shift
 * continuously — a single name can be a fifth to a quarter of a country fund
 * and that ratio moves. Constraints evaluate against live decomposition.
 */
interface ExposureMatrix {
  asOf: IsoDate;
  source: string;
  maxAgeDays: number;

  /** cells[geoId][sector] = bps of total equity. */
  cells: Record<string, Partial<Record<Sector, Bps>>>;

  /** Marginal sums, precomputed for constraint evaluation. */
  byGeoBps: Record<string, Bps>;
  bySectorBps: Record<Sector, Bps>;

  contributions: {
    ticker: string;
    weightInEquityBps: Bps;
    cells: Record<string, Partial<Record<Sector, Bps>>>;
  }[];
}

// ============================================================
// CURRENCY
// ============================================================

/**
 * A separate decision hiding inside every geographic one.
 *
 * EWJ is Japan equity AND a yen position. DXJ is Japan equity alone. These
 * have diverged by double digits within a single year. If the thesis is
 * "Japanese corporate governance reform," the yen leg is uncompensated noise
 * you did not intend to take.
 *
 * Make it explicit on the tilt, never an accident of ticker selection.
 */
type CurrencyStance = "unhedged" | "hedged" | "no_view";

// ============================================================
// GENERALIZED TILT
// ============================================================

type TiltAxis = "sector" | "geo" | "style";

/**
 * Same discipline as the sector-only version: signed deviation from live
 * neutral, mandatory thesis, forced review date, scored against the funding
 * leg rather than against zero.
 */
interface Tilt {
  id: string;
  axis: TiltAxis;

  /** Sector id, GeoNode id, or style id depending on axis. */
  nodeId: string;

  deviationBps: Bps;

  funding: "pro_rata" | "paired";
  offsetNodeId?: string;

  currency: CurrencyStance;

  thesis: string;
  openedAt: IsoDate;
  reviewBy: IsoDate;
  exitCondition?: string;

  /**
   * Cross-axis exposure this tilt knowingly creates. Forces the Taiwan =
   * semiconductor realization at entry rather than at the post-mortem.
   */
  acknowledgedCrossExposure?: { geoId: string; sector: Sector; estimatedBps: Bps }[];
}

// ============================================================
// AXIS-SPECIFIC RULES
// ============================================================

/**
 * TAX CONFLICT, RESOLVED PER AXIS.
 *
 * Sector rotation generates short-term gains -> shelter it.
 * International holdings earn the foreign tax credit ONLY in taxable accounts
 * -> the credit is forfeited entirely in an IRA.
 *
 * These pull opposite directions, so the restriction cannot be global.
 *
 * Resolution: international CORE stays taxable (capture the credit, buy and
 * hold, minimal turnover). Country OVERLAY goes sheltered (turnover-driven,
 * and the forfeited credit on a small tactical sleeve is smaller than the
 * short-term gain cost). Reassess if the overlay ever exceeds the core.
 */
interface AxisRules {
  axis: TiltAxis;
  restrictToTreatments: ("taxable" | "tax_deferred" | "tax_free")[];

  /**
   * Minimum expected relative return to justify the tilt, net of costs.
   *
   * Single-country funds run 50-65bps vs single digits for core, so a country
   * tilt must clear roughly TEN TIMES the hurdle of a sector rotation. That
   * argues for few, large, high-conviction country positions rather than a
   * broad country program.
   */
  minExpectedRelativeReturnBps: Bps;

  maxSingleDeviationBps: Bps;
  maxTotalAbsoluteDeviationBps: Bps;
}

export const AXIS_RULES: AxisRules[] = [
  {
    axis: "sector",
    restrictToTreatments: ["tax_deferred", "tax_free"],
    minExpectedRelativeReturnBps: 100,
    maxSingleDeviationBps: 400,
    maxTotalAbsoluteDeviationBps: 1000,
  },
  {
    axis: "geo",
    restrictToTreatments: ["tax_deferred", "tax_free"],
    minExpectedRelativeReturnBps: 300,   // ~10x the sector hurdle
    maxSingleDeviationBps: 300,
    maxTotalAbsoluteDeviationBps: 800,
  },
];

// ============================================================
// LIQUIDITY / PRICING FLAGS
// ============================================================

/**
 * When Tokyo is closed, EWJ's intraday price is a FORECAST of a stale NAV,
 * not a measurement — persistent premiums and discounts follow.
 *
 * Matters twice: for execution, and for deciding whether a band breach is
 * real or a pricing artifact. Do not trade a breach on a stale-NAV fund
 * without checking against the premium/discount.
 */
interface FundPricingFlags {
  ticker: string;
  navStalenessRisk: boolean;      // underlying market doesn't overlap US hours
  typicalPremiumDiscountBps: Bps;
  feeBps: Bps;
}

// ============================================================
// CONSTRAINTS
// ============================================================

interface MatrixConstraint {
  id: string;
  severity: "hard" | "soft";
  /** "cell" catches joint exposure; margins catch single-axis. */
  scope: "cell" | "geo_margin" | "sector_margin" | "total";
  limitBps: Bps;
  description: string;
}

export const MATRIX_CONSTRAINTS: MatrixConstraint[] = [
  {
    id: "cell_concentration",
    severity: "hard",
    scope: "cell",
    limitBps: 800,
    description:
      "No single country x sector cell above 8% of equity. THE constraint per-axis vectors miss: a tech tilt plus a Taiwan tilt can be individually compliant and jointly a large undeclared semiconductor bet.",
  },
  {
    id: "sector_lookthrough",
    severity: "hard",
    scope: "sector_margin",
    limitBps: 3800,
    description:
      "Look-through sector exposure ceiling, inclusive of sector contributed by country funds.",
  },
  {
    id: "single_country",
    severity: "hard",
    scope: "geo_margin",
    limitBps: 700,
    description: "No single non-US country above 7% of equity, inclusive of core contribution.",
  },
  {
    id: "em_ceiling",
    severity: "soft",
    scope: "geo_margin",
    limitBps: 1500,
    description: "Aggregate emerging exposure, core plus overlay.",
  },
  {
    id: "stale_matrix",
    severity: "hard",
    scope: "total",
    limitBps: 0,
    description: "Refuse to evaluate tilts against a decomposition older than maxAgeDays.",
  },
];

/**
 * REAL ESTATE — DOUBLE-COUNT RESOLVED.
 *
 * In v2 real estate appeared three times: as a GICS sector, as its own sleeve
 * (VNQ), and as displaced-by-home-equity in the external asset logic.
 *
 * Resolution: real estate exists in exactly ONE place — the matrix, as GICS
 * sector `real_estate`. The dedicated sleeve becomes an IMPLEMENTATION of a
 * real-estate overweight, not a parallel allocation. Home equity reduces the
 * target on that sector, not on a separate sleeve. One number, one place.
 */
export const REAL_ESTATE_RESOLUTION = {
  canonicalLocation: "matrix_sector_real_estate",
  sleeveIsImplementationOnly: true,
  homeEquityReducesSectorTarget: true,
} as const;

// ============================================================
// EVALUATION
// ============================================================

/** Pure function over data, consistent with the rest of the schema. */
declare function validateMatrix(
  tilts: Tilt[],
  matrix: ExposureMatrix,
  rules: AxisRules[],
  constraints: MatrixConstraint[]
): { code: string; severity: "hard" | "soft"; detail: string }[];

declare function resolveTargets(
  tilts: Tilt[],
  matrix: ExposureMatrix,
  equitySleeveBps: Bps
): { ticker: string; targetBps: Bps }[];

export type {
  GeoNode,
  ExposureMatrix,
  Tilt,
  TiltAxis,
  CurrencyStance,
  AxisRules,
  FundPricingFlags,
  MatrixConstraint,
};
