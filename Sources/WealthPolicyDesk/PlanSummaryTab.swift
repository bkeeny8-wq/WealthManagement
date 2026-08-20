//  PlanSummaryTab.swift
//  WealthPolicyDesk
//
//  The client-facing deliverable — an Investment Policy Statement that synthesizes the
//  whole analysis into plain language a client reads and takes away. Everything else in
//  the app is the analyst's workbench; this is the one page the client sees: where they
//  stand, what the plan must do, how much risk, the policy allocation, the guardrails,
//  the next steps, and the assumptions behind it all. The same card views also paginate
//  into a shareable PDF (see `printBlocks` + PlanSummaryPDF).

import SwiftUI

struct PlanSummaryTab: View {
    let eval: Evaluation
    var clientHeader: ClientProfileHeader? = nil
    @State private var share: SharePayload? = nil

    private var bs: BalanceSheetView { eval.balanceSheet }
    private var rr: RequiredReturn { eval.requiredReturn }
    private var shortfall: ShortfallEstimate {
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
        return Engine.shortfallEstimate(eval, cme: cme)
    }
    // The target policy mix, aggregated by asset role (the client-facing view).
    private var roleMix: [(role: AssetRole, bps: Bps)] {
        var m: [AssetRole: Bps] = [:]
        for row in eval.allocation {
            let role = eval.legacyPolicy.sleeve(row.sleeveId)?.role ?? .growth
            m[role, default: 0] += row.targetBps
        }
        return AssetRole.allCases.compactMap { r in (m[r] ?? 0) > 0 ? (role: r, bps: m[r]!) : nil }
    }
    // The sleeve budget is only ~80% of the book; alternatives (sized by function, not
    // sleeve) carry the rest. Fold them in as their own bucket so the mix sums to 100%.
    private var altBudgetBps: Bps { eval.altSizing.reduce(0) { $0 + $1.targetBps } }
    private var allocationBuckets: [(label: String, bps: Bps, color: Color)] {
        var b = roleMix.map { (label: $0.role.label, bps: $0.bps, color: roleColor($0.role)) }
        if altBudgetBps > 0 { b.append((label: "Alternatives", bps: altBudgetBps, color: Theme.amber)) }
        return b
    }
    private var hardFindings: [Finding] { eval.findings.filter { $0.severity == .hard } }
    private var softFindings: [Finding] { eval.findings.filter { $0.severity == .soft } }
    // Gate copy/colour on the funded ratio AS DISPLAYED (rounded to 0.1%), so a value
    // that prints "100.0%" can never be described as still having a gap to close.
    private var isFunded: Bool { Int((Double(bs.fundedRatioBps) / 10).rounded()) * 10 >= 10_000 }

    var body: some View {
        masthead
        whereYouStandCard
        mustAchieveCard
        riskCard
        allocationCard
        guardrailsCard
        nextStepsCard
        disclosuresCard
        exportBar
    }

    // The document blocks, in order — shared by the screen and the PDF export.
    var printBlocks: [AnyView] {
        [AnyView(masthead), AnyView(whereYouStandCard), AnyView(mustAchieveCard), AnyView(riskCard),
         AnyView(allocationCard), AnyView(guardrailsCard), AnyView(nextStepsCard), AnyView(disclosuresCard)]
    }

    // MARK: - Cards

    private var whereYouStandCard: some View {
        Card("Where you stand") {
            HeadlineFigure(bs.afterTaxNetWorthUsd < 0 ? Fmt.usdSigned(bs.afterTaxNetWorthUsd) : Fmt.usd(bs.afterTaxNetWorthUsd),
                           caption: "Estimated after-tax net worth — what the household would keep after embedded tax", color: Theme.ink)
            LedgerRow("Investment portfolio", Fmt.usd(eval.household.portfolioValueUsd), color: Theme.ink)
            LedgerRow("Net fixed income (bonds net of debt)",
                      eval.netFixedIncomeUsd < 0 ? Fmt.usdSigned(eval.netFixedIncomeUsd) : Fmt.usd(eval.netFixedIncomeUsd),
                      color: eval.netFixedIncomeUsd < 0 ? Theme.debt : Theme.asset)
            Note("Net worth here is stated after the tax the household still owes on tax-deferred and appreciated assets — closer to what's really yours than the brokerage-statement total. The haircut uses effective-dated, assumed rates (and, for large estates, a projected estate tax), so read the figure as an estimate.")
            if eval.netFixedIncomeUsd < 0 {
                Note("Net fixed income is negative — the household runs NET SHORT duration (its debt outweighs its bonds), the opposite of a defensive cushion.", icon: "exclamationmark.triangle", color: Theme.debt)
            }
        }
    }

