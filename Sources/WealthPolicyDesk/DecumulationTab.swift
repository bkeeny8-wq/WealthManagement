//  DecumulationTab.swift
//  WealthPolicyDesk
//
//  The year-by-year, after-tax retirement projection — and the Roth-conversion
//  strategy laid over it. A single required-return number says nothing about WHEN
//  the tax lands; this tab shows the RMD wall, the low-bracket years before it, and
//  what filling those years with conversions saves over a lifetime.

import SwiftUI

struct DecumulationTab: View {
    let eval: Evaluation
    private var strat: RothStrategy { eval.decumulation }
    private var plan: DecumulationPlan { strat.plan }

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
                StatTile("First RMD", plan.firstRmdAge > 0 ? "age \(plan.firstRmdAge)" : "—",
                         sub: "forced tax-deferred draw", color: Theme.accent),
                StatTile("Peak marginal rate", Fmt.pctBps(plan.peakMarginalRateBps),
                         sub: "highest bracket hit", color: plan.peakMarginalRateBps >= 2400 ? Theme.debt : Theme.ink),
                StatTile("Lifetime IRMAA", Fmt.usdShort(plan.lifetimeIrmaaUsd),
                         sub: "Medicare surcharges", color: plan.lifetimeIrmaaUsd > 0 ? Theme.amber : Theme.asset),
            ])

            Card(strat.lifetimeTaxSavedUsd > 0 ? "Year by year — with conversions" : "Year by year") {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .trailing, horizontalSpacing: 15, verticalSpacing: 7) {
                        GridRow {
                            head("AGE", .leading); head("SPEND"); head("SS + PENS"); head("RMD")
                            head("CONV"); head("ORD. INC"); head("FED TAX"); head("MARG"); head("IRMAA")
                        }
                        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.rule), alignment: .bottom)
                        ForEach(plan.years) { y in
                            GridRow {
                                Text("\(y.age)").font(cell.weight(.semibold)).foregroundStyle(Theme.ink)
                                    .gridColumnAlignment(.leading)
                                num(y.spendingNeedUsd, Theme.ink)
                                num(y.guaranteedIncomeUsd, Theme.asset)
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
                Note("Ordinary income folds the RMD, discretionary tax-deferred draws, pension, any Roth conversion, and the taxable portion of Social Security. Watch the marginal rate and IRMAA step up the year RMDs begin (age \(plan.firstRmdAge > 0 ? String(plan.firstRmdAge) : "—")).", icon: "arrow.up.right")
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

    private let cell = Font.system(size: 13, weight: .medium, design: .monospaced)

    private func head(_ t: String, _ align: HorizontalAlignment = .trailing) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted).gridColumnAlignment(align)
    }
    private func num(_ v: Usd, _ color: Color) -> some View {
        Text(v > 0 ? Fmt.usdShort(v) : "—").font(cell).foregroundStyle(color)
    }
}
