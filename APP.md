# Wealth Policy — the application

A native **SwiftUI (iPad)** app built on the declarative policy layer in `src/`.
It ports the TypeScript domain model to Swift, **implements the engine** the
policy layer only `declare`d, and wraps it in a **self-serve practice-onboarding
tool**: anyone works through an intake questionnaire and lands on a live desk
that turns every belief in the policy layer into a number they can see and change.

The intended arc: **intake → mastery (it teaches while it captures) → CRM (the
intake record is exportable) → web someday** (the portable core is the TS policy
layer; the Swift app is one native face on the same engine). It is designed to
help lay the foundations of an advisory practice.

Same build conventions as the sibling apps in `~/Projects` (StructuredNotesDesk):
a **framework + Example host app** pair, iPad-only (iOS 17+, Swift 5), and a
`generate_xcodeproj.py` that writes the `.pbxproj`.

## Open, build, run

Open **`WealthPolicyDesk.xcodeproj`** → scheme **WealthPolicyDeskExample** → run
on any iPad simulator or device (iOS 17+). The app is **iPad-only**
(`TARGETED_DEVICE_FAMILY = 2`), both orientations.

| Target | Type |
|---|---|
| `WealthPolicyDesk` | Framework — engine, models, seed, design system, teaching layer, intake, views |
| `WealthPolicyDeskExample` | Host app (`import WealthPolicyDesk` → `RootView()`) |

```bash
xcodebuild -project WealthPolicyDesk.xcodeproj -scheme WealthPolicyDeskExample \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

Regenerate the project after adding/removing a framework source file:

```bash
python3 generate_xcodeproj.py
```

## The experience

**Welcome → questionnaire → desk.** First launch shows a welcome (`Set up my
plan` or `Explore the sample — the Harrisons`). The **15-section intake wizard**
(`IntakeModel` → `buildHousehold()`) captures a household and builds a live
`Household`; the desk opens on it. The intake is saved on-device and reloads on
relaunch. `Edit my answers`, `Load sample`, `Start over`, and CRM export live in
the sidebar/⋯ menu.

Intake sections: Household · **Family** (children, 529 education goals) · Income
& human capital · **Equity comp** (ISO/NSO/RSU/ESPP/founder, insider window,
10b5-1, 83(b), QSBS) · Savings · Accounts · **Held-away holdings** (real positions
+ transition budget) · Home & debts · Other income (SS/pension) · **Protection**
(disability, life, LTC, umbrella) · Goals (retirement, legacy floor, additional
goals) · **Estate & giving** (heirs, charitable, docs) · You & risk (personality) ·
**Relationship** (CRM metadata) · Review.

Everything a layperson can't answer — eligibility tier, betas, sleeve mapping,
Social Security estimate, duration — is **derived or synthesized**, so minimal
input still produces a working desk. Itemized held-away positions are analyzed as
**real** holdings; the rest of each account is synthesized.

## The desk

An iPad three-region layout (`NavigationSplitView`): a **sidebar** of sections, a
centered **document column**, and a persistent **inspector** of live levers.
Editing a lever recomputes everything. A **client-profile strip** heads the desk
for a real relationship. Tabs: Balance Sheet · Required Return · Allocation ·
Constraints · Tax · Disposition · Tilts · Learn.

## Layout

```
Sources/WealthPolicyDesk/
  Units.swift              Bps / Usd / IsoDate + Fmt formatting, Severity, PolicyRule
  PolicyModel.swift        InvestmentPolicy, sleeves, alt budgets/wrappers, tiers, rebalance, withdrawal
  HouseholdModel.swift     Household, people, human capital, goals-as-claims, positions, EstateInputs
  TaxModel.swift           TaxParameterSet, SALT, estate, disposition types, itemization
  FixedIncomeModel.swift   Liabilities, BalanceSheetView, DeferredTaxLiability, muni crossover / paydown
  ExposureModel.swift      Sector, TiltPolicy (per-client tilt budget), Country×Sector matrix constraints
  LayerModel.swift         the Layer tag (strategic / tactical / ladder) every position carries
  Seed.swift               legacyPolicy, spendingPolicy, TAX_2026, tiltPolicy (budget),
                           every *_CONSTRAINTS set, and the sample household (the Harrisons)
  IntakeModel.swift        The 15-section questionnaire (Codable) + intake→Household builder + synthesis
  PracticeMetadata.swift   CRM envelope (Codable), PracticeStore, CRMExportRecord (interchange record)
  Book.swift               ClientRecord + BookStore (multi-client store, migration) + BookExport (NDJSON/CSV)
  Engine.swift             required return (after-tax), balance sheet, risk profile, evaluate() entry point
  EngineAnalyses.swift     allocation, itemization/SALT, disposition, ladder, muni, paydown, constraints
  Decumulation.swift       year-by-year after-tax retirement projection + Roth-conversion optimizer
  Resilience.swift         return-sensitivity + sequence-of-returns stress + max-safe-spend (no forecasts)
  Theme.swift / Components.swift   design tokens + the advisory-ledger component library
  Teach.swift              all teaching copy: per-card help, guided lessons, two-register glossary
  IntakeView.swift         RootView (multi-client routing + book persistence), WelcomeView, wizard, form controls
  RosterView.swift         the book of business — client roster, summary, whole-book export
  DeskView.swift           the desk shell, client strip, live household inspector
  *Tab.swift               the 17 desk tabs (Policy Statement, Plan Summary, … Decumulation, Resilience, Frontier)