    private var mustAchieveCard: some View {
        Card("What your plan must achieve") {
            HeadlineFigure(Fmt.pctBps(rr.requiredRealReturnBps), caption: "the real, after-tax return your goals require", color: Theme.accent)
            LedgerRow("Funded ratio", Fmt.pctBps(bs.fundedRatioBps), color: isFunded ? Theme.asset : Theme.amber, bold: true)
            LedgerRow("Goals on file", "\(eval.household.goals.filter { $0.kind == .spending }.count)", color: Theme.muted)
            Note(isFunded
                 ? "Your resources cover your goals — the required return is the return that keeps it that way."
                 : "Your resources fund \(Fmt.pctBps(bs.fundedRatioBps)) of your goals. Closing the gap is a matter of return, savings, or flexing a goal — the required return is the return that would fund the rest.")
        }
    }

    private var riskCard: some View {
        Card("How much risk the plan takes") {
            if let risk = eval.riskProfile {
                StatGrid([
                    StatTile("Can afford", Fmt.pctBps(risk.capacityEquityBps), sub: "equity capacity", color: Theme.ink),
                    StatTile("Will stomach", Fmt.pctBps(risk.toleranceImpliedEquityBps), sub: "risk tolerance", color: Theme.ink),
                    StatTile("Equity ceiling", Fmt.pctBps(risk.bindingEquityBps), sub: "the lower of the two", color: Theme.accent),
                ])
                LedgerRow("Chance of missing the goal", Fmt.pctBps(shortfall.shortfallProbBps, 0), color: shortfall.shortfallProbBps > 5000 ? Theme.debt : (shortfall.shortfallProbBps > 3000 ? Theme.amber : Theme.asset), bold: true)
                Note("The plan CAPS equity at the lower of what you can afford and what you can stomach, then dials the actual target below that ceiling as funded status improves — so your growth allocation below can sit under this number.")
                Note("The shortfall figure compares an after-tax required return against an expected return stated gross of fund fees and annual taxes, so it errs slightly optimistic — read a thin margin as roughly funded, not a cushion.", icon: "info.circle")
            } else {
                Note("Risk tolerance isn't on file yet — answer the risk questions to see the equity ceiling and the chance of missing the goal.", icon: "questionmark.circle")
            }
        }
    }

    private var allocationCard: some View {
        Card("Your policy allocation") {
            StackBar(allocationBuckets.map { StackSegment($0.label, Double($0.bps), $0.color) })
            ForEach(allocationBuckets, id: \.label) { r in
                LedgerRow(r.label, Fmt.pctBps(r.bps), color: r.color)
            }
            Note("This is the target the plan steers to — DERIVED from your goals, funded status, and risk, not a fixed 60/40. Alternatives are sized by function (convexity, defined-outcome, illiquidity premium) and may narrow to what's available at your account tier. Change a goal and the target moves; your current mix is compared against it on the Allocation tab.")
        }
    }

