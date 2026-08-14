/**
 * INVESTMENT POLICY SCHEMA
 * ------------------------
 * A declarative encoding of advisory philosophy.
 *
 * Design principle: every downstream computation — drift, rebalance proposals,
 * policy violations, asset-location suggestions — is a PURE FUNCTION of
 * (positions, policy). Beliefs live here and nowhere else. If you change your
 * mind about small-cap or about how much note exposure a household can carry,
 * you edit one object, not twelve files.
 *
 * This is stack-agnostic on purpose. It survives whatever framework you
 * eventually build on.
 */

// ============================================================
// PRIMITIVES
// ============================================================

/** Basis points. 100 = 1%. Used everywhere to avoid float drift on percentages. */
type Bps = number;

type AccountTaxTreatment =
  | "taxable"
  | "tax_deferred"   // Traditional IRA, 401(k), rollover IRA
  | "tax_free";      // Roth IRA, Roth 401(k), HSA

/**
 * Tax efficiency of an asset class, used by the asset-location engine.
 * Ranked, not boolean — location is a sorting problem, not a binary.
 */
type TaxEfficiency = "high" | "moderate" | "low";

// ============================================================
// SLEEVES — the vocabulary of the portfolio
// ============================================================

/**
 * A sleeve is a role in the portfolio, not a ticker. Tickers are
 * implementation; sleeves are belief. This indirection is what lets you
 * swap VOO for SPLG without touching policy.
 */
interface Sleeve {
  id: string;
  label: string;

  /** Where this sits in the core/satellite structure. */
  tier: "core" | "satellite" | "diversifier" | "liquidity";

  targetBps: Bps;

  /**
   * Rebalance band. Drift beyond this triggers a proposal.
   * Wider bands = fewer trades = less tax friction. Narrower bands = tighter
   * tracking. This number IS a belief about the cost of tracking error
   * relative to the cost of turnover.
   */
  bandBps: Bps;

  /** Hard ceiling regardless of drift. Null = no ceiling beyond the band. */
  maxBps: Bps | null;

  taxEfficiency: TaxEfficiency;

  /** Preferred account types, most-preferred first. Drives asset location. */
  locationPreference: AccountTaxTreatment[];

  /** Acceptable implementations. First is default; others are TLH partners. */
  instruments: {
    ticker: string;
    role: "primary" | "tlh_partner";
    /** Substantially-identical risk flag for wash-sale reasoning. */
    correlationToPrimary?: number;
  }[];

  /**
   * Free text, but write it. This is the sentence you say to a client when
   * they ask "why do I own this." If you can't write it, cut the sleeve.
   */
  rationale: string;
}

// ============================================================
// STRUCTURED NOTES — the differentiated sleeve
// ============================================================

type NoteStructure =
  | "buffered"
  | "barrier"          // contingent downside, cliff risk
  | "absolute_return"
  | "income_autocall"
  | "participation";

interface StructuredNotePolicy {
  /** Ceiling across the whole household. The single most important number here. */
  maxHouseholdBps: Bps;

  /** Ceiling per individual note. Prevents one bad print from mattering too much. */
  maxSinglePositionBps: Bps;

  /** Ceiling per issuer. This is credit risk, and it is the risk people forget. */
  maxIssuerBps: Bps;

  /** Minimum distinct issuers before the sleeve may exceed this size. */
  issuerDiversificationFloor: { aboveBps: Bps; minIssuers: number };

  allowedStructures: NoteStructure[];

  /** Structures you will not sell, and why. Worth being explicit. */
  prohibitedStructures: { structure: NoteStructure; reason: string }[];

  /**
   * How note exposure counts toward the equity risk budget.
   * A 10% buffered note on SPX is not 100% equity and is not 0% equity.
   * This factor is a modeling belief and should be defensible.
   */
  equityEquivalenceFactor: Record<NoteStructure, number>;

  /** Alert when spot approaches the barrier/buffer boundary. */
  barrierProximityAlertBps: Bps;

  /** Maturity ladder: avoid reinvestment-cliff concentration. */
  maxMaturingInAnyQuarterBps: Bps;

  minCreditRating: string;
}

// ============================================================
// REBALANCING
// ============================================================