Example/                   host app + Info.plist + Assets
generate_xcodeproj.py      regenerates the pbxproj from the framework file list
```

## The engine

`Engine.evaluate(household)` is a **pure function** of `(household, policy, tax,
asOf)` — no I/O, no clock, no randomness — so a delivered plan reproduces. It
implements the functions the policy layer declared and the engines it described:

- **Required return (after-tax)** — the real return to fund every claim, computed
  with no capital-market assumption; a legacy-floor-aware headline (floor defaults
  to $0, a lever prices the perpetual corpus) plus the required return *after*
  flexing goals. A **two-pass solve** folds the decumulation tax back into the
  recursion, so the anchor funds the tax on withdrawals too, not just the spending
  (the pre-tax→after-tax gap is the *tax drag*).
- **Decumulation** — a year-by-year **after-tax** retirement projection: RMDs (IRS
  Uniform Lifetime divisors), Social-Security taxation (provisional-income
  worksheet), withdrawal sequencing, progressive tax with **LTCG stacking**, NIIT,
  and **IRMAA** — yielding a lifetime-tax figure. A **Roth-conversion optimizer**
  fills the low-bracket pre-RMD years and keeps the lowest-lifetime-tax plan; tax is
  debited from the portfolio so the roll-forward conserves. All in real dollars,
  growing at the plan's own required return.
- **Balance sheet** — after-tax net worth, **net fixed income = FI assets − debt**,
  total-balance-sheet equity, deferred tax *extinguished* on step-up lots.
- **Risk profile** — capacity (derived) vs tolerance (elicited), bound to the lower.
- **Constraint evaluation** — walks every seeded hard/soft rule and emits the ones
  a household trips (incl. `concentrated_permanent_hold`, `transition_gain_budget_exceeded`,
  `ird_to_charity`, `estate_docs_incomplete`), silent on the rest.
- **Itemization / SALT · disposition · allocation · ladder · tilts** — as before,
  now driven off real held-away holdings and the estate/bequest routing.

## Book of business & CRM export

The app is **multi-client**: a **book of business** (`RosterView`) is the home
screen once it holds a relationship. Each client is a `ClientRecord` (`Book.swift`)
bundling a plan (`IntakeModel`) with its practice envelope (`PracticeMetadata`),
persisted as `[ClientRecord]` in `wealth-policy-book.json` via `BookStore`. A
pre-book single-client install is **migrated** into a one-record book once, then
its legacy files retire. The roster shows each relationship's stage, tier,
investable, next action and open hard-flag count; you open one onto the desk,
archive, or delete (confirmed). `PracticeMetadata` never feeds the engine.

The **CRM interchange record** (`CRMExportRecord`) joins the practice envelope to a
non-PII plan snapshot (investable, tier, filing, required real return, after-tax
net worth, funded ratio) plus the engine's open **planning flags** (hard/soft
counts + the hard ruleIds). It is deliberately **vendor-neutral** — no field is
shaped to a specific CRM's importer; a real integration is years out. Export a
single client (JSON/CSV) from the desk ⋯ menu, or the **whole book** as **NDJSON or
CSV** from the roster ⋯ menu. Contact data (the advisor's own) is included; account
numbers, per-account balances, and credentials never are. Nothing touches the network.

## Compliance

A **teaching and analysis tool**, framed exactly as the policy layer's README
requires: nothing here is investment advice or a recommendation. The disclaimer
is on-screen throughout. PII stays on device.

## Known simplifications & what's next (verify before real use)

- **Tax numbers** in `Seed.tax2026` (brackets, standard deduction, LTCG, IRMAA)
  are representative **2026 estimates** filling the TS `TAX_2026` TODOs.
- Required return uses a constant-real-return funding recursion + a TIPS-like safe
  real rate for PVs — teaching-grade, not Monte-Carlo (resilience/sequence-risk is
  Tier-2 Path B, not yet built). The after-tax fold is a **one-pass** approximation
  (tax fed from a pre-tax-growth projection; displayed projection grows after-tax).
- **Intake, Tranches 1–3 done.** T1 held-away holdings, additional goals, CRM;
  T2 dependents/education, estate & giving; **T3 Protection** (disability/life/LTC/
  umbrella coverage-gap engine + Balance Sheet readout) and **Equity comp**
  (ISO/AMT preference, 83(b) 30-day window, insider/10b5-1 blackout, QSBS, ESPP;
  options/ESPP legs feed single-employer concentration).
- **Model-deepening: Tier 0 (correctness) + Tier 1 (wiring) done; Tier-2 Path A
  (after-tax decumulation) + Path B (resilience/sequence risk) done.** Survivor SS
  economics now modeled (Tier 0). Resilience stresses are stylized historical
  ORDERS re-centered to the required return (not forecasts); the sensitivity's
  "at required return" lands ~0.7% off the floor (one-pass after-tax approximation).
  Open: Tier-2 Path C (real tax lots + entity layer); Tier-3 flags (ISO-AMT
  crossover, §1202 QSBS, 83(b) day-count, PV insurance needs).
- Deferred within Tranche 2: the 529→Roth clock advisory and per-child heir
  brackets (need intake→Household plumbing).
```
