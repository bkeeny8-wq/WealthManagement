//  RiskScaleTab.swift
//  WealthPolicyDesk
//
//  Client risk-tolerance scaling — the allocation across the risk spectrum, so an
//  advisor can have the "if you could stomach more (or less) drawdown, here is the
//  portfolio" conversation. Each rung is the solver's own output; capacity caps them.

import SwiftUI

struct RiskScaleTab: View {
    let eval: Evaluation

    private var ladder: [RiskModelPortfolio] {
        Engine.riskLadder(eval.household, fundedRatioBps: eval.balanceSheet.fundedRatioBps, ladder: eval.ladder)
    }

    var body: some View {
        Card("Risk is a dial, not a number") {
            Note("Your allocation is a function of how much drawdown you can stomach. Below is the same plan across the risk spectrum — each rung is the solver's output at that tolerance, priced as if the plan actually held that much equity. Your CAPACITY (what the situation can afford) caps every rung: you can't dial past it. No market forecast is used.")
            if let rp = eval.riskProfile {
                LedgerRow("Capacity — what you CAN hold", Fmt.pctBps(rp.capacityEquityBps), color: Theme.ink)
                LedgerRow("Tolerance — what you'll STOMACH", Fmt.pctBps(rp.toleranceImpliedEquityBps), color: Theme.ink)
                LedgerRow("Binds at the lower", Fmt.pctBps(rp.bindingEquityBps), color: Theme.accent, bold: true)
                Note(rp.bindingIsCapacity
                     ? "You bind on CAPACITY — the situation, not your nerves, is the limit. Raising tolerance won't add equity."
                     : "You bind on TOLERANCE — you could afford more equity than you'll stomach. That gap is a conversation: flexibility or education, not more risk.",
                     icon: "info.circle", color: Theme.muted)
            } else {
                Note("Risk tolerance isn't set for this client — the spectrum below shows capacity-only ceilings. Capture a max-drawdown tolerance in the intake to bind it.", icon: "exclamationmark.triangle", color: Theme.amber)
            }
        }

        Card("Model portfolios — Defensive → Aggressive") {
            ForEach(ladder) { p in riskRow(p) }
            Note("Growth is the risk dial; defensive bonds, TIPS, commodities, cash, and the alt sleeves fill in around it. A rung dimmed and marked is one your capacity won't allow — the situation caps it below that tolerance.")
        }
    }

    private func riskRow(_ p: RiskModelPortfolio) -> some View {
        let capped = p.capacityBound
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(p.label).font(.system(size: 15, weight: p.isClientLevel ? .heavy : .semibold))
                    .foregroundStyle(p.isClientLevel ? Theme.accent : Theme.ink)
                if p.isClientLevel {
                    Text("YOU").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent, in: Capsule())
                }
                Spacer()
                Text("≤ \(Fmt.pctBps(p.maxDrawdownBps)) drawdown").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            StackBar([
                StackSegment("Growth", Double(p.growthBps), Theme.accent),
                StackSegment("Defensive", Double(p.defensiveBps), Theme.ink.opacity(0.5)),
                StackSegment("Real", Double(p.realDiversifierBps), Theme.debt.opacity(0.5)),
                StackSegment("Cash", Double(p.cashBps), Theme.ink.opacity(0.25)),
                StackSegment("Alts", Double(p.altBps), Theme.amber.opacity(0.6)),
            ])
            HStack(spacing: 6) {
                Text("Growth \(Fmt.pctBps(p.growthBps))")
                    .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.ink)
                if capped {
                    Text("· capacity-capped").font(.system(size: 11)).foregroundStyle(Theme.amber)
                }
                Spacer()
                Text("bonds \(Fmt.pctBps(p.defensiveBps)) · cash \(Fmt.pctBps(p.cashBps))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 9)
        .opacity(capped && !p.isClientLevel ? 0.5 : 1)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
    }
}
