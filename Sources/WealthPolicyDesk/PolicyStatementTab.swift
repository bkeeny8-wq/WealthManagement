//  PolicyStatementTab.swift
//  WealthPolicyDesk
//
//  The Investment Policy Statement as a formal WRITTEN document, structured the way the
//  CFA Institute frames one: purpose and governance, then the two investment OBJECTIVES
//  (return, risk), the five CONSTRAINTS (liquidity, time horizon, taxes, legal/regulatory,
//  unique circumstances), the strategic asset allocation that falls out of them, the
//  rebalancing policy, and the review process. Prose, not a dashboard — the same numbers
//  the desk computes, written as the policy that governs the portfolio. Exports to PDF
//  through the shared PlanSummaryPDF renderer.

import SwiftUI

struct PolicyStatementTab: View {
    let eval: Evaluation
    var clientHeader: ClientProfileHeader? = nil
    /// When present, the return/risk drivers become inline-editable and edits stage a
    /// live re-derive of the whole plan (nil = read-only, e.g. the PDF export).
    var draftOverrides: Binding<HouseholdOverrides>? = nil
    /// The client's year-over-year review history, and the action that snapshots a new one
    /// (given the advisor's note and the section keys confirmed "still applicable").
    var reviews: [IPSReview] = []
    var saveReview: ((String, [String]) -> Void)? = nil
    /// Reviews persist only for a real client record; false on the sample (no record to save to).
    var canPersist: Bool = true
    /// True while uncommitted trades/tilts are staged on another tab — a review captures the
    /// PLAN OF RECORD, so saving is blocked until those are committed or discarded.
    var hasStagedMoves: Bool = false
    @State private var share: SharePayload? = nil
    @State private var reviewNote = ""
    @State private var confirmed: Set<String> = []

    /// The IPS sections the advisor walks and confirms during a review.
    private let reviewSections: [(key: String, label: String)] = [
        ("return", "Return objective"), ("goals", "Goals"), ("risk", "Risk objective"),
        ("constraints", "Constraints"), ("allocation", "Allocation"), ("rebalancing", "Rebalancing"),
    ]

    // MARK: derived reads
    private var h: Household { eval.household }
    private var bs: BalanceSheetView { eval.balanceSheet }
    private var rr: RequiredReturn { eval.requiredReturn }
    private var reb: RebalancePolicy { eval.legacyPolicy.rebalance }
    private var ladder: LadderPlan { eval.ladder }
    private var clientName: String { clientHeader?.title ?? h.name }
    private var primary: Person? { h.people.first { $0.role == .primary } ?? h.people.first }
    private var spouse: Person? { h.people.first { $0.role == .spouse } }
    private var isCouple: Bool { spouse != nil }
    private var age: Int { primary.map { Engine.age(birthDate: $0.birthDate, asOf: eval.asOf) } ?? 0 }
    private var retireAge: Int { primary?.expectedRetirementAge ?? 65 }
    private var yearsToRetire: Int { max(0, retireAge - age) }
    private var longevity: Int { primary?.longevityPercentileTarget ?? 95 }
    private var horizonYears: Int { max(1, h.goals.compactMap { $0.horizonYears }.max() ?? 30) }
    private var deferredTax: Usd { bs.liabilities.deferredTaxUsd }   // embedded income tax only (excludes estate tax)
    private var isFunded: Bool { Int((Double(bs.fundedRatioBps) / 10).rounded()) * 10 >= 10_000 }
    private var shortfall: ShortfallEstimate {
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
        return Engine.shortfallEstimate(eval, cme: cme)
    }
    private var allocationBuckets: [(label: String, bps: Bps)] {
        var m: [AssetRole: Bps] = [:]
        for row in eval.allocation { m[eval.legacyPolicy.sleeve(row.sleeveId)?.role ?? .growth, default: 0] += row.targetBps }
        var out = AssetRole.allCases.compactMap { r in (m[r] ?? 0) > 0 ? (label: r.label, bps: m[r]!) : nil }
        let alt = eval.altSizing.reduce(0) { $0 + $1.targetBps }
        if alt > 0 { out.append((label: "Alternatives", bps: alt)) }
        return out
    }
    private var hardFindings: [Finding] { eval.findings.filter { $0.severity == .hard } }
    // Genuinely-unique circumstances only — exclude modules already covered by their own
    // constraint section (taxes, liquidity/fixed income) and internal-only findings.
    private var uniqueItems: [String] {
        let excluded: Set<FindingModule> = [.tax, .fixedIncome, .layer, .tilt]
        let ordered = eval.findings.filter { $0.severity == .hard } + eval.findings.filter { $0.severity == .soft }
        return Array(ordered.filter { !excluded.contains($0.module) }.map { $0.title }.prefix(5))
    }
    private var titlingPhrase: String {
        let present = h.accounts.filter { $0.treatment == .taxable }.map { $0.ownership.kind }
        let ordered = OwnershipKind.allCases.filter { present.contains($0) }   // stable order (reproducibility)
        return listJoin(ordered.map { $0.label.lowercased() })
    }

