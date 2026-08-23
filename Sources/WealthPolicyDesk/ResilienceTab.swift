//  ResilienceTab.swift
//  WealthPolicyDesk
//
//  How fragile is the plan? The required return is a single average; this stresses
//  it two ways with no market forecast — a miss on the realized return, and the
//  same average delivered in a historically bad ORDER (sequence-of-returns risk).

import SwiftUI

struct ResilienceTab: View {
    let eval: Evaluation
    private var res: ResilienceAnalysis { eval.resilience }

    private var shortfall: ShortfallEstimate {
        let cme = Engine.capitalMarketExpectations(Seed.macroIndicators, regime: Engine.macroRegime(Seed.macroIndicators))
        return Engine.shortfallEstimate(eval, cme: cme)
    }

    private var verdict: (label: String, color: Color) {
        if res.stressCount == 0 { return ("—", Theme.muted) }
        if res.stresses.contains(where: { !$0.survives }) { return ("Fragile", Theme.debt) }
        if res.stresses.contains(where: { !$0.meetsFloor }) { return ("Exposed", Theme.amber) }
        return ("Resilient", Theme.asset)
    }

    private func shortfallColor(_ b: ShortfallBand) -> Color {
        switch b {
        case .low: return Theme.asset
        case .moderate: return Theme.ink
        case .elevated: return Theme.amber
        case .high: return Theme.debt
        }
    }