    private var guardrailsCard: some View {
        Card("Guardrails on your plan") {
            HStack(spacing: 8) {
                StatTile("Must resolve", "\(hardFindings.count)", sub: "hard limits", color: hardFindings.isEmpty ? Theme.asset : Theme.debt)
                StatTile("To review", "\(softFindings.count)", sub: "soft flags", color: softFindings.isEmpty ? Theme.asset : Theme.amber)
            }
            ForEach(Array(hardFindings.prefix(3))) { f in guardrailRow(f, Theme.debt) }
            ForEach(Array(softFindings.prefix(hardFindings.isEmpty ? 3 : 2))) { f in guardrailRow(f, Theme.amber) }
            if hardFindings.isEmpty && softFindings.isEmpty {
                Note("No constraints tripped — the plan sits inside every limit.", icon: "checkmark.seal", color: Theme.asset)
            }
        }
    }

    private var nextStepsCard: some View {
        Card("What the analysis flags next") {
            ForEach(Array(nextSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 9) {
                    Text("\(i + 1)").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                    Text(step).font(.system(size: 13.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Note("These are analytical observations drawn from your own inputs — not personalized investment advice or a recommendation to buy or sell any security.", icon: "info.circle")
        }
    }

    private var disclosuresCard: some View {
        Card("Assumptions & disclosures") {
            LedgerRow("Prepared as of", eval.asOf, color: Theme.muted)
            LedgerRow("Tax year / law", "2026 · OBBBA (P.L. 119-21)", color: Theme.muted)
            LedgerRow("Safe real rate", Fmt.pctBps(rr.safeRealRateBps), color: Theme.muted)
            Note("This is a teaching and analysis document, not investment advice or a recommendation. Every figure uses editable, effective-dated assumptions that must be verified before any client use. Forward-looking figures (expected returns, shortfall odds) come from a labelled capital-market model and are estimates, not forecasts.", icon: "info.circle")
        }
    }

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("INVESTMENT POLICY STATEMENT").font(.system(size: 12, weight: .heavy)).tracking(2).foregroundStyle(Theme.accent)
            Text(clientHeader?.title ?? eval.household.name).font(.system(size: 30, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
            Text("Prepared \(eval.asOf) · \(eval.household.filingStatus.label) · \(eval.household.stateOfResidence)")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    // MARK: - Export (screen-only chrome, never part of printBlocks)

    private var exportBar: some View {
        Button {
            let name = clientHeader?.title ?? eval.household.name
            if let url = PlanSummaryPDF.render(blocks: printBlocks, fileName: PlanSummaryPDF.fileName(for: name)) {
                share = SharePayload(url: url)
            }
        } label: {
            Label("Export as PDF", systemImage: "square.and.arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .padding(.top, 6)
        .sheet(item: $share) { payload in ShareSheet(items: [payload.url]) }
    }

    // The two or three concrete moves, drawn from the analysis.
    private var nextSteps: [String] {
        var steps: [String] = []
        if eval.allocation.contains(where: { $0.status != .within }) {
            steps.append("The book has drifted off its policy target — some sleeves sit outside their band. The Rebalance tab shows the tax-aware trades that would close the gap.")
        }
        if eval.decumulation.lifetimeTaxSavedUsd > 10_000 {
            steps.append("The plan estimates about \(Fmt.usdShort(eval.decumulation.lifetimeTaxSavedUsd)) of lifetime tax saved from Roth conversions in low-bracket years — the Decumulation tab lays out the year-by-year path.")
        }
        for f in hardFindings.prefix(2) { steps.append("A hard limit to resolve — \(f.title): \(f.detail)") }
        if !isFunded {
            steps.append("The plan funds \(Fmt.pctBps(bs.fundedRatioBps)) of its goals; closing the gap is a matter of return, savings, or flexing a goal.")
        }
        if steps.isEmpty { steps.append("The plan is funded, inside every guardrail, and near its policy target — nothing is flagged. Worth a review annually or on a life change.") }
        return Array(steps.prefix(5))
    }

    private func guardrailRow(_ f: Finding, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(f.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Text(f.detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
        }
        .padding(.vertical, 4)
    }

    private func roleColor(_ r: AssetRole) -> Color {
        switch r {
        case .growth: return Theme.accent
        case .defensive: return Theme.ink.opacity(0.5)
        case .realDiversifier: return Theme.debt.opacity(0.6)
        case .cash: return Theme.ink.opacity(0.25)
        }
    }
}
