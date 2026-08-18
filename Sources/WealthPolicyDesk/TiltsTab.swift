//  TiltsTab.swift
//  WealthPolicyDesk
//
//  The tactical-tilt layer for THIS client. Tilts come from the firm-wide Sentiment
//  board (Econ), are staged per client on Planning, and here show as governed bets:
//  budget usage, validation, the thesis + review on each, and the strategic → tactical
//  target they produce. Deviations are funded within the same role, so the risk level
//  the forecast-free solver set is never moved — only the composition.

import SwiftUI

struct TiltsTab: View {
    let eval: Evaluation
    private var tilts: [TacticalTiltAction] { eval.household.tacticalTilts }
    private var budget: TiltPolicy { Seed.tiltPolicy }
    private var usedBps: Bps { tilts.reduce(0) { $0 + abs($1.deviationBps) } }
    private var tiltedRows: [AllocationRow] { eval.allocation.filter { $0.targetBps != $0.strategicTargetBps } }

    var body: some View {
        let tiltFindings = eval.findings.filter { $0.module == .tilt && $0.ruleId.hasPrefix("tactical_") }

        Card("The tactical layer is small by design", help: Teach.help("tilts")) {
            Note("The weakest-evidence component, so it is budgeted: a capped total deviation, a mandatory thesis, and a review date on every tilt. Tilts come from the firm-wide Sentiment board (Econ → Sentiment) and are staged per client on the Planning tab; they deviate the tactical target within the same role, so the equity/bond risk level is never moved — only the composition.")
            HStack(spacing: 8) {
                StatTile("Active tilts", "\(tilts.count)", sub: "sentiment-sourced", color: Theme.ink)
                StatTile("Total active bet", Fmt.pctBps(usedBps), sub: "of \(Fmt.pctBps(budget.maxTotalAbsoluteDeviationBps))",
                         color: usedBps > budget.maxTotalAbsoluteDeviationBps ? Theme.debt : Theme.asset)
            }
        }

        if tilts.isEmpty {
            Card("No tactical tilts") {
                Note("No governed tilts on this client yet. Open Econ → Sentiment for the current candidates, then stage one on the Planning tab — it will carry the candidate's thesis and a review date, and move the tactical target within budget.", icon: "dial.medium", color: Theme.muted)
            }
        } else {
            Card(tiltFindings.isEmpty ? "Validation — compliant" : "Validation — issues") {
                if tiltFindings.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(Theme.asset)
                        Text("Every tilt passes: within the total budget, under the single-tilt cap, and carrying a written thesis.")
                            .font(.system(size: 13.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(tiltFindings) { FindingCard($0) }
                }
            }

            Card("Active tilts") {
                ForEach(tilts) { t in tiltCard(t) }
            }

            Card("Effect on the target") {
                ForEach(tiltedRows) { r in
                    let dev = r.targetBps - r.strategicTargetBps
                    LedgerRow(r.label, "\(Fmt.pctBps(r.strategicTargetBps)) → \(Fmt.pctBps(r.targetBps))",
                              color: dev >= 0 ? Theme.asset : Theme.debt)
                }
                Note("Strategic → tactical target per sleeve. Each tilt is funded pro-rata from the other sleeves of its role, so these deviations net to zero within equity (or within bonds) — the risk budget is untouched.", color: Theme.muted)
            }
        }
    }

    private func tiltCard(_ t: TacticalTiltAction) -> some View {
        let ow = t.deviationBps >= 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(sleeveLabel(t.sleeveId)) \(Fmt.bpsSigned(t.deviationBps))")
                    .font(.system(size: 16.5, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                Spacer()
                Text(ow ? "OVERWEIGHT" : "UNDERWEIGHT").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(ow ? Theme.asset : Theme.debt, in: Capsule())
            }
            Text("from “\(t.sourceName)” (Sentiment)").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            if !t.thesis.isEmpty {
                Text(t.thesis).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            if let r = t.reviewDate {
                Text("review by \(r.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.amber)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
    }

    private func sleeveLabel(_ id: String) -> String { Seed.legacyPolicy.sleeves.first { $0.id == id }?.label ?? id }
}