interface RebalancePolicy {
  /**
   * Band-based is generally superior to calendar for taxable accounts.
   * Calendar is a fallback for accounts where you can't monitor continuously.
   */
  trigger: "band" | "calendar" | "band_with_calendar_floor";

  calendarFloor?: "quarterly" | "semiannual" | "annual";

  /** Don't propose trades smaller than this — friction exceeds benefit. */
  minTradeUsd: number;

  /**
   * Prefer to correct drift with new contributions before selling.
   * Cheapest rebalancing is the kind that doesn't realize gains.
   */
  preferCashFlowRebalancing: boolean;

  /** Annual realized-gain budget in taxable accounts, as % of taxable AUM. */
  realizedGainBudgetBps: Bps | null;

  washSaleWindowDays: number;
}

// ============================================================
// CONSTRAINTS — the "never do this" layer
// ============================================================

interface Constraint {
  id: string;
  /** "hard" blocks the proposal. "soft" flags it for review. */
  severity: "hard" | "soft";
  description: string;
}

// ============================================================
// THE POLICY OBJECT
// ============================================================

interface InvestmentPolicy {
  id: string;
  version: string;
  effectiveDate: string;

  /** Risk tier this policy serves. Client-facing variants derive from this. */
  riskTier: "conservative" | "moderate" | "growth" | "aggressive";

  /** Years. Drives equity share and note maturity tolerance. */
  horizonYears: number;

  sleeves: Sleeve[];
  notes: StructuredNotePolicy;
  rebalance: RebalancePolicy;
  constraints: Constraint[];

  /**
   * The philosophy in prose. Not decoration — this is the text that becomes
   * IPS language and client explanation. Keep it honest about tradeoffs
   * you're deliberately accepting.
   */
  statement: string;
}

// ============================================================
// SEED INSTANCE — long-horizon growth
// Derived from your current rollover allocation. Bands, ceilings, and the
// entire notes block are placeholders: those are YOUR numbers to set.
// ============================================================

