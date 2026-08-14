/**
 * TAX & TERMINAL DISPOSITION MODULE — v1
 * ======================================
 *
 * Two halves:
 *   1. Tax law as EDITABLE DATA. Effective-dated, versioned, never hardcoded
 *      into policy. Every parameter below is expected to change.
 *   2. The terminal disposition engine — what happens to each asset at death,
 *      and how that decision propagates backward into lifetime allocation.
 *
 * THE SECOND HALF IS THE POINT. Most planning software models accumulation and
 * decumulation and then stops. But for a perpetual corpus, the disposition
 * decision is worth more than most lifetime decisions — and it changes what
 * you should hold, where, and whether you should ever sell.
 *
 * PARAMETERS CURRENT AS OF 2026-08-11. Verify before any client use.
 */

import type { Bps, Usd, IsoDate } from "./policy-schema-v2";

type FilingStatus = "single" | "mfj" | "mfs" | "hoh";

// ============================================================
// EDITABLE PARAMETER TABLE
// ============================================================

/**
 * Effective-dated, NOT year-keyed. Law changes mid-year and occasionally
 * retroactively. Stamp `version` into every saved plan so a delivered
 * projection can be reproduced under the law as it stood.
 */
interface TaxParameterSet {
  version: string;
  effectiveFrom: IsoDate;
  effectiveTo: IsoDate | null;
  jurisdiction: "us_federal";
  lastVerifiedAt: IsoDate;
  sources: string[];

  standardDeduction: Record<FilingStatus, Usd>;
  ordinaryBrackets: Record<FilingStatus, { upToUsd: Usd | null; rateBps: Bps }[]>;
  ltcgBreakpoints: Record<FilingStatus, { upToUsd: Usd | null; rateBps: Bps }[]>;

  salt: SaltParameters;
  estate: EstateParameters;

  niitThreshold: Record<FilingStatus, Usd>;
  niitRateBps: Bps;
  irmaaTiers: { magiOverUsd: Usd; monthlySurchargeUsd: Usd }[];

  rmdStartAge: number;
  bracketIndexation: "chained_cpi";
  scheduledChanges: ScheduledChange[];
}

/**
 * SALT — the parameter that flipped the mortgage-interest question.
 *
 * 2018-2024: cap was $10,000. A typical homeowner's SALT + mortgage interest
 * often fell short of the standard deduction, so they didn't itemize and the
 * interest deduction was worth ZERO at the margin — not underutilized,
 * unavailable.
 *
 * 2025-2029: cap raised to $40,000 (2025) / $40,400 (2026), stepping ~1%/yr.
 * A high-property-tax-state homeowner now hits the cap on state income and
 * property tax ALONE — which makes every dollar of mortgage interest fully
 * incremental. That is the real underutilization, and it is newly true.
 *
 * 2030: reverts to $10,000. See scheduledChanges.
 */
interface SaltParameters {
  capUsd: Record<FilingStatus, Usd>;

  /**
   * Phase-down band. Above the threshold the cap shrinks by `phaseDownRate`
   * per additional dollar of MAGI until it hits the floor.
   *
   * THIS IS A CLIFF AND IT HITS HIGH-COMP HOUSEHOLDS DIRECTLY. Inside the
   * band an extra dollar of income costs the marginal rate PLUS the lost
   * deduction. Interacts hard with Roth conversion sizing: a conversion that
   * pushes MAGI into the band can cost more than it saves.
   */
  phaseDownThresholdUsd: Record<FilingStatus, Usd>;
  phaseDownRatePerDollar: number;
  phaseDownFloorUsd: Record<FilingStatus, Usd>;

  /**
   * Top-bracket haircut: for 37%-bracket filers the effective federal benefit
   * of itemized deductions is capped below the statutory rate. Deduction value
   * is rate-dependent, not just cap-dependent.
   */
  topBracketBenefitCapBps: Bps;

  mortgageInterestAcquisitionDebtLimitUsd: Usd;
}

