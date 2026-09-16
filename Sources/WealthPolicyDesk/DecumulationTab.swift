//  DecumulationTab.swift
//  WealthPolicyDesk
//
//  The year-by-year, after-tax retirement projection — and the Roth-conversion
//  strategy laid over it. A single required-return number says nothing about WHEN
//  the tax lands; this tab shows the RMD wall, the low-bracket years before it, and
//  what filling those years with conversions saves over a lifetime.

import SwiftUI
import Charts

struct DecumulationTab: View {
    let eval: Evaluation
    private var strat: RothStrategy { eval.decumulation }
    private var plan: DecumulationPlan { strat.plan }
    private var glide: WealthGlide { Engine.wealthGlide(eval) }

    private struct GlideBand: Identifiable {
        let age: Int; let kind: String; let usd: Usd
        var id: String { "\(kind)-\(age)" }
    }

    /// Why no RMD lands. `firstRmdAge == 0` reads as "the plan ends before RMDs begin", but
    /// it is also what a household that CONVERTED its way out of them looks like, and a note
    /// telling the reader to watch a step-up that never comes — with an em-dash where the age
    /// should be — said neither.
    private var noRmdReason: String {
        let plan = self.plan
        // Evidence of having HELD a deferred balance, not just of ending a year with one. The
        // first version looked only at end-of-year balances and conversions, so a household that
        // drew its whole tax-deferred balance down inside plan year 1 — the engine's draw order
        // is taxable, then deferred, then Roth — was reported as having had "no tax-deferred
        // balance to draw from", which is the opposite of what happened. A withdrawal or an RMD
        // is proof the balance existed.
        let everHeldDeferred = plan.years.contains {
            $0.endDeferredUsd > 0 || $0.rothConversionUsd > 0 || $0.deferredWithdrawalUsd > 0 || $0.rmdUsd > 0
        }
        if !everHeldDeferred { return "no tax-deferred balance to draw from" }
        if let last = plan.years.last, last.endDeferredUsd > 0 { return "the plan ends before the RMD age" }
        return "the tax-deferred balance is exhausted before the RMD age"
    }

