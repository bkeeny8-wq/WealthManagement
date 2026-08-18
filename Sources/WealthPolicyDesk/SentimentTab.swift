//  SentimentTab.swift
//  WealthPolicyDesk
//
//  The equity & bond tactical-sentiment board. Household-independent — reads the
//  dated Seed.tacticalTilts catalog and surfaces overweight/underweight candidates
//  for the BUDGETED tilt layer. Never sets the forecast-free strategic target.

import SwiftUI

struct SentimentTab: View {
    private var tilts: [TacticalTilt] { Seed.tacticalTilts }
    private var equity: [TacticalTilt] { tilts.filter { $0.group.contains("Equity") } }
    private var bonds: [TacticalTilt] { tilts.filter { $0.group.lowercased().contains("income") } }

    var body: some View {
        Card("Tactical sentiment") {
            Note("Equity and bond exposures scored on Value · Momentum · Sentiment · Cycle-fit → an overweight / lean / neutral / underweight stance (a strong ±3 composite is a governed tilt; ±1–2 is a lean to watch). Cycle-fit is fed by the Macro inning, so the two engines move together. These are candidates for the BUDGETED tilt layer — a deviation cap, a mandatory thesis, a review date — never the forecast-free strategic target. Tactical timing is weak-evidence; the discipline is the product.")
        }

        sentimentCard("Equity sentiment", broad: tilts.first { $0.name.contains("Equity risk") }, set: equity)
        sentimentCard("Bond sentiment", broad: tilts.first { $0.name.contains("Bond sentiment") }, set: bonds)

        Card("Strongest tilts") {
            let ow = tilts.filter { $0.stance == .overweight }.sorted { $0.netScore > $1.netScore }
            let uw = tilts.filter { $0.stance == .underweight }.sorted { $0.netScore < $1.netScore }
            if !ow.isEmpty {
                Text("OVERWEIGHT").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.asset)
                ForEach(ow) { tiltRow($0) }
            }
            if !uw.isEmpty {
                Text("UNDERWEIGHT").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.debt).padding(.top, 8)
                ForEach(uw) { tiltRow($0) }
            }
            Note("A strong ±3 composite earns a governed overweight/underweight; a ±1–2 lean is a candidate to watch, not yet an action. Sector tilts can be rotated in on the Planning tab (into the sector's SPDR); style, region, and bond tilts surface here as budgeted-tilt candidates but aren't wired into Planning yet.", color: Theme.muted)
        }

        Card("The board — \(tilts.count) candidates") {
            ForEach(groupOrder, id: \.self) { g in
                let items = tilts.filter { $0.group == g }
                if !items.isEmpty {
                    Text(g.uppercased()).font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.accent).padding(.top, 8)
                    ForEach(items) { tiltRow($0) }
                }
            }
        }
    }

    private var groupOrder: [String] {
        let all = Set(tilts.map { $0.group })
        let pref = ["Equity — sectors", "Equity — style/region", "Fixed income"]
        return pref.filter { all.contains($0) } + all.subtracting(pref).sorted()
    }

    private func sentimentCard(_ title: String, broad: TacticalTilt?, set: [TacticalTilt]) -> some View {
        let agg = Engine.tiltAggregate(set)
        let ows = set.filter { $0.stance == .overweight }.sorted { $0.netScore > $1.netScore }.prefix(3).map { $0.name }
        let uws = set.filter { $0.stance == .underweight }.sorted { $0.netScore < $1.netScore }.prefix(3).map { $0.name }
        return Card(title) {
            HStack {
                Text(leanWord(agg.net)).font(.system(size: 18, weight: .bold, design: .serif)).foregroundStyle(leanColor(agg.net))
                Spacer()
                Text(String(format: "avg tilt %+.1f", agg.net)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            if let b = broad { dimLine(b) }
            if !ows.isEmpty {
                Text("Overweight — \(ows.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(Theme.asset).fixedSize(horizontal: false, vertical: true)
            }
            if !uws.isEmpty {
                Text("Underweight — \(uws.joined(separator: ", "))").font(.system(size: 12)).foregroundStyle(Theme.debt).fixedSize(horizontal: false, vertical: true)
            }
            if let b = broad { Note(b.thesis, color: Theme.muted) }
        }
    }

    private func tiltRow(_ t: TacticalTilt) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(t.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(t.ticker).font(.system(size: 10, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.muted)
                Spacer()
                Text(String(format: "%+d", t.netScore)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.muted)
                Text(t.stance.short).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(stanceColor(t.stance), in: Capsule())
            }
            dimLine(t)
            Text(t.thesis).font(.system(size: 10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func dimLine(_ t: TacticalTilt) -> some View {
        HStack(spacing: 12) {
            ForEach(t.dimensions) { d in
                HStack(spacing: 2) {
                    Text(String(d.name.prefix(1))).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                    Text(String(format: "%+d", d.score)).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(scoreColor(d.score))
                }
            }
            Spacer()
            Text(t.conviction).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    private func leanWord(_ net: Double) -> String {
        if net >= 1.5 { return "Overweight" }
        if net >= 0.5 { return "Mild overweight" }
        if net <= -1.5 { return "Underweight" }
        if net <= -0.5 { return "Mild underweight" }
        return "Neutral"
    }
    /// The gauge word and its color share one classification of the same avg-tilt
    /// number — so a "Mild overweight" headline can never render in neutral gray.
    private func leanColor(_ net: Double) -> Color {
        net >= 0.5 ? Theme.asset : (net <= -0.5 ? Theme.debt : Theme.muted)
    }
    private func stanceColor(_ s: TiltStance) -> Color {
        switch s {
        case .overweight:  return Theme.asset
        case .leanOver:    return Theme.asset.opacity(0.55)
        case .neutral:     return Theme.muted
        case .leanUnder:   return Theme.debt.opacity(0.55)
        case .underweight: return Theme.debt
        }
    }
    private func scoreColor(_ n: Int) -> Color { n > 0 ? Theme.asset : (n < 0 ? Theme.debt : Theme.muted) }
}