interface EstateParameters {
  /** Unified estate/gift/GST lifetime exemption, per person. */
  lifetimeExemptionUsd: Usd;
  /** Portability lets a surviving spouse claim the unused portion. */
  portabilityAvailable: boolean;
  topRateBps: Bps;
  annualGiftExclusionUsd: Usd;
  inflationIndexed: boolean;
}

interface ScheduledChange {
  effectiveFrom: IsoDate;
  parameter: string;
  description: string;
  /** Sunsets are facts a 30-year projection must carry, not surprises. */
  certainty: "enacted" | "scheduled_sunset" | "proposed";
}

// ============================================================
// CURRENT PARAMETERS
// ============================================================

export const TAX_2026: TaxParameterSet = {
  version: "us-fed-2026.1",
  effectiveFrom: "2026-01-01",
  effectiveTo: "2026-12-31",
  jurisdiction: "us_federal",
  lastVerifiedAt: "2026-08-11",
  sources: ["OBBBA (P.L. 119-21)", "26 U.S.C. 164(b)(7)", "IRS annual inflation adjustments"],

  // TODO: populate from IRS tables. Structure is the deliverable here.
  standardDeduction: { single: 0, mfj: 0, mfs: 0, hoh: 0 },
  ordinaryBrackets: { single: [], mfj: [], mfs: [], hoh: [] },
  ltcgBreakpoints: { single: [], mfj: [], mfs: [], hoh: [] },

  salt: {
    capUsd: { single: 40400, mfj: 40400, mfs: 20200, hoh: 40400 },
    phaseDownThresholdUsd: { single: 505000, mfj: 505000, mfs: 252500, hoh: 505000 },
    phaseDownRatePerDollar: 0.30,      // cap shrinks 30c per extra dollar of MAGI
    phaseDownFloorUsd: { single: 10000, mfj: 10000, mfs: 5000, hoh: 10000 },
    topBracketBenefitCapBps: 3500,     // ~35c/dollar for 37%-bracket filers
    mortgageInterestAcquisitionDebtLimitUsd: 750000,
  },

  estate: {
    lifetimeExemptionUsd: 15_000_000,  // $30M/couple with portability
    portabilityAvailable: true,
    topRateBps: 4000,
    annualGiftExclusionUsd: 19000,
    inflationIndexed: true,
  },

  niitThreshold: { single: 200000, mfj: 250000, mfs: 125000, hoh: 200000 },
  niitRateBps: 380,
  irmaaTiers: [],                      // TODO: populate

  rmdStartAge: 73,
  bracketIndexation: "chained_cpi",

  scheduledChanges: [
    {
      effectiveFrom: "2030-01-01",
      parameter: "salt.capUsd",
      description:
        "SALT cap reverts to $10,000 ($5,000 MFS). Closes a five-year window in which mortgage interest is fully incremental for high-tax-state itemizers. Structurally parallel to the Roth conversion window — front-load deductible activity while open.",
      certainty: "scheduled_sunset",
    },
  ],
};

// ============================================================
// SALT / MORTGAGE INTEREST EVALUATION
// ============================================================

/**
 * The framing that belongs in the philosophy statement:
 *
 * The deduction is NOT a reason to hold a mortgage. Interest is a real cost;
 * deductibility reduces it, never below zero.
 *
 * It IS a reason to sequence income and deductions around a closing window.
 * Between now and 2029 there is a dated, computable opportunity for exactly
 * the high-tax-state homeowners in scope — and it argues for KEEPING mortgage
 * debt rather than accelerating payoff during the window. That is the
 * opposite of the default advice most people receive.
 */
interface ItemizationAnalysis {
  taxYear: number;
  filingStatus: FilingStatus;
  magiUsd: Usd;

  stateIncomeTaxUsd: Usd;
  propertyTaxUsd: Usd;
  mortgageInterestUsd: Usd;
  charitableUsd: Usd;

