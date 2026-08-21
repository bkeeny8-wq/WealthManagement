//  DeskView.swift
//  WealthPolicyDesk
//
//  The desk, laid out for iPad: a sidebar of sections (NavigationSplitView) and a
//  centered document column of the selected analysis. Every analysis tab is a
//  pure read-out of Engine.evaluate(household).
//
//  The Planning tab is where the plan CHANGES: moves (sell/rotate) are staged
//  against a draft copy of the household, so the whole desk previews their effect
//  live and non-destructively (a banner marks the preview state). Nothing touches
//  the client of record until an explicit Commit, which persists the moves and
//  rebaselines the household. Engine being pure is what makes the preview exact.

import SwiftUI

public enum DeskTab: String, CaseIterable, Identifiable, Hashable {
    case policyStatement = "Policy Statement"
    case summary = "Plan Summary"
    case balanceSheet = "Balance Sheet"
    case requiredReturn = "Required Return"
    case resilience = "Resilience"
    case allocation = "Allocation"
    case exposure = "Exposure"
    case riskScale = "Risk Scale"
    case frontier = "Frontier"
    case rebalance = "Rebalance"
    case planning = "Planning"
    case constraints = "Constraints"
    case tax = "Tax"
    case decumulation = "Decumulation"
    case disposition = "Disposition"
    case tilts = "Tilts"
    case learn = "Learn"
    public var id: String { rawValue }
    var icon: String {
        switch self {
        case .policyStatement: return "doc.text"
        case .summary: return "doc.richtext"
        case .balanceSheet: return "scalemass"
        case .requiredReturn: return "target"
        case .resilience: return "shield.lefthalf.filled"
        case .allocation: return "chart.pie"
        case .exposure: return "square.grid.3x3.fill"
        case .riskScale: return "slider.horizontal.3"
        case .frontier: return "chart.dots.scatter"
        case .rebalance: return "arrow.triangle.2.circlepath"
        case .planning: return "arrow.left.arrow.right"
        case .constraints: return "checklist"
        case .tax: return "percent"
        case .decumulation: return "calendar"
        case .disposition: return "arrow.triangle.branch"
        case .tilts: return "dial.medium"
        case .learn: return "book"
        }
    }
}

struct DeskView: View {
    @Binding var household: Household
    var clientHeader: ClientProfileHeader? = nil
    var exportJSON: String? = nil
    var exportCSV: String? = nil
    var committedStatuses: [CommittedMoveStatus] = []
    var canPersist: Bool = true
    var onCommit: ([PlannedAction]) -> Void = { _ in }
    var onCommitTilts: ([TacticalTiltAction]) -> Void = { _ in }
    var onEditIntake: () -> Void
    var onLoadSample: () -> Void
    var onClose: () -> Void
    var onEcon: () -> Void = {}
    var onCommitOverrides: (HouseholdOverrides) -> Void = { _ in }
    var onResetOverrides: () -> Void = {}
    var reviews: [IPSReview] = []
    var onSaveReview: (HouseholdOverrides, String, [String]) -> Void = { _, _, _ in }
    @State private var section: DeskTab? = .policyStatement
    /// Moves staged on the desk but not yet committed. The whole desk previews
    /// the household with these applied; Commit clears them onto the record.
    @State private var staged: [PlannedAction] = []
    @State private var stagedTilts: [TacticalTiltAction] = []
    /// Foundational-assumption edits made from the Policy Statement, not yet committed.
    @State private var draftOverrides = HouseholdOverrides()

    /// The household everything on the desk is evaluated against — the record
    /// plus any staged (uncommitted) moves, tactical tilts, and policy edits.
    private var previewHousehold: Household {
        var h = household.applying(staged)
        h.tacticalTilts = household.tacticalTilts + stagedTilts
        return h.withDriverOverrides(draftOverrides)
    }
    private var eval: Evaluation { Engine.evaluate(previewHousehold) }

    public var body: some View {
        let e = eval
        return NavigationSplitView {
            sidebar(e)
        } detail: {
            detail(e)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.accent)
    }

