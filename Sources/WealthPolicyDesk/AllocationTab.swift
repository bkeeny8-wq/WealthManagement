//  AllocationTab.swift
//  WealthPolicyDesk

import SwiftUI

struct AllocationTab: View {
    let eval: Evaluation

    private var sleeveColor: [String: Color] {
        ["us_large_core": Theme.accent, "us_sector_tilt": Theme.amber, "us_mid_small": Theme.accent.opacity(0.6),
         "intl_developed": Theme.asset, "emerging": Theme.asset.opacity(0.6), "real_assets": Theme.debt.opacity(0.6),
         "fixed_income_liquid": Theme.ink.opacity(0.55)]
    }

    var body: some View {
        Card("Allocation is an output", help: Teach.help("allocation")) {
            StackBar(eval.allocation.filter { $0.currentBps > 0 }.map {
                StackSegment($0.label, Double($0.currentBps), sleeveColor[$0.sleeveId] ?? Theme.muted)
            })
            Note("What you see is the residue of funding the claims — never a target. The blended split is an output; nobody sets 60/40 and works backward.")
        }

        Card("Sleeves — current vs target") {
            ForEach(eval.allocation) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(Fmt.pctBps(row.currentBps)) / \(Fmt.pctBps(row.targetBps))")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(row.status == .outerBreach ? Theme.debt : (row.status == .innerBreach ? Theme.amber : Theme.ink))
                    }
                    DriftMeter(driftBps: row.driftBps, innerBps: row.innerBandBps, outerBps: row.outerBandBps)
                    HStack {
                        Text(statusText(row)).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("drift \(Fmt.bpsSigned(row.driftBps))").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 6)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            }
        }

        Card("Alternatives — sized by function, not product", help: Teach.help("alts")) {
            ForEach(eval.altSizing) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.fn.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(Fmt.pctBps(row.currentBps)) / \(Fmt.pctBps(row.targetBps))")
                            .font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: row.eligible ? "checkmark.seal" : "arrow.uturn.down")
                            .font(.system(size: 11.5)).foregroundStyle(row.eligible ? Theme.asset : Theme.amber)
                        Text(row.eligible ? row.chosenWrapperLabel : "no wrapper at tier → \(fallbackLabel(row.fallbackSleeveId))")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                        Spacer()
                        if row.eligible {
                            Text("\(Fmt.bps(row.wrapperFeeBps))")
                                .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(row.feeOverBudget ? Theme.debt : Theme.muted)
                        }
                    }
                }
                .padding(.vertical, 6)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            }
        }

        ladderCard
    }

    private var ladderCard: some View {
        let l = eval.ladder
        return Card("Ladder — sized to liability, not a percentage", help: Teach.help("ladder")) {
            LedgerRow("Years pre-funded", "\(l.yearsCovered)y", color: Theme.ink)
            LedgerRow("Net annual outflow", Fmt.usd(l.netAnnualOutflowUsd), color: Theme.ink)
            LedgerRow("Ladder size", Fmt.usd(l.ladderSizeUsd), color: Theme.asset)
            LedgerRow("Rebalance reserve", Fmt.usd(l.rebalanceReserveUsd), color: Theme.asset)
            LedgerRow("Required daily-liquid", Fmt.usd(l.requiredLiquidUsd), color: Theme.ink, bold: true)
            LedgerRow("Available daily-liquid", Fmt.usd(l.availableDailyLiquidUsd), color: l.covered ? Theme.asset : Theme.debt, bold: true)
            Note(l.covered ? "Covered: daily-liquid assets exceed the ladder + reserve + a year of outflows." : "SHORT: daily-liquid assets do not cover the floor.", icon: l.covered ? "checkmark.circle" : "exclamationmark.triangle", color: l.covered ? Theme.asset : Theme.debt)
        }
    }

    private func statusText(_ r: AllocationRow) -> String {
        switch r.status {
        case .within: return "within band"
        case .innerBreach: return "inner band — flag"
        case .outerBreach: return "outer band — mandatory correction"
        }
    }
    private func fallbackLabel(_ id: String) -> String { eval.legacyPolicy.sleeve(id)?.label ?? id }
}