    var body: some View {
        if plan.years.isEmpty {
            Card("Decumulation") {
                Note("No retirement years to project yet — set a retirement age and horizon, and a portfolio to draw from.")
            }
        } else {
            strategyCard

            StatGrid([
                StatTile("Lifetime tax", Fmt.usdShort(plan.lifetimeFederalTaxUsd),
                         sub: strat.lifetimeTaxSavedUsd > 0 ? "with conversions" : "baseline", color: Theme.ink),
                StatTile("First RMD", plan.firstRmdAge > 0 ? "age \(plan.firstRmdAge)" : "none",
                         sub: plan.firstRmdAge > 0 ? "forced tax-deferred draw" : noRmdReason, color: Theme.accent),
                StatTile("Peak marginal rate", Fmt.pctBps(plan.peakMarginalRateBps),
                         sub: "highest bracket hit", color: plan.peakMarginalRateBps >= 2400 ? Theme.debt : Theme.ink),
                StatTile("Lifetime IRMAA", Fmt.usdShort(plan.lifetimeIrmaaUsd),
                         sub: "Medicare surcharges", color: plan.lifetimeIrmaaUsd > 0 ? Theme.amber : Theme.asset),
            ])

            if glide.points.count > 1 { glideCard }

            Card(strat.lifetimeTaxSavedUsd > 0 ? "Year by year — with conversions" : "Year by year") {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .trailing, horizontalSpacing: 15, verticalSpacing: 7) {
                        GridRow {
                            head("AGE", .leading); head("SPEND"); head("SS + PENS"); head("WAGES"); head("RMD")
                            head("CONV"); head("ORD. INC"); head("FED TAX"); head("MARG"); head("IRMAA")
                        }
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.rule), alignment: .bottom)
                        ForEach(plan.years) { y in
                            GridRow {
                                Text("\(y.age)").font(cell.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .gridColumnAlignment(.leading)
                                num(y.spendingNeedUsd, Theme.ink)
                                num(y.guaranteedIncomeUsd, Theme.asset)
                                num(y.wagesUsd, y.wagesUsd > 0 ? Theme.asset : Theme.muted)
                                num(y.rmdUsd, y.rmdUsd > 0 ? Theme.accent : Theme.muted)
                                num(y.rothConversionUsd, y.rothConversionUsd > 0 ? Theme.asset : Theme.muted)
                                num(y.ordinaryIncomeUsd, Theme.ink)
                                num(y.federalTaxUsd, y.federalTaxUsd > 0 ? Theme.debt : Theme.muted)
                                Text(Fmt.pctBps(y.marginalRateBps)).font(cell)
                                    .foregroundStyle(y.marginalRateBps >= 2400 ? Theme.debt : Theme.muted)
                                num(y.irmaaUsd, y.irmaaUsd > 0 ? Theme.amber : Theme.muted)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                Note("Ordinary income folds wages still being earned, the RMD, discretionary tax-deferred draws, pension, any Roth conversion, and the taxable portion of Social Security. "
                     + (plan.firstRmdAge > 0
                        ? "Watch the marginal rate and IRMAA step up the year RMDs begin (age \(plan.firstRmdAge))."
                        : "No RMD falls in this plan — \(noRmdReason) — so the RMD column stays empty and no forced draw ever lands."),
                     icon: "arrow.up.right")
            }
        }
    }

    @ViewBuilder private var strategyCard: some View {
        if strat.lifetimeTaxSavedUsd > 0 {
            Card("Roth-conversion strategy", help: Teach.help("requiredReturn")) {
                HeadlineFigure(Fmt.usd(strat.lifetimeTaxSavedUsd), caption: "Projected lifetime federal tax saved (real $)", color: Theme.asset)
                LedgerRow("Baseline — no conversions", Fmt.usd(strat.baseline.lifetimeFederalTaxUsd), color: Theme.muted)
                LedgerRow("With recommended conversions", Fmt.usd(plan.lifetimeFederalTaxUsd), color: Theme.ink, bold: true)
                Note("Convert about \(Fmt.usdShort(strat.avgAnnualConversionUsd))/yr for \(strat.conversionYears) year\(strat.conversionYears == 1 ? "" : "s"), filling to the \(Fmt.pctBps(strat.targetBracketBps)) bracket in the low-income years before RMDs — moving tax-deferred dollars to Roth at a low rate now to shrink the RMDs, Social-Security taxation, and IRMAA later.")
            }
        } else {
            Card("Lifetime tax — baseline path", help: Teach.help("requiredReturn")) {
                HeadlineFigure(Fmt.usd(plan.lifetimeFederalTaxUsd), caption: "Projected lifetime federal income tax (real $)", color: Theme.ink)
                Note("No Roth conversion beats the baseline draw order here — the bracket is roughly flat across retirement, so there's little to arbitrage. The pre-RMD years below still show where the room is.")
            }
        }
    }

    private var glideCard: some View {
        let g = glide
        let bands: [GlideBand] = g.points.flatMap { p in
            [GlideBand(age: p.age, kind: "Financial capital", usd: p.financialUsd),
             GlideBand(age: p.age, kind: "Human capital", usd: p.humanCapitalUsd)]
        }
        let atRetirement = g.points.first { $0.age >= g.retirementAge }
        return Card("Lifetime wealth glide") {
            Note("Where the money is over a life, in today's real dollars. Human capital — the value of earnings still ahead — converts into the portfolio as you save, tapering to zero as those earnings end; the portfolio grows through accumulation, peaks near retirement, then draws down to fund spending. The financial line is the plan's own required-return path — whether real returns can DELIVER it is the Resilience and Shortfall question.")
            Chart {
                ForEach(bands) { b in
                    AreaMark(x: .value("Age", b.age), y: .value("Value", b.usd))
                        .foregroundStyle(by: .value("Band", b.kind))
                        .interpolationMethod(.monotone)
                }
                RuleMark(x: .value("Retires", g.retirementAge))
                    .foregroundStyle(Theme.ink.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("retires \(g.retirementAge)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                if g.legacyFloorUsd > 0 {
                    RuleMark(y: .value("Floor", g.legacyFloorUsd))
                        .foregroundStyle(Theme.debt.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .bottom, alignment: .trailing) {
                            Text("legacy floor").font(.system(size: 9)).foregroundStyle(Theme.debt)
                        }
                }
            }
            .chartForegroundStyleScale(["Financial capital": Theme.accent, "Human capital": Theme.amber.opacity(0.8)])
            .chartLegend(position: .top, alignment: .leading, spacing: 10)
            .chartXScale(domain: (g.points.first?.age ?? 0)...(g.points.last?.age ?? 100))
            .chartXAxisLabel("Age", alignment: .center)
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisGridLine(); AxisTick()
                AxisValueLabel { if let y = v.as(Double.self) { Text(Fmt.usdShort(y)) } }
            } }
            .frame(height: 260)

            if let ret = atRetirement {
                LedgerRow("Portfolio at retirement — age \(g.retirementAge)", Fmt.usd(ret.financialUsd), color: Theme.ink, bold: true)
            }
            LedgerRow("Peak total wealth", "\(Fmt.usd(g.peakTotalUsd)) · age \(g.peakTotalAge)", color: Theme.asset)
            LedgerRow(g.depletionAge != nil ? "Portfolio depletes" : "Portfolio lasts",
                      g.depletionAge.map { "age \($0) — before the horizon ends" } ?? "through the plan horizon",
                      color: g.depletionAge != nil ? Theme.debt : Theme.asset)
            if !g.hasHumanCapital {
                Note("No future earnings on file — the human-capital band is empty, so this is a pure drawdown.", color: Theme.muted)
            }
        }
    }

    private let cell = Font.system(size: 13, weight: .medium, design: .monospaced)

    private func head(_ t: String, _ align: HorizontalAlignment = .trailing) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted).gridColumnAlignment(align)
    }
    private func num(_ v: Usd, _ color: Color) -> some View {
        Text(v > 0 ? Fmt.usdShort(v) : "—").font(cell).foregroundStyle(color)
    }
}
