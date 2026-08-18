//  FrontierTab.swift
//  WealthPolicyDesk
//
//  The efficient-frontier desk tab. Volatility across the bottom, expected real
//  return up the side; the curve is the solver's own portfolios priced by the CME;
//  the forecast-free constraints (required return, tolerance σ, capacity σ) and the
//  client's own portfolios sit on top. One glance answers: inside the tolerable-σ
//  band, does the curve reach the required-return line?

import SwiftUI
import Charts

struct FrontierTab: View {
    let eval: Evaluation
    @State private var showCurve = true

    private var cme: CapitalMarketSet {
        Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
    }
    private var chart: FrontierChart { Engine.frontier(eval, cme: cme) }

    var body: some View {
        let f = chart
        Card("Efficient frontier") {
            Note("Risk (volatility) across the bottom, expected REAL return up the side. The curve is the app's own portfolios — the forecast-free solver swept from low to high equity, alts a fixed budget, bonds the residual — priced by the capital-market expectations (Econ tab). On it sit the forecast-free things the plan brings: what it NEEDS (the required-return line) and what the client can stomach and afford (the tolerance and capacity σ lines). We never optimize the weights to the forecast; we price the real menu.")
            Toggle("Show the market frontier (CMA overlay)", isOn: $showCurve)
                .font(.system(size: 13, weight: .semibold)).tint(Theme.accent).padding(.vertical, 2)
            frontierChart(f).frame(height: 300)
            legend(f)
        }

        Card("Where the plan sits") {
            verdict(f).padding(.bottom, 4)
            LedgerRow("Target portfolio", "\(pct(f.target.equityBps)) eq · σ \(pct(f.target.volBps)) · exp \(pct(f.target.expRealBps))", color: Theme.ink)
            LedgerRow("Current holdings", "\(pct(f.current.equityBps)) eq · σ \(pct(f.current.volBps)) · exp \(pct(f.current.expRealBps))", color: Theme.muted)
            if f.toleranceStated {
                LedgerRow("Tolerance", "≤ \(pct(f.toleranceDrawdownBps)) drawdown → σ \(pct(f.toleranceVolBps))", color: Theme.amber)
            } else {
                LedgerRow("Tolerance", "not on file", color: Theme.muted)
            }
            LedgerRow("Capacity", "\(pct(f.capacityEquityBps)) equity → σ \(pct(f.capacityVolBps))", color: Theme.muted)

            if f.targetExceedsToleranceBps > 100 {
                Note("The solved target's modeled drawdown (\(pct(f.target.drawdownBps))) sits above the stated tolerance (\(pct(f.toleranceDrawdownBps))) — capacity or a liquidity floor is holding equity here, not tolerance.", icon: "exclamationmark.triangle", color: Theme.amber)
            }
            toleranceNote(f)
        }
    }

    // MARK: verdict

