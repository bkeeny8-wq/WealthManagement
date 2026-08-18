//  MacroTab.swift
//  WealthPolicyDesk
//
//  The macro-inning readout. Household-independent — the cycle is the same for
//  every client — so it reads the dated Seed.currentMacro snapshot directly.
//  A regime/context surface, not a trade: it will condition expectations and
//  tilts downstream, never the forecast-free strategic target.

import SwiftUI

struct MacroTab: View {
    private var regime: MacroRegime { Engine.macroRegime(Seed.currentMacro) }

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

        Card("Signals — what's driving the read") {
            ForEach(signalCategories, id: \.self) { cat in
                let sigs = r.signals.filter { category(of: $0.name) == cat }
                if !sigs.isEmpty {
                    Text(cat.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.accent)
                        .padding(.top, 8)
                    ForEach(sigs) { s in signalRow(s) }
                }
            }
            Note("Every input is observable and shown with its lean, so the inning is auditable — no black box. The read balances a strong real economy against stretched assets; late-leaning signals push the cycle later, and the Sahm trigger, an ISM collapse, or a market rollover flips it to recession.", color: Theme.muted)
        }
    }

    // MARK: cycle position bar (0 = early … 100 = late)

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
                Spacer()
                Text("Mid").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                Text("Late").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func signalRow(_ s: MacroSignal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(s.reading).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                Text(s.lean.label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(leanColor(s.lean), in: Capsule())
            }
            Text(s.note).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private let signalCategories = ["Growth & activity", "Labor", "Rates & policy", "Credit", "Equity & market"]
    private func category(of name: String) -> String {
        let n = name.lowercased()
        if n.contains("ism") || n.contains("activity") { return "Growth & activity" }
        if n.contains("sahm") || n.contains("labor") || n.contains("claims") { return "Labor" }
        if n.contains("curve") || n.contains("policy rate") { return "Rates & policy" }
        if n.contains("credit") { return "Credit" }
        return "Equity & market"
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
