//  RequiredReturnTab.swift
//  WealthPolicyDesk

import SwiftUI
import Charts

struct RequiredReturnTab: View {
    let eval: Evaluation
    private var rr: RequiredReturn { eval.requiredReturn }
    private var recon: CMEReconciliation {
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
        return Engine.cmeReconciliation(eval, cme: cme)
    }

    var body: some View {
        Card("Required real return", help: Teach.help("requiredReturn")) {
            HStack(alignment: .top) {
                HeadlineFigure(Fmt.pctBps(rr.requiredRealReturnBps),
                               caption: rr.legacyFloorUsd > 0
                                 ? "to fund the plan AND leave \(Fmt.usdShort(rr.legacyFloorUsd)) (today's $)"
                                 : "to spend the corpus down to zero — no legacy",
                               color: rr.requiredRealReturnBps > 500 ? Theme.debt : Theme.asset)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.pctBps(rr.requiredRealReturnWithFlexibilityBps))
                        .font(.system(size: 27, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                    Text("with goal flexibility").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
            }
            Note("The gap of \(Fmt.bps(rr.requiredRealReturnBps - rr.requiredRealReturnWithFlexibilityBps)) is what deferring and scaling the spending goal buys — for free. Deferring a goal beats taking more risk.", icon: "arrow.down.right", color: Theme.accent)
        }

        Card("Expected vs required — is the market priced to fund this plan?") {
            let rec = recon
            LedgerRow("Required real (after-tax)", Fmt.pctBps(rec.requiredRealBps), color: Theme.ink, bold: true)
            reconRow("Strategic target (net)", rec.netTargetBps, rec.gapTargetBps)
            reconRow("Current holdings (net)", rec.netCurrentBps, rec.gapCurrentBps)
            LedgerRow("Gross expected (target) − fees & tax drag",
                      "\(Fmt.pctBps(rec.target.expectedRealBps)) − \(Fmt.pctBps(rec.frictionDragBps))", color: Theme.muted)
            if rec.unpricedResidualBps > 25 {
                Note("\(Fmt.pctBps(rec.unpricedResidualBps)) of current holdings aren't mapped to a sleeve (e.g. a concentrated stock) and are priced here as US-large equity.", icon: "questionmark.circle", color: Theme.muted)
            }
            Note("Both figures are REAL. \"Expected\" — what the market is priced to deliver on this allocation (Econ → Capital market expectations) — is stated NET of a \(Fmt.pctBps(rec.frictionDragBps)) fund-fee + annual-tax friction dial, so it sits on the same after-tax basis as \"required,\" the rate the corpus must actually compound at after funding its own withdrawal taxes. A gap the market isn't priced to close is closed by saving more, spending less, or deferring a goal (required with flexibility: \(Fmt.pctBps(rec.requiredFlexBps))) — not by reaching for risk the market isn't paying for.", icon: "scalemass")
        }

        Card("After-tax — the tax drag", help: Teach.help("requiredReturn")) {
            LedgerRow("Pre-tax required return", Fmt.pctBps(rr.requiredRealReturnPreTaxBps), color: Theme.muted)
            LedgerRow("After-tax required return", Fmt.pctBps(rr.requiredRealReturnBps), color: Theme.ink, bold: true)
            LedgerRow("Tax drag", Fmt.bpsSigned(rr.requiredRealReturnBps - rr.requiredRealReturnPreTaxBps),
                      color: rr.requiredRealReturnBps > rr.requiredRealReturnPreTaxBps ? Theme.debt : Theme.muted, bold: true)
            Note("The headline number now funds the tax the withdrawals generate too — RMDs, the taxable share of Social Security, and IRMAA (see the Decumulation tab) — not just the spending. That gap is what a pre-tax required return quietly omits.", icon: "percent")
        }

        Card("The legacy claim", help: Teach.help("requiredReturn")) {
            LedgerRow("Spend-down baseline (floor $0)", Fmt.pctBps(rr.spendDownRealReturnBps), color: Theme.ink)
            LedgerRow("Legacy floor", rr.legacyFloorUsd > 0 ? Fmt.usd(rr.legacyFloorUsd) : "$0 — none set", color: rr.legacyFloorUsd > 0 ? Theme.asset : Theme.muted)
            LedgerRow("Required return with the floor", Fmt.pctBps(rr.requiredRealReturnBps), color: Theme.ink, bold: true)
            LedgerRow("Cost of the legacy claim", Fmt.bpsSigned(rr.requiredRealReturnBps - rr.spendDownRealReturnBps), color: rr.requiredRealReturnBps > rr.spendDownRealReturnBps ? Theme.debt : Theme.muted, bold: true)
            Note(rr.legacyFloorUsd > 0
                 ? "The corpus is perpetual, so the plan must leave the floor intact rather than spend to zero. The extra return above is the price of the legacy claim — a price every brokerage statement quietly sets at zero."
                 : "The corpus is being spent to nothing by the horizon: the legacy claim is priced at zero. Raise the legacy-floor lever to fund a perpetual corpus and watch this cost appear.",
                 icon: "infinity", color: rr.legacyFloorUsd > 0 ? Theme.asset : Theme.muted)
        }

        Card("Corpus projection at the required return") {
            Chart(rr.projection) { p in
                AreaMark(x: .value("Year", p.year), y: .value("Balance", p.balanceUsd))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Year", p.year), y: .value("Balance", p.balanceUsd))
                    .foregroundStyle(Theme.accent)
            }
            .chartXScale(domain: (rr.projection.first?.year ?? 2026)...(rr.projection.last?.year ?? 2058))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let y = v.as(Int.self) { Text(verbatim: String(y)) } }
            } }
            .chartYAxis { AxisMarks { v in AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.usdShort(d)) } } } }
            .frame(height: 180)
            Note(rr.legacyFloorUsd > 0
                 ? "The corpus is drawn down to fund net outflows, then held so it ENDS at the \(Fmt.usdShort(rr.legacyFloorUsd)) legacy floor — the perpetual corpus, preserved. External income is netted before the draw."
                 : "The corpus is drawn down to fund net outflows and lands near zero at horizon — the definition of the required return. External income (Social Security, pension, home equity) is netted before the draw.")
        }

        Card("The funding equation") {
            LedgerRow("Current investable assets", Fmt.usd(rr.currentAssetsUsd), color: Theme.asset)
            LedgerRow("+ Future savings (PV)", Fmt.usd(rr.futureSavingsPvUsd), color: Theme.asset)
            LedgerRow("+ External income (PV)", Fmt.usd(rr.externalIncomePvUsd), color: Theme.asset)
            LedgerRow("− Goal liabilities (PV)", Fmt.usd(rr.liabilityPvUsd), color: Theme.debt)
            LedgerRow("Net liability after resources", Fmt.usd(rr.netLiabilityPvUsd), color: Theme.debt, bold: true)
            LedgerRow("Funded ratio", Fmt.pctBps(rr.fundedRatioBps), color: rr.fundedRatioBps >= 10_000 ? Theme.asset : Theme.amber, bold: true)
            Note("PVs use a \(Fmt.pctBps(rr.safeRealRateBps)) safe real rate (TIPS-like) — an observable, not a capital-market forecast. Report the required return first; let assumptions answer how plausible it is.")
        }
    }

    /// One portfolio's expected real return vs the required hurdle, with a verdict chip.
    private func reconRow(_ label: String, _ expected: Bps, _ gap: Bps) -> some View {
        let verdict = CMEReconciliation.verdict(gap)
        let color: Color = verdict == .cushion ? Theme.asset : (verdict == .stretch ? Theme.debt : Theme.amber)
        return HStack(spacing: 8) {
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer()
            Text(Fmt.pctBps(expected)).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
            Text(Fmt.bpsSigned(gap)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(color)
            Text(verdict.rawValue.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2).background(color, in: Capsule())
        }
        .padding(.vertical, 3)
    }
}