    @ViewBuilder private func verdict(_ f: FrontierChart) -> some View {
        if !f.toleranceStated {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tolerance not on file").font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(Theme.muted)
                    Text("complete the risk questionnaire to place the plan against a drawdown budget")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        } else if !f.hasTolerableBand {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Below the floor").font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(Theme.debt)
                    Text("even the most defensive portfolio the solver builds models ~\(pct(f.minDrawdownBps)) drawdown — above the stated \(pct(f.toleranceDrawdownBps)) limit, so no tolerable equity level exists")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        } else {
            let ok = f.meetsRequiredWithinTolerance
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ok ? "Reachable" : "A stretch")
                        .font(.system(size: 22, weight: .bold, design: .serif)).foregroundStyle(ok ? Theme.asset : Theme.debt)
                    Text(ok ? "the market reaches the required return inside the tolerable band"
                            : "no tolerable portfolio is priced to reach the required return")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("REACHABLE vs NEEDED").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.muted)
                    Text("\(pct(f.reachableWithinToleranceBps ?? 0)) vs \(pct(f.requiredRealBps))")
                        .font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(ok ? Theme.asset : Theme.debt)
                }
            }
        }
    }

    @ViewBuilder private func toleranceNote(_ f: FrontierChart) -> some View {
        if f.toleranceStated, let fte = f.frontierToleranceEquityBps {
            let flat = f.flatToleranceEquityBps
            let tail = fte >= flat
                ? "Diversification lets more risk assets ride under the same drawdown."
                : "The 3σ model prices every sleeve's own volatility — including the alts, credit, and commodities in the defensive half — so it reads MORE conservative than the naive equity-only 2× rule."
            Note("Frontier-derived tolerance equity: the highest-equity portfolio whose modeled drawdown stays inside the stated limit is \(pct(fte)) equity — the ceiling the solver now binds to — versus \(pct(flat)) from the old flat 2× rule. \(tail)", icon: "info.circle", color: Theme.muted)
        } else if f.toleranceStated {
            Note("The stated \(pct(f.toleranceDrawdownBps)) drawdown limit sits below the menu's ~\(pct(f.minDrawdownBps)) floor, so no equity level is 'tolerable' — the flat 2× rule would have claimed \(pct(f.flatToleranceEquityBps)) equity, which the diversification-aware model rejects.", icon: "info.circle", color: Theme.muted)
        }
    }

    // MARK: chart

    private func frontierChart(_ f: FrontierChart) -> some View {
        let vols = f.curve.map { d($0.volBps) } + [d(f.toleranceVolBps), d(f.capacityVolBps), d(f.target.volBps), d(f.current.volBps)]
        let rets = f.curve.map { d($0.expRealBps) } + [d(f.requiredRealBps), d(f.target.expRealBps), d(f.current.expRealBps)]
        let xMax = (vols.max() ?? 20) * 1.12
        let yMin = min(0, rets.min() ?? 0)
        let yMax = (rets.max() ?? 5) + 0.4
        return Chart {
            if showCurve {
                ForEach(f.curve) { p in
                    LineMark(x: .value("σ", d(p.volBps)), y: .value("Return", d(p.expRealBps)))
                        .foregroundStyle(Theme.accent)
                        .interpolationMethod(.catmullRom)
                }
            }
            RuleMark(y: .value("Required", d(f.requiredRealBps)))
                .foregroundStyle(Theme.debt.opacity(0.8)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                .annotation(position: .top, alignment: .leading) {
                    Text("required \(pct(f.requiredRealBps))").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.debt)
                }
            if f.toleranceStated {
                RuleMark(x: .value("Tolerance σ", d(f.toleranceVolBps)))
                    .foregroundStyle(Theme.amber.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("tolerance").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.amber)
                    }
            }
            RuleMark(x: .value("Capacity σ", d(f.capacityVolBps)))
                .foregroundStyle(Theme.muted.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .bottom, alignment: .center) {
                    Text("capacity").font(.system(size: 9)).foregroundStyle(Theme.muted)
                }
            PointMark(x: .value("σ", d(f.target.volBps)), y: .value("Return", d(f.target.expRealBps)))
                .foregroundStyle(Theme.asset).symbolSize(170)
                .annotation(position: .bottomTrailing) { Text("target").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.asset) }
            PointMark(x: .value("σ", d(f.current.volBps)), y: .value("Return", d(f.current.expRealBps)))
                .foregroundStyle(Theme.ink.opacity(0.45)).symbolSize(90)
                .annotation(position: .topLeading) { Text("current").font(.system(size: 9)).foregroundStyle(Theme.muted) }
        }
        .chartXScale(domain: 0...xMax)
        .chartYScale(domain: yMin...yMax)
        .chartXAxisLabel("Volatility (σ)", alignment: .center)
        .chartYAxisLabel("Expected real return")
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in
            AxisGridLine(); AxisTick()
            AxisValueLabel { if let x = v.as(Double.self) { Text(verbatim: "\(Int(x))%") } }
        } }
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in
            AxisGridLine(); AxisTick()
            AxisValueLabel { if let y = v.as(Double.self) { Text(verbatim: String(format: "%.0f%%", y)) } }
        } }
    }

    private func legend(_ f: FrontierChart) -> some View {
        HStack(spacing: 14) {
            legendKey("frontier", Theme.accent, line: true)
            legendKey("target", Theme.asset, line: false)
            legendKey("required", Theme.debt, line: true)
            if f.toleranceStated { legendKey("tolerance", Theme.amber, line: true) }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func legendKey(_ label: String, _ color: Color, line: Bool) -> some View {
        HStack(spacing: 4) {
            (line ? AnyView(RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 3))
                  : AnyView(Circle().fill(color).frame(width: 8, height: 8)))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func d(_ bps: Bps) -> Double { Double(bps) / 100.0 }
    private func pct(_ bps: Bps) -> String { Fmt.pctBps(bps) }
}