export const growthPolicy: InvestmentPolicy = {
  id: "growth-30y",
  version: "0.1.0",
  effectiveDate: "2026-08-11",
  riskTier: "growth",
  horizonYears: 30,

  sleeves: [
    {
      id: "us_large_core",
      label: "US Large Cap Core",
      tier: "core",
      targetBps: 3000,
      bandBps: 500,
      maxBps: null,
      taxEfficiency: "high",
      locationPreference: ["taxable", "tax_free", "tax_deferred"],
      instruments: [
        { ticker: "VOO", role: "primary" },
        { ticker: "SPLG", role: "tlh_partner", correlationToPrimary: 0.999 },
      ],
      rationale:
        "Beta anchor. Lowest-cost access to the return stream everything else is measured against.",
    },
    {
      id: "us_large_growth",
      label: "US Large Cap Growth Tilt",
      tier: "satellite",
      targetBps: 1300,
      bandBps: 300,
      maxBps: 1800,
      taxEfficiency: "high",
      locationPreference: ["tax_free", "taxable", "tax_deferred"],
      instruments: [{ ticker: "QQQM", role: "primary" }],
      rationale:
        "Deliberate growth/tech overweight. Stacks with the tech sector sleeve — see the concentration constraint.",
    },
    {
      id: "us_tech_sector",
      label: "US Technology Sector",
      tier: "satellite",
      targetBps: 1000,
      bandBps: 250,
      maxBps: 1400,
      taxEfficiency: "high",
      locationPreference: ["tax_free", "taxable", "tax_deferred"],
      instruments: [{ ticker: "VGT", role: "primary" }],
      rationale:
        "Explicit sector conviction, sized so total tech exposure is intentional rather than accidental.",
    },
    {
      id: "us_mid",
      label: "US Mid Cap",
      tier: "core",
      targetBps: 800,
      bandBps: 200,
      maxBps: null,
      taxEfficiency: "high",
      locationPreference: ["taxable", "tax_deferred", "tax_free"],
      instruments: [{ ticker: "VO", role: "primary" }],
      rationale: "Completion exposure below large-cap, cheaply.",
    },
    {
      id: "us_small",
      label: "US Small Cap",
      tier: "satellite",
      targetBps: 800,
      bandBps: 200,
      maxBps: null,
      taxEfficiency: "moderate",
      locationPreference: ["tax_free", "tax_deferred", "taxable"],
      instruments: [{ ticker: "VB", role: "primary" }],
      rationale: "Size premium, held on a horizon long enough to survive its drawdowns.",
    },
    {
      id: "intl_developed",
      label: "International Developed",
      tier: "core",
      targetBps: 1000,
      bandBps: 250,
      maxBps: null,
      taxEfficiency: "moderate",
      locationPreference: ["taxable", "tax_deferred", "tax_free"],
      instruments: [{ ticker: "VEA", role: "primary" }],
      rationale:
        "Held in taxable to capture the foreign tax credit — a location decision, not just an allocation one.",
    },
    {
      id: "emerging",
      label: "Emerging Markets",
      tier: "satellite",
      targetBps: 800,
      bandBps: 200,
      maxBps: null,
      taxEfficiency: "moderate",
      locationPreference: ["tax_deferred", "tax_free", "taxable"],
      instruments: [{ ticker: "VWO", role: "primary" }],
      rationale: "Dispersion and valuation exposure not available in developed markets.",
    },
    {
      id: "real_assets",
      label: "Real Estate / Real Assets",
      tier: "diversifier",
      targetBps: 600,
      bandBps: 150,
      maxBps: null,
      taxEfficiency: "low",
      locationPreference: ["tax_deferred", "tax_free"],
      instruments: [{ ticker: "VNQ", role: "primary" }],
      rationale:
        "Non-qualified dividend income — belongs in sheltered accounts. Classic asset-location case.",
    },
    {
      id: "alt_sleeve",
      label: "Alternatives / Thematic",
      tier: "diversifier",
      targetBps: 700,
      bandBps: 200,
      maxBps: 1000,
      taxEfficiency: "moderate",
      locationPreference: ["tax_deferred", "tax_free"],
      instruments: [
        { ticker: "CAIE", role: "primary" },
        { ticker: "SBAR", role: "primary" },
      ],
      rationale: "Return streams with lower correlation to the equity core.",
    },
  ],

  notes: {
    maxHouseholdBps: 1500,
    maxSinglePositionBps: 300,
    maxIssuerBps: 500,
    issuerDiversificationFloor: { aboveBps: 1000, minIssuers: 3 },
    allowedStructures: ["buffered", "absolute_return", "participation"],
    prohibitedStructures: [
      {
        structure: "barrier",
        reason:
          "Cliff risk at the barrier is poorly understood by clients and poorly compensated at current levels. Placeholder — your call.",
      },
    ],
    equityEquivalenceFactor: {
      buffered: 0.85,
      barrier: 0.95,
      absolute_return: 0.6,
      income_autocall: 0.75,
      participation: 1.0,
    },
    barrierProximityAlertBps: 1000,
    maxMaturingInAnyQuarterBps: 500,
    minCreditRating: "A-",
  },

  rebalance: {
    trigger: "band_with_calendar_floor",
    calendarFloor: "annual",
    minTradeUsd: 500,
    preferCashFlowRebalancing: true,
    realizedGainBudgetBps: 100,
    washSaleWindowDays: 31,
  },

  constraints: [
    {
      id: "total_tech_ceiling",
      severity: "soft",
      description:
        "Combined look-through technology exposure across all sleeves flags above 35%. Deliberate concentration, but it should be a decision each time, not a drift.",
    },
    {
      id: "single_issuer_credit",
      severity: "hard",
      description:
        "No single note issuer above 5% of household, inclusive of any other credit exposure to that name.",
    },
    {
      id: "no_notes_short_horizon",
      severity: "hard",
      description:
        "No structured notes with maturity beyond the stated liquidity horizon of the account.",
    },
    {
      id: "concentrated_stock",
      severity: "soft",
      description:
        "Any single equity position above 10% of household triggers a diversification review.",
    },
  ],

  statement: `Core beta is the engine; satellites express conviction and must justify their
cost. Concentration is acceptable when chosen and sized, not when inherited from drift.
Structured notes are a tool for shaping a known payoff, not for reaching yield — they are
capped, issuer-diversified, and counted against the equity risk budget rather than treated
as a separate bucket. Taxes are a real and controllable drag: location precedes selection,
and the cheapest rebalance is the one funded by new cash. TODO: rewrite this in your own
words. The version you'd actually say out loud is the one worth keeping.`,
};
