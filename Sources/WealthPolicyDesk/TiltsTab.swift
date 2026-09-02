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
    var onSetStyle: (USEquityStyleTilt) -> Void = { _ in }
    private var tilts: [TacticalTiltAction] { eval.household.tacticalTilts }
    private var budget: TiltPolicy { Seed.tiltPolicy }
    private var usedBps: Bps { tilts.reduce(0) { $0 + abs($1.deviationBps) } }
    private var tiltedRows: [AllocationRow] { eval.allocation.filter { $0.targetBps != $0.strategicTargetBps } }

    var body: some View {
        let tiltFindings = eval.findings.filter { $0.module == .tilt && $0.ruleId.hasPrefix("tactical_") }

        styleCard

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

    // MARK: - US equity value/growth style overlay

    private var styleCard: some View {
        let st = eval.household.equityStyle
        let fx = Engine.factorExposure(eval.household)
        let valueTilt = fx.tilts.first { $0.axis == .value }?.tilt ?? 0
        return Card("US equity style — value ⇄ growth") {
            Note("Tilt each US size bucket toward value or growth. This is a COMPOSITION change only — it swaps which style ETF is held (e.g. VOO → VTV value or VUG growth), never how much equity you hold or the risk level the solver set. It flows into the factor look-through and the rebalancer.", icon: "dial.medium")
            ForEach(USSizeBucket.allCases, id: \.self) { b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(b.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(b.ticker(for: st.style(for: b)))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(st.style(for: b) == .blend ? Theme.muted : Theme.accent)
                    }
                    ChoiceChips(EquityStyle.allCases.map { ($0, $0.label) }, selection: st.style(for: b)) { newStyle in
                        var ns = st; ns.set(newStyle, for: b); onSetStyle(ns)
                    }
                }
                .padding(.vertical, 7)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            }
            LedgerRow("Net value/growth posture", stylePostureText(valueTilt),
                      color: abs(valueTilt) < 0.05 ? Theme.muted : (valueTilt > 0 ? Theme.asset : Theme.accent), bold: true)
            LedgerRow("Style set", st.summary, color: Theme.muted)
            if !st.isNeutral {
                Button { onSetStyle(USEquityStyleTilt()) } label: {
                    Label("Reset to cap-weighted blend", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain).padding(.top, 4)
            }
        }
    }

    /// The value-axis reading as a plain lean (the factor look-through's value(+)/growth(−) axis).
    private func stylePostureText(_ t: Double) -> String {
        if abs(t) < 0.05 { return "Cap-weighted — no net value/growth bet" }
        let mag = String(format: "%.2f", abs(t))
        return t > 0 ? "Value-leaning (+\(mag))" : "Growth-leaning (+\(mag))"
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
