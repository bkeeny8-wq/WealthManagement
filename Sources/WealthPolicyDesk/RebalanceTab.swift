//  RebalanceTab.swift
//  WealthPolicyDesk
//
//  The rebalance-to-policy trade list: the concrete sells and buys that move the
//  book from where it IS to the derived target, tax-aware and disposition-aware.
//  A proposal to verify and place — never executed here.

import SwiftUI

struct RebalanceTab: View {
    let eval: Evaluation

    // Rebalance to the TACTICAL target: the derived policy (full sleeve metadata +
    // rebalance knobs) with each sleeve's target overwritten by the tactical target
    // the allocation table already tracks drift against.
    private var plan: RebalancePlan {
        var p = eval.legacyPolicy
        p.sleeves = p.sleeves.map { s in
            var s = s
            if let row = eval.allocation.first(where: { $0.sleeveId == s.id }) { s.targetBps = row.targetBps }
            return s
        }
        return Engine.rebalancePlan(eval.household, policy: p, tax: eval.tax, asOf: eval.asOf)
    }

    var body: some View {
        let p = plan
        let sells = p.trades.filter { $0.side == .sell }
        let buys = p.trades.filter { $0.side == .buy }

        Card("Rebalance to policy") {
            Note("The concrete trades that close the gap between the book and its DERIVED target — the same target the Allocation tab measures drift against, tilts included. Each trade closes \(Fmt.pctBps(p.correctionFractionBps)) of the gap (the policy's partial-correction rule — let momentum run), only for sleeves outside their no-trade band. Selling is tax-aware and honors every hold-to-step-up / gift / charitable lot. A proposal to verify and place — the app never executes.")
            LedgerRow("Trade volume", Fmt.usd(p.totalSellsUsd + p.totalBuysUsd), color: Theme.ink, bold: true)
            LedgerRow("Sell → buy", "\(Fmt.usdShort(p.totalSellsUsd)) → \(Fmt.usdShort(p.totalBuysUsd))", color: Theme.muted)
            LedgerRow("Turnover", Fmt.pctBps(p.turnoverBps), color: Theme.muted)
            LedgerRow("Realized gain", Fmt.usdSigned(p.realizedGainUsd), color: p.realizedGainUsd > 0 ? Theme.amber : Theme.asset)
            if p.realizedShortTermUsd > 0 {
                LedgerRow("of which short-term / long-term", "\(Fmt.usdShort(p.realizedShortTermUsd)) / \(Fmt.usdShort(p.realizedLongTermUsd))", color: Theme.muted)
            }
            LedgerRow("Est. tax", Fmt.usd(p.estTaxUsd), color: p.estTaxUsd > 0 ? Theme.amber : Theme.asset, bold: true)
            if p.gainBudgetUsd > 0 {
                LedgerRow("Gain budget", Fmt.usd(p.gainBudgetUsd), color: p.budgetBinds ? Theme.debt : Theme.asset)
            }
        }

        if !p.warnings.isEmpty {
            Card("Watch") {
                ForEach(Array(p.warnings.enumerated()), id: \.offset) { _, w in
                    Note(w, icon: "exclamationmark.triangle", color: Theme.amber)
                }
            }
        }

        if !sells.isEmpty {
            Card("Sell — \(sells.count)") {
                ForEach(sells) { tradeRow($0) }
                Note("Order: sheltered accounts first (no tax), then losses to harvest, then the lowest-gain taxable lots — capped by the realized-gain budget.", color: Theme.muted)
            }
        }

        if !buys.isEmpty {
            Card("Buy — \(buys.count)") {
                ForEach(buys) { tradeRow($0) }
                Note("Each underweight sleeve is funded with its primary instrument, in its preferred account location.", color: Theme.muted)
            }
        }

        Card("Drift by sleeve") {
            ForEach(p.sleeveGaps.filter { $0.currentBps > 0 || $0.targetBps > 0 }) { gapRow($0) }
            Note("Full gap to target shown; only sleeves tagged TRADE are outside their band and get a (partial) correction.", color: Theme.muted)
        }
    }

    private func tradeRow(_ t: RebalanceTrade) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(t.side == .sell ? "SELL" : "BUY").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(t.side == .sell ? Theme.debt : Theme.asset, in: Capsule())
                Text(t.ticker).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                if t.side == .sell && t.shortTermGainUsd > 0 {
                    Text(t.longTermGainUsd > 0 ? "ST+LT" : "ST").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1.5).background(Theme.amber, in: Capsule())
                }
                Text("· \(t.accountLabel)").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Text(Fmt.usd(t.amountUsd)).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
            }
            HStack(alignment: .top) {
                Text(t.rationale).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if t.side == .sell && t.realizedGainUsd != 0 {
                    Text("gain \(Fmt.usdSigned(t.realizedGainUsd))").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(t.realizedGainUsd > 0 ? Theme.amber : Theme.asset).fixedSize()
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }

    private func gapRow(_ g: RebalanceSleeveGap) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(g.label).font(.system(size: 13.5, weight: g.traded ? .semibold : .regular)).foregroundStyle(Theme.ink)
                    if g.traded {
                        Text("TRADE").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5).background(Theme.accent, in: Capsule())
                    }
                }
                Text("\(Fmt.pctBps(g.currentBps)) → \(Fmt.pctBps(g.targetBps))")
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Text(Fmt.usdSigned(g.gapUsd)).font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(g.status == .outerBreach ? Theme.debt : (g.status == .innerBreach ? Theme.amber : Theme.muted))
        }
        .padding(.vertical, 5)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}
