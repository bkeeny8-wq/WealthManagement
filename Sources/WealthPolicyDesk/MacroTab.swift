//  MacroTab.swift
//  WealthPolicyDesk
//
//  The macro-inning readout. Household-independent — the cycle is the same for
//  every client — so it aggregates the dated Seed.macroIndicators board directly.
//  A regime/context surface, not a trade.

import SwiftUI

/// How the Econ-data board is organized. Timing (leading → coincident → lagging)
/// is the default; Category keeps the old 9-group view; Lean is a flat early→late sort.
enum MacroGrouping: String, CaseIterable, Identifiable {
    case timing = "Timing", category = "Category", lean = "Lean"
    var id: String { rawValue }
}

struct MacroTab: View {
    private var regime: MacroRegime { Engine.macroRegime(Seed.macroIndicators) }
    @State private var grouping: MacroGrouping = .timing
    /// Which collapsible groups are expanded (by group title). All start collapsed
    /// so the board opens as the aggregate + three one-line groups — drill in on tap.
    @State private var open: Set<String> = []

    var body: some View {
        let r = regime
        Card("Macro inning") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.phase.label).font(.system(size: 20, weight: .bold, design: .serif)).foregroundStyle(phaseColor(r.phase))
                    Text("Inning \(r.inning) of 9").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("RECESSION ODDS").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.muted)
                    Text(Fmt.pctBps(r.recessionOddsBps))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(r.recessionOddsBps >= 4000 ? Theme.debt : (r.recessionOddsBps >= 2000 ? Theme.amber : Theme.asset))
                }
            }
            cycleBar(r).padding(.top, 4)
            Note(r.headline)
            Note("As of \(r.asOf) · \(r.source). A regime read, not a trade — it conditions the capital-market expectations and which sectors a tilt favors, never the strategic target.", icon: "info.circle", color: Theme.muted)
        }

        Card("Econ data — \(r.indicators.count) indicators") {
            StackBar([
                StackSegment("Early", Double(max(0, r.earlyCount)), Theme.asset),
                StackSegment("Neutral", Double(max(0, r.neutralCount)), Theme.ink.opacity(0.28)),
                StackSegment("Late", Double(max(0, r.lateCount)), Theme.amber),
                StackSegment("Recession", Double(max(0, r.recessionCount)), Theme.debt),
            ])
            HStack(spacing: 14) {
                leanKey("early", r.earlyCount, Theme.asset)
                leanKey("neutral", r.neutralCount, Theme.ink.opacity(0.28))
                leanKey("late", r.lateCount, Theme.amber)
                if r.recessionCount > 0 { leanKey("recession", r.recessionCount, Theme.debt) }
                Spacer()
            }
            .padding(.top, 2)
            LedgerRow("Confidence", r.confidence, color: Theme.ink, bold: true)
            Note("Diffusion aggregation — the importance-weighted balance of early-vs-late leans across the whole board sets the inning, so no single indicator jerks the read. Confidence reflects how much the board agrees.", color: Theme.muted)
            Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule).padding(.vertical, 8)
            Picker("Group by", selection: $grouping) {
                ForEach(MacroGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 2)
            Text(groupingBlurb).font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)

            switch grouping {
            case .timing:
                ForEach(MacroTiming.allCases, id: \.self) { t in
                    let sigs = r.indicators.filter { $0.timing == t }.sorted { $0.importance > $1.importance }
                    groupBox(key: t.rawValue, subtitle: "\(sigs.count) · \(t.blurb)", sigs: sigs)
                }
            case .category:
                ForEach(MacroCategory.allCases, id: \.self) { c in
                    let sigs = r.indicators.filter { $0.category == c }.sorted { $0.importance > $1.importance }
                    if !sigs.isEmpty { groupBox(key: c.rawValue, subtitle: "\(sigs.count) indicators", sigs: sigs) }
                }
            case .lean:
                ForEach(r.indicators.sorted(by: leanSort)) { s in indicatorRow(s) }
            }
        }
    }

    private var groupingBlurb: String {
        switch grouping {
        case .timing:   return "Grouped by cycle timing — leading signals turn first, so a leading group leaning late while coincident still reads steady is the earliest sign of a turn. Rows sorted by weight; tap a group to expand."
        case .category: return "Grouped by category — the nine data families. Rows sorted by weight; tap a group to expand."
        case .lean:     return "Every indicator, flat, sorted by cycle lean (early → late) then weight."
        }
    }

    /// Ascending by lean (early→neutral→late→recession), then heavier weight first.
    private func leanSort(_ a: MacroIndicator, _ b: MacroIndicator) -> Bool {
        let order: [SignalLean: Int] = [.early: 0, .neutral: 1, .late: 2, .recession: 3]
        let la = order[a.lean] ?? 1, lb = order[b.lean] ?? 1
        if la != lb { return la < lb }
        return a.importance > b.importance
    }

    // MARK: collapsible group with its own diffusion bar

    @ViewBuilder private func groupBox(key: String, subtitle: String, sigs: [MacroIndicator]) -> some View {
        let c = leanCounts(sigs)
        let isOpen = open.contains(key)
        VStack(alignment: .leading, spacing: 6) {
            Button { toggle(key) } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.muted).frame(width: 11)
                    Text(key).font(.system(size: 13, weight: .heavy)).foregroundStyle(Theme.accent)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 8)
                    miniDiffusion(c).frame(width: 92, height: 7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(countsLabel(c)).font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.leading, 19)
            if isOpen { ForEach(sigs) { s in indicatorRow(s) } }
        }
        .padding(.top, 8)
    }

    private func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }

    private func leanCounts(_ sigs: [MacroIndicator]) -> (e: Int, n: Int, l: Int, r: Int) {
        var e = 0, n = 0, l = 0, r = 0
        for s in sigs {
            switch s.lean { case .early: e += 1; case .neutral: n += 1; case .late: l += 1; case .recession: r += 1 }
        }
        return (e, n, l, r)
    }

    private func countsLabel(_ c: (e: Int, n: Int, l: Int, r: Int)) -> String {
        var parts = ["\(c.e) early", "\(c.n) neutral", "\(c.l) late"]
        if c.r > 0 { parts.append("\(c.r) recession") }
        return parts.joined(separator: " · ")
    }

    private func miniDiffusion(_ c: (e: Int, n: Int, l: Int, r: Int)) -> some View {
        let total = max(1, c.e + c.n + c.l + c.r)
        return GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                Rectangle().fill(Theme.asset).frame(width: w * CGFloat(c.e) / CGFloat(total))
                Rectangle().fill(Theme.ink.opacity(0.22)).frame(width: w * CGFloat(c.n) / CGFloat(total))
                Rectangle().fill(Theme.amber).frame(width: w * CGFloat(c.l) / CGFloat(total))
                Rectangle().fill(Theme.debt).frame(width: w * CGFloat(c.r) / CGFloat(total))
            }
        }
        .clipShape(Capsule())
    }

    private func cycleBar(_ r: MacroRegime) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule).frame(height: 8)
                    Circle().fill(phaseColor(r.phase)).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Theme.paper, lineWidth: 2))
                        .offset(x: max(0, min(w - 16, w * CGFloat(r.cycleScore) / 100 - 8)))
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                Text("Early").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer(); Text("Mid").font(.system(size: 10)).foregroundStyle(Theme.muted); Spacer()
                Text("Late").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func leanKey(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(n) \(label)").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.muted)
        }
    }

    private func indicatorRow(_ s: MacroIndicator) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(s.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(s.reading).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                Text(s.lean.label.uppercased()).font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(leanColor(s.lean), in: Capsule())
            }
            Text(s.descriptor).font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func phaseColor(_ p: CyclePhase) -> Color {
        switch p {
        case .early: return Theme.asset
        case .mid: return Theme.accent
        case .late: return Theme.amber
        case .recession: return Theme.debt
        }
    }
    private func leanColor(_ l: SignalLean) -> Color {
        switch l {
        case .early: return Theme.asset
        case .neutral: return Theme.muted
        case .late: return Theme.amber
        case .recession: return Theme.debt
        }
    }
}