    var body: some View {
        if res.stresses.isEmpty {
            Card("Resilience") { Note("No plan horizon to stress yet — set a retirement age, spending, and a portfolio.") }
        } else {
            Card("Resilience — how the plan holds under stress", help: Teach.help("requiredReturn")) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verdict.label).font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(verdict.color)
                    Text("survives \(res.stressesSurvived) of \(res.stressCount) bad-sequence stresses")
                        .font(.system(size: 15)).foregroundStyle(Theme.muted)
                }
                Note("The required return is the average the plan needs. These stresses hold that average fixed and only change what a single number can't see: whether a bad miss, or a bad ORDER of returns, breaks the plan. No market forecast — the sequences are historical patterns re-centered to your own required return and scaled by equity exposure.")
            }

            shortfallCard

            StatGrid([
                StatTile("Required return", Fmt.pctBps(res.requiredRealReturnBps), sub: "the plan's average", color: Theme.ink),
                StatTile("Max safe spend", Fmt.usdShort(res.maxSafeSpendUsd), sub: "survives the worst stress", color: Theme.ink),
                StatTile("Spending headroom", Fmt.pctBps(res.spendHeadroomBps), sub: res.spendHeadroomBps < 0 ? "over the safe line" : "cushion", color: res.spendHeadroomBps < 0 ? Theme.debt : Theme.asset),
                StatTile("Worst case", res.stresses.compactMap { $0.depletionAge }.min().map { "depletes \($0)" } ?? "no depletion", sub: "earliest run-out age", color: res.stresses.contains { !$0.survives } ? Theme.debt : Theme.asset),
            ])

            Card("Sequence-of-returns risk") {
                ForEach(res.stresses) { s in stressRow(s) }
                Note("Same average return, worse order. A big loss in the first years of retirement — while you're drawing down — does damage a late loss can't, because there's less corpus left to recover. This is the risk a required-return number is silent on.", icon: "arrow.down.right")
            }

            Card("Return sensitivity") {
                Note("If the realized return misses the required \(Fmt.pctBps(res.requiredRealReturnBps)):")
                ForEach(res.sensitivities) { s in
                    LedgerRow(sensitivityLabel(s),
                              s.depletionAge.map { "depletes at \($0)" } ?? "ends " + Fmt.usdShort(s.terminalBalanceUsd),
                              color: s.depletionAge != nil ? Theme.debt : (s.terminalBalanceUsd >= res.legacyFloorUsd ? Theme.asset : Theme.amber))
                }
            }
        }
    }

    private var shortfallCard: some View {
        let s = shortfall
        // Expected (CME) is now NET of a friction dial (fund fees + annual taxes) and
        // required is after-tax, so the margin sits on one basis. A thin buffer remains
        // only for CME forecast uncertainty — the expectation is a forecast, not a promise.
        let bufferBps = 30
        let margin = s.marginBps
        let marginColor: Color = margin < 0 ? Theme.debt : (margin < bufferBps ? Theme.amber : Theme.asset)
        let marginCopy: String = margin < 0
            ? "The market is priced below what this plan needs, so the median outcome is itself a shortfall — the gap closes through flexibility, not more risk."
            : (margin < bufferBps
                ? "The median outcome only just clears the bar; the CME is itself a forecast, so read a thin margin as roughly funded rather than a firm cushion."
                : "The median outcome clears the bar with room to spare; the spread is what leaves any miss on the table.")
        return Card("Shortfall probability — the odds the plan falls short") {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Fmt.pctBps(s.shortfallProbBps, 0)).font(.system(size: 34, weight: .bold, design: .serif)).foregroundStyle(shortfallColor(s.band))
                Text("\(s.band.label) — chance the target mix earns less than the plan needs over \(s.horizonYears)y")
                    .font(.system(size: 15)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            LedgerRow("Required real return — after-tax", Fmt.pctBps(s.requiredRealBps), color: Theme.ink)
            LedgerRow("Expected — CME, target mix, net of fees & tax", Fmt.pctBps(s.expectedRealBps), color: marginColor)
            LedgerRow("  (friction netted off gross)", "−\(Fmt.pctBps(s.frictionDragBps))", color: Theme.muted)
            LedgerRow("Median margin", Fmt.bpsSigned(s.marginBps), color: marginColor, bold: true)
            LedgerRow("Portfolio σ — 1yr · annualized /\(s.horizonYears)y", "\(Fmt.pctBps(s.volBps)) · \(Fmt.pctBps(s.annualizedSigmaBps))", color: Theme.muted)
            if s.currentShortfallProbBps != s.shortfallProbBps {
                LedgerRow("Current holdings, for contrast", Fmt.pctBps(s.currentShortfallProbBps, 0),
                          color: s.currentShortfallProbBps < s.shortfallProbBps ? Theme.asset : Theme.debt)
            }
            Note("Risk as the odds of missing the goal, not just a bad year: P(realized real return < required) over the horizon, with the expected return from the capital-market model and σ from the risk model — an analytic normal estimate whose spread shrinks by √time. \(marginCopy) Expected is now NET of a fund-fee + annual-tax friction dial, so it's on the same after-tax basis as the required return. This is an i.i.d. model — sequence-of-returns risk is covered by the historical bad-order stresses above, its deliberate complement, not double-counted here. A lower-equity target can RAISE this number even as it lowers drawdown — the capacity-vs-tolerance tension, made numeric. Uses the QUARANTINED forecast (the CME): it reconciles, it never sets the target.", icon: "dice")
        }
    }

    private func stressRow(_ s: SequenceStress) -> some View {
        let color: Color = !s.survives ? Theme.debt : (s.meetsFloor ? Theme.asset : Theme.amber)
        let status = !s.survives ? "Depletes at \(s.depletionAge ?? 0)"
                   : (s.meetsFloor ? "Survives · ends \(Fmt.usdShort(s.terminalBalanceUsd))"
                                   : "Survives · ends \(Fmt.usdShort(s.terminalBalanceUsd)), below floor")
        return HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(s.detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Text(status).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(color)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func sensitivityLabel(_ s: ReturnSensitivity) -> String {
        let delta = s.realReturnBps - res.requiredRealReturnBps
        if delta == 0 { return "At the required return (\(Fmt.pctBps(s.realReturnBps)))" }
        return "\(delta > 0 ? "+" : "−")\(Fmt.pctBps(abs(delta))) → \(Fmt.pctBps(s.realReturnBps))"
    }
}