  /** Cap after phase-down applied at this MAGI. */
  effectiveSaltCapUsd: Usd;
  saltDeductibleUsd: Usd;
  totalItemizedUsd: Usd;
  standardDeductionUsd: Usd;
  itemizes: boolean;

  /**
   * THE NUMBER THAT MATTERS. Marginal value of the next dollar of mortgage
   * interest. Zero if not itemizing. Full marginal rate if SALT is already
   * capped out — which is the common case for NJ/NY/CA homeowners in the
   * current window.
   */
  marginalValueOfMortgageInterestBps: Bps;

  /** Cost of one more dollar of MAGI inside the phase-down band. */
  inPhaseDownBand: boolean;
  effectiveMarginalRateInBandBps: Bps;

  /** Years until the window closes. Drives urgency on bunching strategies. */
  yearsUntilSaltReversion: number;
}

// ============================================================
// TERMINAL DISPOSITION — the piece usually left out
// ============================================================

/**
 * What happens to an asset at death. Every holding needs one, and the answer
 * propagates BACKWARD into lifetime allocation and location.
 */
type Disposition =
  | "hold_to_step_up"      // heirs receive stepped-up basis, retain asset
  | "step_up_then_sell"    // heirs receive step-up, liquidate at ~zero gain
  | "gift_during_life"     // removes appreciation from estate, CARRIES OVER basis
  | "charitable_at_death"  // no income or estate tax
  | "consume";             // spent during lifetime

/**
 * ASSET TREATMENT AT DEATH — and the ordering is NOT the same as lifetime
 * asset location. This is the piece most plans omit.
 *
 *   TAXABLE APPRECIATED  -> full step-up. Embedded gain erased. BEST asset to
 *                           leave to individual heirs.
 *   ROTH                 -> already tax-free; 10-year distribution rule for
 *                           most non-spouse heirs but no tax. Excellent.
 *   TAX-DEFERRED (IRA)   -> NO step-up. Income in respect of a decedent: heirs
 *                           pay ordinary income on every dollar, compressed
 *                           into 10 years — often during their peak earning
 *                           years. WORST asset to leave to individual heirs.
 *                           BEST asset to leave to charity (charity pays none).
 *   REAL PROPERTY        -> step-up erases capital gain AND depreciation
 *                           recapture. If heirs HOLD, they begin a FRESH
 *                           depreciation schedule on the stepped-up basis.
 *                           Structurally the best long-hold asset in the system.
 *
 * IMPLICATION: the charitable beneficiary should be the IRA, and the heirs
 * should get the taxable account. Reversing that is a common and expensive
 * default.
 */
interface AssetDispositionProfile {
  assetClass:
    | "taxable_appreciated"
    | "taxable_high_basis"
    | "tax_deferred"
    | "roth"
    | "real_property"
    | "illiquid_alt"
    | "primary_residence";

  receivesStepUp: boolean;
  erasesDepreciationRecapture: boolean;
  heirsGetFreshDepreciationSchedule: boolean;
  isIRD: boolean;                       // no step-up, ordinary income to heirs
  subjectToTenYearRule: boolean;

  /** Preference order for leaving this asset. 1 = best. */
  heirPreferenceRank: number;
  charityPreferenceRank: number;
}

/**
 * THE CENTRAL TRADEOFF: basis vs estate tax.
 *
 * Below the exemption ($15M/person, $30M/couple with portability):
 *   NEVER gift appreciated assets. Hold everything for step-up. There is no
 *   estate tax to avoid, so giving up basis step-up is a pure loss.
 *
 * Above the exemption:
 *   Estate tax tops out at 40% — higher than combined federal capital gains.
 *   Gifting removes future appreciation from the estate, but the donee takes
 *   CARRYOVER basis.
 *   Therefore: GIFT HIGH-BASIS ASSETS, HOLD LOW-BASIS FOR STEP-UP.
 *
 * That asset-selection rule is computable, is worth real money, and is
 * routinely gotten backwards.
 */
