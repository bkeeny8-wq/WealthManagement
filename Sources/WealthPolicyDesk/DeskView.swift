//  DeskView.swift
//  WealthPolicyDesk
//
//  The desk, laid out for iPad: a sidebar of sections (NavigationSplitView), a
//  centered document column of the selected analysis, and a persistent
//  inspector of household levers on the trailing edge. Edit a lever and every
//  number recomputes live. Engine is a pure function of the household, so the
//  whole surface is a view of Engine.evaluate(household).

import SwiftUI

public enum DeskTab: String, CaseIterable, Identifiable, Hashable {
    case balanceSheet = "Balance Sheet"
    case requiredReturn = "Required Return"
    case resilience = "Resilience"
    case allocation = "Allocation"
    case constraints = "Constraints"
    case tax = "Tax"
    case decumulation = "Decumulation"
    case disposition = "Disposition"
    case tilts = "Tilts"
    case learn = "Learn"
    public var id: String { rawValue }
    var icon: String {
        switch self {
        case .balanceSheet: return "scalemass"
        case .requiredReturn: return "target"
        case .resilience: return "shield.lefthalf.filled"
        case .allocation: return "chart.pie"
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
    var onEditIntake: () -> Void
    var onLoadSample: () -> Void
    var onClose: () -> Void
    @State private var section: DeskTab? = .balanceSheet

    private var eval: Evaluation { Engine.evaluate(household) }

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
                Button { onEditIntake() } label: { Label("Edit my answers", systemImage: "pencil") }
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
        .navigationTitle(tab.rawValue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { onEditIntake() } label: { Label("Edit my answers", systemImage: "pencil") }
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
        case .balanceSheet:   BalanceSheetTab(eval: e)
        case .requiredReturn: RequiredReturnTab(eval: e)
        case .resilience:     ResilienceTab(eval: e)
        case .allocation:     AllocationTab(eval: e)
        case .constraints:    ConstraintsTab(eval: e)
        case .tax:            TaxTab(eval: e)
        case .decumulation:   DecumulationTab(eval: e)
        case .disposition:    DispositionTab(eval: e)
        case .tilts:          TiltsTab(eval: e)
        case .learn:          LearnTab()
        }
    }
}

// MARK: - Household inspector (the live levers)

struct HouseholdInspector: View {
    @Binding var household: Household

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("LEVERS").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.muted)

                Card("Filing status") {
                    ChoiceChips(FilingStatus.allCases.map { ($0, $0.rawValue.uppercased()) }, selection: household.filingStatus) { household.filingStatus = $0 }
                }
                Card("Real savings per year", help: Teach.help("requiredReturn")) {
                    // Upper bound always contains the live value so a touch never clamps it.
                    SliderRow(value: Binding(get: { household.annualSavingsUsd }, set: { household.annualSavingsUsd = $0 }),
                              range: 0...max(200_000, household.annualSavingsUsd), step: 5_000, display: Fmt.usd(household.annualSavingsUsd))
                    Note("Added to the corpus each year until the primary earner retires. Lowers the required return.")
                }
                if let idx = household.goals.firstIndex(where: { $0.kind == .spending }) {
                    let cur = household.goals[idx].outflows.first?.amountUsd ?? 0
                    Card("Retirement spending (today's $/yr)") {
                        SliderRow(value: spendingBinding(idx), range: 0...max(360_000, cur), step: 5_000,
                                  display: Fmt.usd(cur))
                        Note("Flows every year of the horizon. Raising it raises the required return and can break the funded ratio.")
                    }
                }
                Card("Legacy floor (today's $)", help: Teach.help("requiredReturn")) {
                    SliderRow(value: Binding(get: { household.legacyFloorUsd }, set: { household.legacyFloorUsd = $0 }),
                              range: 0...max(5_000_000, household.legacyFloorUsd), step: 100_000,
                              display: household.legacyFloorUsd > 0 ? Fmt.usd(household.legacyFloorUsd) : "$0 — spend-down")
                    Note("The corpus must END worth at least this. $0 spends it to zero; raise it to fund a perpetual legacy and watch the required return climb on the Required Return tab.")
                }
                // Sample-only demonstration levers — hidden for synthesized plans
                // that carry no single-name concentration or muni position.
                if household.positions.contains(where: { $0.id == "pos_aapl" }) {
                    Card("Concentrated position (AAPL)") {
                        SliderRow(value: positionBinding("pos_aapl"), range: 0...max(600_000, household.positions.first(where: { $0.id == "pos_aapl" })?.marketValueUsd ?? 0), step: 10_000,
                                  display: Fmt.usd(household.positions.first(where: { $0.id == "pos_aapl" })?.marketValueUsd ?? 0))
                        Note("A low-basis single name earmarked to step-up. Push it past 8% of the portfolio to trip the concentration flag.")
                    }
                }
                if household.positions.contains(where: { $0.id == "pos_mub" }) {
                    Card("Move the muni into the IRA") {
                        Toggle(isOn: muniShelteredBinding) {
                            Text("Hold MUB in the tax-deferred IRA").font(.system(size: 14.5))
                        }.tint(Theme.debt)
                        Note("Munis in a sheltered account is a hard error — watch the Constraints tab react.")
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.paper)
    }

    private func spendingBinding(_ idx: Int) -> Binding<Double> {
        Binding(
            get: { household.goals[idx].outflows.first?.amountUsd ?? 0 },
            set: { newVal in
                household.goals[idx].outflows = household.goals[idx].outflows.map { Outflow(year: $0.year, amountUsd: newVal, inflationLinked: $0.inflationLinked) }
            })
    }
    private func positionBinding(_ id: String) -> Binding<Double> {
        Binding(
            get: { household.positions.first(where: { $0.id == id })?.marketValueUsd ?? 0 },
            set: { newVal in if let i = household.positions.firstIndex(where: { $0.id == id }) { household.positions[i].marketValueUsd = newVal } })
    }
    private var muniShelteredBinding: Binding<Bool> {
        Binding(
            get: { household.positions.first(where: { $0.id == "pos_mub" })?.accountId == "acct_ira" },
            set: { on in if let i = household.positions.firstIndex(where: { $0.id == "pos_mub" }) { household.positions[i].accountId = on ? "acct_ira" : "acct_taxable" } })
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

/// A labelled slider with a live monospaced read-out.
struct SliderRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var display: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text(display).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
            }
            Slider(value: $value, in: range, step: step).tint(Theme.ink)
        }
    }
}