    var body: some View {
        letterhead
        if saveReview != nil && canPersist { reviewBar; reviewPanel }   // screen-only; real client only
        purposeSection
        governanceSection
        returnObjectiveSection(editable: draftOverrides != nil)
        goalsSection(editable: draftOverrides != nil)
        riskObjectiveSection(editable: draftOverrides != nil)
        constraintsSection
        allocationSection
        rebalancingSection
        reviewSection
        if !reviews.isEmpty { reviewHistorySection }
        disclosuresSection
        exportBar
    }

    var printBlocks: [AnyView] {
        var b: [AnyView] = [AnyView(letterhead), AnyView(purposeSection), AnyView(governanceSection),
             AnyView(returnObjectiveSection(editable: false)), AnyView(goalsSection(editable: false)), AnyView(riskObjectiveSection(editable: false)), AnyView(constraintsSection),
             AnyView(allocationSection), AnyView(rebalancingSection), AnyView(reviewSection)]
        if !reviews.isEmpty { b.append(AnyView(reviewHistorySection)) }
        b.append(AnyView(disclosuresSection))
        return b
    }

    // MARK: - Sections

    private var letterhead: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INVESTMENT POLICY STATEMENT").font(.system(size: 12, weight: .heavy)).tracking(2).foregroundStyle(Theme.accent)
            Text(clientName).font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
            Text("Prepared \(eval.asOf) · \(h.filingStatus.label) · \(h.stateOfResidence)")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.rule).frame(height: 1).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var purposeSection: some View {
        section("1", "Purpose and scope") {
            p("This Investment Policy Statement (IPS) establishes the objectives, constraints, and policies that govern the management of the investment assets of \(clientName). It states the return the portfolio is required to earn, the risk it may take, the constraints it must respect, the strategic asset allocation that follows from them, and the process for rebalancing and review.")
            p("The assets governed by this statement total approximately \(Fmt.usd(h.portfolioValueUsd)) in investable capital, part of an estimated after-tax net worth of \(Fmt.usd(bs.afterTaxNetWorthUsd)). This document is intended to align the portfolio with the household's goals and to serve as the reference against which investment decisions and results are judged.")
        }
    }

    private var governanceSection: some View {
        section("2", "Roles and responsibilities") {
            p("The adviser is responsible for recommending and monitoring the policy set out here, for constructing and rebalancing the portfolio consistent with it, and for reviewing it with the household. The household is responsible for providing complete and accurate information about its circumstances and goals, for funding the plan, and for approving material changes. Both parties should treat this statement as a living document, revised when the facts it rests on change.")
        }
    }

    private func returnObjectiveSection(editable: Bool) -> some View {
        section("3", "Investment objective — return") {
            p("The portfolio is required to earn a real, after-tax return of approximately \(Fmt.pctBps(rr.requiredRealReturnBps)) per year\(rr.legacyFloorUsd > 0 ? " while preserving a legacy floor of \(Fmt.usd(rr.legacyFloorUsd)) in today's dollars" : ""). Because the plan already funds the taxes its own withdrawals generate, this after-tax figure — not the \(Fmt.pctBps(rr.requiredRealReturnPreTaxBps)) pre-tax equivalent — is the binding hurdle.")
            p(fundedText)
            if isCouple { p(survivorAssumptionText) }
            if editable, let b = draftOverrides {
                savingsRetireEditor(b)
                legacyFloorEditor(b)
            }
        }
    }

    private func savingsRetireEditor(_ o: Binding<HouseholdOverrides>) -> some View {
        let savings = h.annualSavingsUsd
        let retAge = primary?.expectedRetirementAge ?? 65
        return editorRow("Savings & retirement", now: retireSummary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    miniStepper("Annual savings", Fmt.usdShort(savings),
                                minus: { o.wrappedValue.annualSavingsUsd = max(0, savings - 10_000) },
                                plus:  { o.wrappedValue.annualSavingsUsd = savings + 10_000 })
                    miniStepper(isCouple ? "\(firstName(primary)) retires" : "Retire at age", "\(retAge)",
                                minus: { o.wrappedValue.retirementAge = max(age + 1, retAge - 1) },
                                plus:  { o.wrappedValue.retirementAge = min(longevity - 1, retAge + 1) })
                }
                if isCouple, let sp = spouse {
                    let spAge = Engine.age(birthDate: sp.birthDate, asOf: eval.asOf)
                    let spRet = sp.expectedRetirementAge
                    miniStepper("\(firstName(sp)) retires", "\(spRet)",
                                minus: { o.wrappedValue.spouseRetirementAge = max(spAge + 1, spRet - 1) },
                                plus:  { o.wrappedValue.spouseRetirementAge = min(sp.longevityPercentileTarget - 1, spRet + 1) })
                }
            }
        }
    }

    private var retireSummary: String {
        let s = "\(Fmt.usdShort(h.annualSavingsUsd))/yr"
        let p = primary?.expectedRetirementAge ?? 65
        if isCouple, let sp = spouse { return "\(s) · retire \(p) / \(sp.expectedRetirementAge)" }
        return "\(s) · retire \(p)"
    }

    private func firstName(_ p: Person?) -> String {
        guard let label = p?.label, !label.isEmpty else { return "Retire" }
        return String(label.split(separator: " ").first ?? Substring(label))
    }

    /// A couples-only footnote making the survivor-spending assumption visible in the
    /// document (it moves the required return, so it should not be silent). Marked as an
    /// assumption to verify, consistent with the rest of the statement.
    private var survivorAssumptionText: String {
        let survivorPct = Int((Engine.survivorSpendingFactor * 100).rounded())
        let dropPct = 100 - survivorPct
        // The binding savings window is the LATER of the two retirements measured in time
        // (a spouse who retires at a lower age can still be the later one), so quote the
        // engine's own save-years rather than an age that could name the earlier retiree.
        let saveYears = Engine.householdSaveYears(h, asOf: eval.asOf)
        let yearWord = saveYears == 1 ? "year" : "years"
        return "Because the household is a couple, the plan assumes it keeps saving until the later of the two retirements — about \(saveYears) more \(yearWord) — and that joint retirement spending steps down by about \(dropPct)% (to roughly \(survivorPct)% of its level) after the first death, reflecting a survivor's lower cost of living. This assumption lowers the required return and should be verified against the household's own circumstances."
    }

    private var fundedText: String {
        let hasFlex = rr.requiredRealReturnWithFlexibilityBps < rr.requiredRealReturnBps
        let flexPct = Fmt.pctBps(rr.requiredRealReturnWithFlexibilityBps)
        if isFunded {
            let base = "The household's resources currently fund its goals in full (funded ratio \(Fmt.pctBps(bs.fundedRatioBps))); the required return is the rate that keeps it so."
            return hasFlex ? base + " Modest goal flexibility would ease the requirement to \(flexPct)." : base
        }
        let base = "The household's resources currently fund about \(Fmt.pctBps(bs.fundedRatioBps)) of its goals; the required return is the rate that would fund the remainder."
        return hasFlex
            ? base + " Deferring or scaling a goal lowers the requirement to \(flexPct) — closing the gap through flexibility, savings, or return, not by taking risk the plan cannot bear."
            : base + " Closing the gap is a matter of savings or return, not risk the plan cannot bear."
    }

    private func riskObjectiveSection(editable: Bool) -> some View {
        section("4", "Investment objective — risk") {
            if let r = eval.riskProfile {
                p("Risk tolerance is the lower of the household's ABILITY and WILLINGNESS to bear risk. Ability (capacity), reflecting the funded ratio, time horizon, and human capital, supports up to \(Fmt.pctBps(r.capacityEquityBps)) in equities. Willingness, from a stated maximum tolerable one-year drawdown of about \(Fmt.pctBps(h.statedToleranceMaxDrawdownBps)), supports up to \(Fmt.pctBps(r.toleranceImpliedEquityBps)). Prudence binds the portfolio to the lower of the two — an equity ceiling of \(Fmt.pctBps(r.bindingEquityBps)).")
                p("At the policy allocation, the modelled probability of failing to meet the goal over the \(horizonYears)-year horizon is approximately \(Fmt.pctBps(shortfall.shortfallProbBps, 0)). This is a model estimate, not a guarantee; it compares an after-tax required return against an expected return stated gross of fees and annual taxes, so a thin margin should be read as roughly funded rather than a cushion.")
            } else {
                p("A formal risk tolerance is not yet on file. Completing the household's risk assessment — its maximum tolerable drawdown and its behavioural response to loss — is required before the equity ceiling and shortfall probability that anchor this policy can be set.")
            }
            if editable, let b = draftOverrides { toleranceEditor(b) }
        }
    }

    private var constraintsSection: some View {
        section("5", "Investment constraints") {
            constraint("Liquidity", liquidityText)
            constraint("Time horizon", timeHorizonText)
            constraint("Taxes", taxText)
            constraint("Legal and regulatory", "\(titlingPhrase.isEmpty ? "Taxable assets are held in the household's own name." : "Taxable accounts are titled as \(titlingPhrase), which governs the basis step-up available to heirs.") The portfolio is managed under the prudent-investor standard, with diversification and suitability as governing principles. Nothing in this statement constitutes legal or tax advice; account titling and beneficiary designations should be confirmed with qualified counsel.")
            constraint("Unique circumstances", uniqueText)
        }
    }

    private var liquidityText: String {
        let cover = ladder.covered ? "Current daily-liquid assets satisfy this requirement." : "Current daily-liquid assets fall short of this requirement and should be replenished."
        let hasSpending = ladder.requiredLiquidUsd > ladder.rebalanceReserveUsd
        let body = hasSpending
            ? "The portfolio must keep at least \(Fmt.usd(ladder.requiredLiquidUsd)) readily liquid — covering the household's near-term spending ladder, a rebalancing reserve of \(Fmt.usd(ladder.rebalanceReserveUsd)), and roughly twelve months of outflows — held in the cash and short-duration sleeves."
            : "The portfolio must keep a rebalancing reserve of \(Fmt.usd(ladder.rebalanceReserveUsd)) readily liquid in the cash sleeve; with no near-term spending need at this stage, no additional liquidity is pre-funded."
        return "\(body) \(cover) Beyond the near term, spending needs are met from portfolio cash flow and scheduled rebalancing."
    }

    private var cadenceAdverb: String {
        switch reb.reviewCadence.lowercased() {
        case "annual": return "annually"
        case "semiannual", "semi-annual": return "semi-annually"
        case "quarterly": return "quarterly"
        case "monthly": return "monthly"
        default: return "on a \(reb.reviewCadence) basis"
        }
    }

    private var timeHorizonText: String {
        let base: String
        if age >= retireAge {
            base = "\(clientName) is age \(age) and is in retirement" +
                (isCouple && spouse != nil ? " (with \(spouse!.label))" : "") +
                ", with a planning horizon that runs to roughly age \(longevity)."
        } else {
            base = "\(clientName) is age \(age) and plans to retire at \(retireAge)" +
                (isCouple && spouse != nil ? " (with \(spouse!.label) at \(spouse!.expectedRetirementAge))" : "") +
                " — an accumulation horizon of about \(yearsToRetire) years — followed by a retirement planned to roughly age \(longevity)."
        }
        let legacy = rr.legacyFloorUsd > 0
            ? " A legacy objective extends the effective horizon indefinitely, so the plan is managed to preserve capital in perpetuity rather than spend to zero."
            : ""
        return base + legacy + " The portfolio is therefore managed against a long, multi-stage horizon, which supports a meaningful allocation to growth assets within the risk ceiling."
    }

    private var taxText: String {
        var s = "The household files \(h.filingStatus.label) and resides in \(h.stateOfResidence). Assets are held across taxable and tax-advantaged accounts, and the portfolio is managed on an after-tax basis: embedded and deferred taxes of approximately \(Fmt.usd(deferredTax)) are treated as a real liability, and asset location and tax-aware rebalancing are integral to the policy. Planning reflects 2026 federal law under OBBBA (P.L. 119-21)."
        if let ec = h.equityComp, ec.isoBargainElementUsd > 0 {
            s += " Concentrated equity compensation is present; incentive-stock-option exercises are managed for alternative-minimum-tax exposure and single-employer concentration."
        }
        return s
    }

    private var uniqueText: String {
        if uniqueItems.isEmpty {
            return "No unusual circumstances beyond those set out above were identified. The plan's guardrails are reviewed on each update."
        }
        return "The policy reflects the following circumstances and constraints the plan has flagged for this household: \(listJoin(uniqueItems)). Each is detailed, with its magnitude and remedy, in the plan's guardrails."
    }

    private var allocationSection: some View {
        section("6", "Strategic asset allocation") {
            p("The strategic allocation below is DERIVED from the objectives and constraints above — from the household's goals, funded status, and risk ceiling — rather than set to a fixed 60/40. Equity is held at or below the risk ceiling; the cash sleeve carries the liquidity floor; the balance is diversified across defensive and real-diversifying assets and a functional alternatives budget.")
            VStack(spacing: 0) {
                ForEach(allocationBuckets, id: \.label) { b in
                    LedgerRow(b.label, Fmt.pctBps(b.bps), color: Theme.ink)
                }
            }
            .padding(.vertical, 2)
            p("Each sleeve is managed within a tolerance band around its target; the intra-equity and intra-bond composition follows a diversified structural template. The current portfolio is compared against these targets, sleeve by sleeve, on the Allocation tab, and the trades required to close any gap are set out on the Rebalance tab.")
        }
    }

    private var rebalancingSection: some View {
        section("7", "Rebalancing policy") {
            p("The portfolio is reviewed \(cadenceAdverb) and rebalanced when a sleeve breaches its band. \(reb.correctionFractionBps >= 10_000 ? "Breaches are corrected fully back to target." : "Corrections are partial — about \(Fmt.pctBps(reb.correctionFractionBps)) of the way back to target — which controls turnover while keeping the portfolio inside its risk limits.")")
            p("Rebalancing is tax-aware: it favours sheltered accounts and realises losses before gains, observes the \(reb.washSaleWindowDays)-day wash-sale window, and \(reb.preferCashFlowRebalancing ? "uses contributions and withdrawals to rebalance where possible, minimising taxable sales" : "sizes trades to the minimum needed to restore the target"). Locked or gated holdings sit outside the bands, and the remainder of the portfolio absorbs their drift.")
        }
    }

    private var reviewSection: some View {
        section("8", "Monitoring and review") {
            p("Performance is judged against this policy — the strategic allocation and the required return — rather than against any single market index in isolation. The strategic allocation is derived from the household's goals, funding, risk, and constraints, so it moves when those inputs move.")
            p("This statement should be reviewed at least annually and whenever a material change occurs: a change in goals or their funding, a change in tax law, a change in employment or income, or a change in family or health circumstances. Each such change is an occasion to re-derive the policy rather than to adjust the portfolio ad hoc.")
        }
    }

    private var disclosuresSection: some View {
        section("9", "Assumptions and disclosures") {
            p("Prepared as of \(eval.asOf) using a safe real rate of \(Fmt.pctBps(rr.safeRealRateBps)) and 2026 tax law under OBBBA (P.L. 119-21). Every figure rests on editable, effective-dated assumptions that must be verified before any client use.")
            p("This is a teaching and analysis document. It is not personalized investment, legal, or tax advice, nor a recommendation to buy or sell any security. Forward-looking figures — expected returns and shortfall probabilities — come from a labelled capital-market model and are estimates, not forecasts or guarantees of future results.")
        }
    }

    // MARK: - Annual review

    /// Screen-only banner: last-reviewed status + the action that snapshots a new review.
    private var reviewBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.checkmark").font(.system(size: 20)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                if let last = reviews.max(by: { $0.createdAt < $1.createdAt }) {
                    Text("LAST REVIEWED").font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.muted)
                    HStack(spacing: 6) {
                        Text(last.createdAt, style: .date).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("· \(reviews.count) on file").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("NOT YET REVIEWED").font(.system(size: 9, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.muted)
                    Text("Walk the statement, confirm each section, and save this year's review.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if hasStagedMoves {
                VStack(alignment: .trailing, spacing: 3) {
                    Label("Save as review", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.rule.opacity(0.3), in: Capsule())
                    Text("Commit or discard staged moves first").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                }
            } else {
                Button {
                    saveReview?(reviewNote.trimmingCharacters(in: .whitespacesAndNewlines),
                                reviewSections.map { $0.key }.filter { confirmed.contains($0) })
                    reviewNote = ""; confirmed = []
                } label: {
                    Label("Save as review", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.25)))
    }

    /// The "break it apart" checklist + a note, filled in while walking the statement.
    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("THIS YEAR'S REVIEW — confirm each section still applies")
                .font(.system(size: 10, weight: .heavy)).tracking(0.6).foregroundStyle(Theme.accent)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(reviewSections, id: \.key) { s in
                    let on = confirmed.contains(s.key)
                    Button {
                        if on { confirmed.remove(s.key) } else { confirmed.insert(s.key) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 13)).foregroundStyle(on ? Theme.accent : Theme.muted)
                            Text(s.label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(on ? Theme.accent.opacity(0.12) : Theme.card, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Theme.accent.opacity(0.4) : Theme.rule))
                    }.buttonStyle(.plain)
                }
            }
            Text("\(confirmed.count) of \(reviewSections.count) confirmed").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.muted)
            TextField("Notes for this review — what changed, what to watch…", text: $reviewNote, axis: .vertical)
                .font(.system(size: 13)).lineLimit(1...4)
                .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.15)))
    }

    private var reviewHistorySection: some View {
        let sorted = reviews.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Review history").font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(Theme.ink)
            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, r in
                reviewRow(r, prior: i + 1 < sorted.count ? sorted[i + 1] : nil)
            }
            Note("Each entry is a dated snapshot taken when the statement was walked and confirmed. The arrows show the change since the prior review.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func reviewRow(_ r: IPSReview, prior: IPSReview?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(r.createdAt, style: .date).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text("\(r.confirmedSections.count)/\(reviewSections.count) confirmed").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            }
            Text("Required \(Fmt.pctBps(r.requiredRealReturnBps))\(delta(r.requiredRealReturnBps, prior?.requiredRealReturnBps)) · Funded \(Fmt.pctBps(r.fundedRatioBps))\(delta(r.fundedRatioBps, prior?.fundedRatioBps)) · Net worth \(Fmt.usdShort(r.afterTaxNetWorthUsd))")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if !r.note.isEmpty {
                Text("“\(r.note)”").font(.system(size: 12)).italic().foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule.opacity(0.5)), alignment: .bottom)
    }

    /// A "(▲ 0.3%)" delta suffix vs the prior review; empty when the change is invisible at
    /// the displayed 0.1% precision (so we never print an arrow beside a "0.0%" magnitude).
    private func delta(_ now: Bps, _ prior: Bps?) -> String {
        guard let prior, Fmt.pctBps(now) != Fmt.pctBps(prior) else { return "" }
        return " (\(now > prior ? "▲" : "▼") \(Fmt.pctBps(abs(now - prior))))"
    }

    // MARK: - Export (screen-only, not part of printBlocks)

    private var exportBar: some View {
        Button {
            if let url = PlanSummaryPDF.render(blocks: printBlocks, fileName: PlanSummaryPDF.fileName(for: clientName)) {
                share = SharePayload(url: url)
            }
        } label: {
            Label("Export as PDF", systemImage: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
        }
        .padding(.top, 6)
        .sheet(item: $share) { payload in ShareSheet(items: [payload.url]) }
    }

    // MARK: - Prose helpers

    private func section<Content: View>(_ number: String, _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(number).font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.accent)
                Text(title).font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(Theme.ink)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func p(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5)).foregroundStyle(Theme.ink.opacity(0.9))
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func constraint(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
            p(text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listJoin(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? "")
        }
    }

    // MARK: - Inline driver editors (screen-only; never part of printBlocks)

    private func legacyFloorEditor(_ o: Binding<HouseholdOverrides>) -> some View {
        editorRow("Legacy floor — capital to preserve", now: h.legacyFloorUsd == 0 ? "None" : Fmt.usdShort(h.legacyFloorUsd)) {
            HStack(spacing: 6) {
                ForEach([Usd(0), 500_000, 1_000_000, 2_000_000, 5_000_000], id: \.self) { v in
                    chip(v == 0 ? "None" : Fmt.usdShort(v), selected: h.legacyFloorUsd == v) { o.wrappedValue.legacyFloorUsd = v }
                }
            }
        }
    }

    private func toleranceEditor(_ o: Binding<HouseholdOverrides>) -> some View {
        editorRow("Max tolerable one-year drawdown", now: Fmt.pctBps(h.statedToleranceMaxDrawdownBps)) {
            HStack(spacing: 6) {
                ForEach([Bps(1000), 2000, 3000, 4000], id: \.self) { v in
                    chip(Fmt.pctBps(v), selected: h.statedToleranceMaxDrawdownBps == v) { o.wrappedValue.toleranceMaxDrawdownBps = v }
                }
            }
        }
    }

    // MARK: - Goals (view + edit)

    private var spendingGoals: [Goal] { eval.household.goals.filter { $0.kind == .spending } }

    private func goalsSection(editable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("The goals your plan must fund")
                .font(.system(.title3, design: .serif).weight(.semibold)).foregroundStyle(Theme.ink)
            VStack(spacing: 0) {
                ForEach(spendingGoals, id: \.id) { g in goalRow(g, editable: editable) }
            }
            if editable, let b = draftOverrides {
                addGoalBar(b)
            }
            Note("These are the spending goals the required return must fund, in today's dollars. Resize a goal with the ± steppers, add one beyond retirement, or drop one — each move re-derives the required return and funded ratio above. Flexibility is often a cheaper lever than more risk.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func goalRow(_ g: Goal, editable: Bool) -> some View {
        let current = g.outflows.first?.amountUsd ?? g.nominalTodayUsd
        let firstY = g.outflows.map { $0.year }.min() ?? 0
        let lastY = g.outflows.map { $0.year }.max() ?? 0
        let oneTime = g.outflows.count <= 1
        let timing = oneTime ? "at age \(age + firstY)" : "ages \(age + firstY)–\(age + lastY)"
        let canTime = g.id != "g_spending"     // retirement timing is set by retirement age, not here
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(g.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                if editable, canTime, let b = draftOverrides {
                    Button { removeGoal(g, b) } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.debt.opacity(0.85))
                    }.buttonStyle(.plain)
                }
            }
            if editable, let b = draftOverrides {
                HStack(spacing: 10) {
                    goalStepper(g, current, b)
                    if !canTime { Text("per year · \(timing)").font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                }
                if canTime { timingEditor(g, b) }
            } else {
                Text(oneTime ? "\(Fmt.usd(current)) · \(timing)" : "\(Fmt.usd(current))/yr · \(timing)")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule.opacity(0.5)), alignment: .bottom)
    }

    private func removeGoal(_ g: Goal, _ o: Binding<HouseholdOverrides>) {
        if let idx = o.wrappedValue.addedGoals.firstIndex(where: { $0.goalId == g.id }) {
            o.wrappedValue.addedGoals.remove(at: idx)                 // a not-yet-committed add: just drop it
            o.wrappedValue.goalAmountOverrides[g.id] = nil            // and any amount / timing edit on it
            o.wrappedValue.goalTimingOverrides[g.id] = nil
        } else if !o.wrappedValue.removedGoalIds.contains(g.id) {
            o.wrappedValue.removedGoalIds.append(g.id)                // a standard/committed goal: mark removed
        }
    }

    // Start-age and duration steppers → a per-id timing override (reshapes the goal's outflows).
    private func timingEditor(_ g: Goal, _ o: Binding<HouseholdOverrides>) -> some View {
        let startY = g.outflows.map { $0.year }.min() ?? 1
        let yrs = max(1, g.outflows.count)
        return HStack(spacing: 16) {
            miniStepper("Starts age", "\(age + startY)",
                        minus: { setTiming(g, max(1, startY - 1), yrs, o) },
                        plus:  { setTiming(g, startY + 1, yrs, o) })
            miniStepper("For", "\(yrs) yr",
                        minus: { setTiming(g, startY, max(1, yrs - 1), o) },
                        plus:  { setTiming(g, startY, yrs + 1, o) })
        }
    }

    private func setTiming(_ g: Goal, _ startYear: Int, _ years: Int, _ o: Binding<HouseholdOverrides>) {
        o.wrappedValue.goalTimingOverrides[g.id] = GoalTiming(startYear: startYear, years: years)
    }

    private func miniStepper(_ label: String, _ value: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).tracking(0.5).foregroundStyle(Theme.muted)
            stepButton("minus", minus)
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink).frame(minWidth: 42, alignment: .center)
            stepButton("plus", plus)
        }
    }

    // A ± stepper on each goal's amount → a per-id amount override (retirement or any goal).
    private func goalStepper(_ g: Goal, _ current: Usd, _ o: Binding<HouseholdOverrides>) -> some View {
        let step = amountStep(current)
        return HStack(spacing: 6) {
            stepButton("minus") { o.wrappedValue.goalAmountOverrides[g.id] = max(step, current - step) }
            Text(Fmt.usd(current)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                .frame(minWidth: 96, alignment: .center)
            stepButton("plus") { o.wrappedValue.goalAmountOverrides[g.id] = current + step }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Theme.accent.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(Theme.accent.opacity(0.2)))
    }

    // A circular ± control with a generous (32pt) hit area.
    private func stepButton(_ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: icon + ".circle.fill").font(.system(size: 21)).foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func amountStep(_ a: Usd) -> Usd {
        if a >= 250_000 { return 50_000 }
        if a >= 100_000 { return 25_000 }
        if a >= 40_000 { return 10_000 }
        return 5_000
    }

    private func addGoalBar(_ o: Binding<HouseholdOverrides>) -> some View {
        editorRow("Add a goal beyond retirement", now: "\(o.wrappedValue.addedGoals.count) added") {
            HStack(spacing: 6) {
                addChip("+ Education", "Education", 40_000, 1, 4, o)
                addChip("+ Home", "Home purchase", 500_000, 3, 1, o)
                addChip("+ Travel", "Travel", 25_000, 1, 10, o)
            }
        }
    }

    private func addChip(_ label: String, _ goalLabel: String, _ annual: Usd, _ start: Int, _ years: Int, _ o: Binding<HouseholdOverrides>) -> some View {
        chip(label, selected: false) {
            o.wrappedValue.addedGoals.append(GoalEdit(id: UUID().uuidString, label: goalLabel, annualUsd: annual, startYear: start, years: years))
        }
    }

    @ViewBuilder private func editorRow<Chips: View>(_ label: String, now: String, @ViewBuilder _ chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                Text(label.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(Theme.accent)
                Text("· now \(now)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            chips()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.25)))
        .padding(.top, 2)
    }

    private func chip(_ label: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(label).font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Theme.accent : Theme.card, in: Capsule())
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .overlay(Capsule().stroke(selected ? Color.clear : Theme.rule))
        }.buttonStyle(.plain)
    }
}
