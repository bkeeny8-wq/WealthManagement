# Wealth Management — Policy Layer

A declarative encoding of an advisory philosophy. Stack-agnostic TypeScript
types plus seeded policy instances. No runtime, no UI, no dependencies.

> **The application lives in [`APP.md`](APP.md).** A native SwiftUI app
> (`WealthPolicyDesk.xcodeproj`) ports this policy layer to Swift, implements the
> engine these types only `declare`, and drives it from an editable sample
> household so every belief below becomes a number you can see and change.

**Design invariant:** policy states *beliefs and preferences*. The tax module
states *numbers*. Evaluation is a pure function of `(positions, policy)`.
Beliefs should outlive both Congress and the business cycle.

---

## Why this exists before any app

Frameworks rot. Auth patterns rot. The policy layer doesn't. This is the part
that can't be outsourced, and it doubles as IPS template language and ADV
Item 8 source material.

---

## The philosophy in eight lines

1. **The corpus is perpetual.** Claims against it are not — so allocation is an
   *output* of funding those claims, never an input.
2. **Bonds are a conditional diversifier.** Positively correlated to equities
   under inflation shocks, negatively under growth shocks. The regime isn't
   knowable in advance, so fixed income is sized to liquidity and liability
   rather than to a share.
3. **Alternatives are bought for a function, not a label.** Convexity that
   works in the shock bonds fail; shaped payoffs with defined outcomes;
   illiquidity premium held on its own honest terms — never under the
   correlation argument.
4. **Total balance sheet or nothing.** Home equity, human capital, deferred
   comp, and debt are all positions. Net fixed income is FI assets *minus*
   debt.
5. **Disposition at death inverts lifetime asset location.** The charity should
   get the IRA; the heirs should get the brokerage account.
6. **Goal flexibility is a stronger risk lever than allocation.** Deferring a
   goal beats taking more risk.
7. **Tactical is small, logged, and scored against its funding leg.** It is the
   weakest-evidence component in the system and is budgeted accordingly.
8. **Most of the durable value is tax and structure, not market calls.**

---

## Module map

| File | Covers |
|---|---|
| `policy-schema-v2.ts` | Goal claims, sleeves, alt function budgets, eligibility tiers, ladder, ratchet glide, rebalance, external assets |
| `household-module.ts` | Human capital + beta, deferred comp, two-earner correlation, Social Security, tiered/flexible goals, required return |
| `exposure-matrix-module.ts` | Country × sector matrix, geography tree, generalized tilts, currency stance, aligned ETF lineup |
| `layer-separation-module.ts` | Strategic vs tactical lots, dual rebalance regimes, holding periods, round-trip cost gate, attribution |
| `tax-disposition-module.ts` | Editable federal tax parameters, SALT window, estate, step-up / IRD, basis-vs-estate-tax fork |
| `fixed-income-liability-module.ts` | FI vehicles, instrument location rules, duration from liabilities, full liability side, deferred tax, balance sheet view |
| `planning-surface-module.ts` | Transition management, risk tolerance vs capacity, insurance & LTC, equity comp, charitable, 529→Roth |
| `sector-tilt-module.ts` | Superseded for tilts; still canonical for `Sector` and `SECTOR_ETF` |
| `_archive-policy-schema-v1.ts` | Historical. Household-allocation model, replaced by goal claims. Kept for diff. |

---

## Open items

**Unspecified belief**
- Capital market assumptions. The last unarticulated belief. Historical
  bootstrap vs building-block vs regime-switching, who owns the numbers, update
  cadence. Note: required return is computed *without* CMAs — report it first,
  then let CMAs answer how plausible it is.

**Specified but unbuilt**
- Spending-claim policy instance (ladder + glide are defined but never
  exercised — this is what a decumulation client would actually see)
- All `declare`d functions. They need a concrete holdings data shape first:
  `validateTilts`, `resolveTargets`, `validateMatrix`, `analyzeItemization`,
  `recommendDisposition`, `partitionByLayer`, `evaluateStrategic`,
  `evaluateTactical`, `computeRoundTripCost`

**Numbers that are placeholders wearing plausible values**
- `correctionFractionBps: 6000` — most consequential unbacked number; wants a backtest
- `volatilityOverrideBps` on PE/private credit — must be defensible from unsmoothed data
- `equityEquivalenceFactor` per note structure
- Eligibility tier thresholds above the derived ~$350k floor
- All `TAX_2026` bracket tables (structure present, values TODO)

**Verify before client use**
- QSBS rules (modified recently)
- QCD annual limit (indexed)
- State-level 529→Roth recapture treatment
- Everything in `TAX_2026` — `lastVerifiedAt` is stamped for a reason

**Out of scope in v1**
- State tax. Federal only. Materially shifts muni crossover and Roth
  conversion breakeven; strategy *ranking* mostly survives, magnitude doesn't.

---

## Compliance note

Nothing here constitutes investment advice or a recommendation. Delivering
personalized advice for compensation requires registration. Before this
touches a prospect: securities counsel, and check any employer's outside
business activity policy first.