    private func commit() {
        guard !staged.isEmpty || !stagedTilts.isEmpty || !draftOverrides.isEmpty else { return }
        if !staged.isEmpty { onCommit(staged.map { var a = $0; a.status = .committed; return a }) }
        if !stagedTilts.isEmpty { onCommitTilts(stagedTilts.map { var t = $0; t.status = .committed; return t }) }
        if !draftOverrides.isEmpty { onCommitOverrides(draftOverrides) }
        staged = []; stagedTilts = []; draftOverrides = HouseholdOverrides()
    }
    private func discard() { staged = []; stagedTilts = []; draftOverrides = HouseholdOverrides() }

    // MARK: sidebar

    private func sidebar(_ e: Evaluation) -> some View {
        let tier = e.legacyPolicy.tier(household.eligibilityTierId)
        return List(selection: $section) {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(household.name)
                        .font(.system(.title3, design: .serif).weight(.bold)).foregroundStyle(Theme.ink)
                    Text("\(household.filingStatus.rawValue.uppercased()) · \(household.stateOfResidence) · \(tier?.label ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    HStack(spacing: 6) {
                        miniStat("After-tax", Fmt.usdShort(e.balanceSheet.afterTaxNetWorthUsd), Theme.ink)
                        miniStat("Req. real", Fmt.pctBps(e.requiredReturn.requiredRealReturnBps), Theme.asset)
                        miniStat("Net FI", Fmt.usdShort(e.netFixedIncomeUsd), e.netFixedIncomeUsd < 0 ? Theme.debt : Theme.asset)
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
            Section("Analysis") {
                ForEach(DeskTab.allCases) { t in
                    Label(t.rawValue, systemImage: t.icon).tag(t)
                }
            }
            Section("Plan") {
                Button { onClose() } label: { Label("Book of business", systemImage: "rectangle.stack") }
                    .foregroundStyle(Theme.ink)
                Button { onEcon() } label: { Label("Econ backdrop", systemImage: "globe.americas") }
                    .foregroundStyle(Theme.ink)
                Button { onEditIntake() } label: { Label("Edit client profile", systemImage: "pencil") }
                    .foregroundStyle(Theme.ink)
                Button { onLoadSample() } label: { Label("Load sample", systemImage: "person.2") }
                    .foregroundStyle(Theme.ink)
            }
            Section {
                Text(Teach.disclosure).font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Wealth Policy")
        .navigationSplitViewColumnWidth(min: 280, ideal: 312, max: 360)
    }

    private func miniStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: detail

    private func detail(_ e: Evaluation) -> some View {
        let tab = section ?? .balanceSheet
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let ch = clientHeader { ClientStrip(header: ch) }
                tabContent(tab, e)
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.paper)
        .safeAreaInset(edge: .top) { if !staged.isEmpty || !stagedTilts.isEmpty || !draftOverrides.isEmpty { stagingBanner } }
        .navigationTitle(tab.rawValue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { onEditIntake() } label: { Label("Edit client profile", systemImage: "pencil") }
                    Button { onEcon() } label: { Label("Econ backdrop", systemImage: "globe.americas") }
                    Button { draftOverrides = HouseholdOverrides(); onResetOverrides() } label: { Label("Reset policy edits to standard", systemImage: "arrow.uturn.backward") }
                    Button { onLoadSample() } label: { Label("Load sample (Harrisons)", systemImage: "person.2") }
                    if let json = exportJSON {
                        ShareLink(item: json, preview: SharePreview("Client record (JSON)")) { Label("Export record (JSON)", systemImage: "square.and.arrow.up") }
                    }
                    if let csv = exportCSV {
                        ShareLink(item: csv, preview: SharePreview("Client record (CSV)")) { Label("Export record (CSV)", systemImage: "tablecells") }
                    }
                    Divider()
                    Button { onClose() } label: { Label("Back to book", systemImage: "rectangle.stack") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    // MARK: routed content

    @ViewBuilder private func tabContent(_ tab: DeskTab, _ e: Evaluation) -> some View {
        switch tab {
        case .policyStatement: PolicyStatementTab(eval: e, clientHeader: clientHeader, draftOverrides: $draftOverrides,
                                                  reviews: reviews,
                                                  saveReview: { note, confirmed in onSaveReview(draftOverrides, note, confirmed); draftOverrides = HouseholdOverrides() },
                                                  canPersist: canPersist,
                                                  hasStagedMoves: !staged.isEmpty || !stagedTilts.isEmpty)
        case .summary:        PlanSummaryTab(eval: e, clientHeader: clientHeader)
        case .balanceSheet:   BalanceSheetTab(eval: e)
        case .requiredReturn: RequiredReturnTab(eval: e)
        case .resilience:     ResilienceTab(eval: e)
        case .allocation:     AllocationTab(eval: e)
        case .exposure:       ExposureTab(eval: e)
        case .riskScale:      RiskScaleTab(eval: e)
        case .frontier:       FrontierTab(eval: e)
        case .rebalance:      RebalanceTab(eval: e)
        case .planning:       PlanningTab(base: household, staged: $staged, stagedTilts: $stagedTilts,
                                          committed: committedStatuses, committedTilts: household.tacticalTilts,
                                          canPersist: canPersist, onCommit: commit, onDiscard: discard)
        case .constraints:    ConstraintsTab(eval: e)
        case .tax:            TaxTab(eval: e)
        case .decumulation:   DecumulationTab(eval: e)
        case .disposition:    DispositionTab(eval: e)
        case .tilts:          TiltsTab(eval: e)
        case .learn:          LearnTab()
        }
    }

    // MARK: staging banner (pinned above every tab while moves are staged)

    /// Realized-gain tax if the staged moves were committed. The taxable gains are
    /// stacked and taxed once (summing per-move taxes would understate by ignoring
    /// bracket stacking). Each move's marginal gain is measured against the
    /// household left by the moves before it.
    private var stagedTaxTotal: Usd {
        var h = household
        var totalST: Usd = 0, totalLT: Usd = 0
        for m in staged {
            if let p = h.positions.first(where: { $0.accountId == m.sellAccountId && $0.ticker == m.sellTicker }),
               h.treatment(of: p) == .taxable {
                let (st, lt) = p.realizedGainSplit(sellUsd: m.sellUsd, asOf: Engine.planningAsOf)
                totalST += st; totalLT += lt        // short-term taxed as ordinary, matching the commit path
            }
            h = h.applying(m)
        }
        return Engine.capitalGainsTaxAggregate(household, shortTerm: totalST, longTerm: totalLT)
    }

    private var previewLabel: String {
        var parts: [String] = []
        if !staged.isEmpty { parts.append("\(staged.count) move\(staged.count == 1 ? "" : "s")") }
        if !stagedTilts.isEmpty { parts.append("\(stagedTilts.count) tilt\(stagedTilts.count == 1 ? "" : "s")") }
        if !draftOverrides.isEmpty { parts.append("\(draftOverrides.count) policy edit\(draftOverrides.count == 1 ? "" : "s")") }
        return "Previewing " + parts.joined(separator: " + ") + " staged"
    }

    private var stagingBanner: some View {
        let taxTotal = stagedTaxTotal
        return HStack(spacing: 12) {
            Image(systemName: "eye.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(previewLabel)
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                Text(taxTotal > 0 ? "Not saved · ~\(Fmt.usd(taxTotal)) tax if committed" : "Not saved · no tax realized")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button { discard() } label: { Text("Discard").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.debt)
            Button { commit() } label: {
                Text(canPersist ? "Commit" : "Apply").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7).background(Theme.accent, in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.amber.opacity(0.12))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}

/// The practice-facing client strip at the top of the desk.
struct ClientStrip: View {
    let header: ClientProfileHeader
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(header.title).font(.system(size: 19, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                    Text(header.badge.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent, in: Capsule())
                }
                Text(header.subtitle + " · " + header.caption).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !header.nextAction.isEmpty {
                Label(header.nextAction, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rule))
    }
}
