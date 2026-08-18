//  MacroTab.swift
//  WealthPolicyDesk
//
//  The macro-inning readout. Household-independent — the cycle is the same for
//  every client — so it aggregates the dated Seed.macroIndicators board directly.
//  A regime/context surface, not a trade.

import SwiftUI

struct MacroTab: View {
    private var regime: MacroRegime { Engine.macroRegime(Seed.macroIndicators) }

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

        Card("The board — \(r.indicators.count) indicators") {
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
        }

        Card("Signals by category") {
            ForEach(MacroCategory.allCases, id: \.self) { cat in
                let sigs = r.indicators.filter { $0.category == cat }
                if !sigs.isEmpty {
                    Text(cat.rawValue.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.accent).padding(.top, 8)
                    ForEach(sigs) { s in indicatorRow(s) }
                }
            }
        }
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