interface DispositionDecision {
  lotId: string;
  currentDisposition: Disposition;

  estimatedEstateValueUsd: Usd;
  exemptionAvailableUsd: Usd;
  aboveExemption: boolean;

  unrealizedGainUsd: Usd;
  basisRatioBps: Bps;                   // basis / FMV. High ratio -> gift candidate.

  /** Tax if held to death and stepped up. */
  taxIfHeldUsd: Usd;
  /** Tax if gifted now (carryover basis, eventual sale by donee). */
  taxIfGiftedUsd: Usd;
  /** Estate tax saved by removing the asset and its appreciation. */
  estateTaxAvoidedUsd: Usd;

  recommendation: Disposition;
  rationale: string;
}

// ============================================================
// PRACTICAL HEIR CONSTRAINTS
// ============================================================

/**
 * Tax-optimal is not always administrable. These break plans in practice and
 * belong in the model, not in a footnote.
 */
interface HeirFeasibility {
  /**
   * Illiquid alts pass to heirs WITH their obligations. An heir inheriting a
   * PE interest inherits the unfunded capital call schedule and may lack the
   * liquidity or the accreditation to meet it. Default is a forced secondary
   * sale at a discount — which destroys the step-up advantage.
   */
  unfundedCommitmentsUsd: Usd;
  heirsAreAccredited: boolean;

  /**
   * Multiple heirs on one indivisible property is the classic failure. Absent
   * a governing entity, any co-owner can force a partition sale — converting
   * a hold_to_step_up plan into an involuntary liquidation.
   */
  indivisibleAssetHeirCount: number;
  governingEntityExists: boolean;       // LLC/trust with buy-sell provisions

  /** Illiquid estate + estate tax due in 9 months = forced sale. */
  estimatedEstateTaxDueUsd: Usd;
  liquidAssetsAvailableUsd: Usd;
  liquidityShortfallUsd: Usd;
}

// ============================================================
// CONSTRAINTS
// ============================================================

export const DISPOSITION_CONSTRAINTS = [
  {
    id: "ird_to_charity",
    severity: "soft" as const,
    description:
      "Charitable bequest funded from taxable assets while tax-deferred assets pass to individual heirs. This is backwards: charity pays no income tax on IRD, heirs pay ordinary rates over 10 years.",
  },
  {
    id: "gift_low_basis",
    severity: "soft" as const,
    description:
      "Low-basis asset selected for lifetime gifting while high-basis assets are held. Below the exemption, gifting appreciated assets forfeits step-up for no benefit; above it, gift the HIGH-basis lots.",
  },
  {
    id: "step_up_sale",
    severity: "hard" as const,
    description:
      "Taxable sale of a lot marked hold_to_step_up. Over a multi-decade horizon this forfeits more than any tilt will produce.",
  },
  {
    id: "estate_liquidity",
    severity: "hard" as const,
    description:
      "Projected estate tax exceeds liquid assets. Estate tax is due roughly nine months after death; an illiquid estate forces a discounted sale.",
  },
  {
    id: "orphaned_commitments",
    severity: "hard" as const,
    description:
      "Unfunded capital commitments projected to pass to heirs lacking liquidity or accreditation to meet them.",
  },
  {
    id: "partition_risk",
    severity: "soft" as const,
    description:
      "Indivisible asset passing to multiple heirs without a governing entity. Any co-owner can force a partition sale.",
  },
];

declare function analyzeItemization(input: Partial<ItemizationAnalysis>, params: TaxParameterSet): ItemizationAnalysis;
declare function recommendDisposition(lot: unknown, params: TaxParameterSet, feasibility: HeirFeasibility): DispositionDecision;

export type {
  TaxParameterSet,
  SaltParameters,
  EstateParameters,
  ScheduledChange,
  ItemizationAnalysis,
  Disposition,
  AssetDispositionProfile,
  DispositionDecision,
  HeirFeasibility,
};
