//  TiltsTab.swift
//  WealthPolicyDesk

import SwiftUI

struct TiltsTab: View {
    let eval: Evaluation
    private var tp: TiltPolicy { Seed.tiltPolicy }
    private var budget: LayerBudget { Seed.layerBudget }

    private var tacticalValue: Usd { eval.household.positions.filter { $0.layer == .tactical }.reduce(0) { $0 + $1.marketValueUsd } }
    private var equityValue: Usd { eval.household.positions.filter { Engine.isEquity($0) }.reduce(0) { $0 + $1.marketValueUsd } }

    var body: some View {
        let tiltFindings = eval.findings.filter { $0.module == .tilt }
        let tacticalOfEquity = equityValue > 0 ? (tacticalValue / equityValue).bps : 0
        let tacticalOfPortfolio = eval.household.portfolioValueUsd > 0 ? (tacticalValue / eval.household.portfolioValueUsd).bps : 0

        Card("The tactical layer is small by design", help: Teach.help("tilts")) {
            Note("This is the weakest-evidence component in the system, so it is budgeted accordingly: capped share, capped concurrent tilts, a rolling cost budget, and a forced review date on every position.")
            HStack(spacing: 8) {
                StatTile("Active tilts", "\(tp.activeTilts.count)/\(budget.maxConcurrentTilts)", sub: "Concurrent cap", color: tp.activeTilts.count <= budget.maxConcurrentTilts ? Theme.asset : Theme.debt)
                StatTile("Total active bet", Fmt.bps(tp.activeTilts.reduce(0) { $0 + abs($1.deviationBps) }), sub: "of \(Fmt.bps(tp.maxTotalAbsoluteDeviationBps))", color: Theme.ink)
            }
        }

        Card("Layer budget") {
            meter("Tactical share of equity", tacticalOfEquity, budget.maxTacticalShareOfEquityBps)
            meter("Tactical share of portfolio", tacticalOfPortfolio, budget.maxTacticalShareOfPortfolioBps)
            LedgerRow("Annual cost budget", Fmt.bps(budget.annualCostBudgetBps), color: Theme.ink)
            LedgerRow("Restricted to", tp.restrictToTreatments.map { $0.short }.joined(separator: ", "), color: Theme.muted)
        }

        Card(tiltFindings.isEmpty ? "Validation — compliant" : "Validation — issues") {
            if tiltFindings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(Theme.asset)
                    Text("All active tilts pass: within budget, paired with offsets, thesis present, review dates current, sheltered accounts only.")
                        .font(.system(size: 13.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(tiltFindings) { FindingCard($0) }
            }
        }

        Card("Active tilts") {
            ForEach(tp.activeTilts) { t in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("\(nodeLabel(t)) \(Fmt.bpsSigned(t.deviationBps))")
                            .font(.system(size: 16.5, weight: .bold, design: .serif)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(t.funding.label + (t.offsetNodeId != nil ? " · \(offsetLabel(t))" : ""))
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                    Text(t.thesis).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("opened \(t.openedAt)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("review by \(t.reviewBy)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.amber)
                    }
                    if !t.acknowledgedCrossExposure.isEmpty {
                        Note("Acknowledged cross-exposure: " + t.acknowledgedCrossExposure.joined(separator: "; "), icon: "arrow.triangle.branch", color: Theme.muted)
                    }
                }
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.rule))
            }
        }
    }

    private func meter(_ label: String, _ value: Bps, _ cap: Bps) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 14)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Fmt.pctBps(value)) / \(Fmt.pctBps(cap))").font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(value > cap ? Theme.debt : Theme.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.rule.opacity(0.5)).frame(height: 6)
                    Capsule().fill(value > cap ? Theme.debt : Theme.asset)
                        .frame(width: min(1, Double(value) / Double(max(1, cap))) * geo.size.width, height: 6)
                }
            }.frame(height: 8)
        }
        .padding(.vertical, 5)
    }
    private func nodeLabel(_ t: Tilt) -> String { Sector(rawValue: t.nodeId)?.label ?? t.nodeId }
    private func offsetLabel(_ t: Tilt) -> String { t.offsetNodeId.flatMap { Sector(rawValue: $0)?.label } ?? (t.offsetNodeId ?? "") }
}
