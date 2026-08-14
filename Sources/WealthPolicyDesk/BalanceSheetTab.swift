//  BalanceSheetTab.swift
//  WealthPolicyDesk

import SwiftUI

struct BalanceSheetTab: View {
    let eval: Evaluation
    private var bs: BalanceSheetView { eval.balanceSheet }

    var body: some View {
        let netFIColor = bs.netFixedIncomeUsd < 0 ? Theme.debt : Theme.asset
        let a = bs.assets
        let l = bs.liabilities

        Card("Household balance sheet", help: Teach.help("balanceSheet")) {
            HeadlineFigure(Fmt.usd(bs.afterTaxNetWorthUsd), caption: "After-tax net worth", color: Theme.ink)
            LedgerRow("Gross net worth", Fmt.usd(bs.grossNetWorthUsd), color: Theme.muted)
            LedgerRow("Embedded tax removed", Fmt.usdSigned(-(bs.grossNetWorthUsd - bs.afterTaxNetWorthUsd)), color: Theme.debt)
            Note("Gross net worth overstates what a household actually has — here by \(Fmt.pct((bs.grossNetWorthUsd - bs.afterTaxNetWorthUsd) / max(1, bs.grossNetWorthUsd))). The statement counts tax you still owe as yours.")
        }

        StatGrid([
            StatTile("Net fixed income", Fmt.usd(bs.netFixedIncomeUsd), sub: bs.netFixedIncomeUsd < 0 ? "Net SHORT duration" : "Net long", color: netFIColor),
            StatTile("Funded ratio", Fmt.pctBps(bs.fundedRatioBps), sub: "Resources ÷ liabilities", color: bs.fundedRatioBps >= 10_000 ? Theme.asset : Theme.amber),
            StatTile("Total B/S equity", Fmt.pctBps(bs.totalBalanceSheetEquityBps), sub: "Incl. human-capital beta", color: Theme.ink),
            StatTile("Net duration", Fmt.yrs(bs.netHouseholdDurationYears), sub: "Household, incl. debt", color: Theme.ink),
        ])

        if let rp = eval.riskProfile {
            Card("Risk — capacity vs tolerance") {
                StatGrid([
                    StatTile("Capacity", Fmt.pctBps(rp.capacityEquityBps), sub: "equity you CAN hold", color: Theme.ink),
                    StatTile("Tolerance", Fmt.pctBps(rp.toleranceImpliedEquityBps), sub: "equity you'll STOMACH", color: Theme.ink),
                    StatTile("Binds at", Fmt.pctBps(rp.bindingEquityBps), sub: rp.bindingIsCapacity ? "capacity-bound" : "tolerance-bound", color: Theme.accent),
                ])
                Note("Bind to the lower of the two. The \(Fmt.bps(rp.gapBps)) gap is the conversation: \(rp.bindingIsCapacity ? "your situation can afford less equity than you'd stomach" : "you could afford more equity than you'll stomach — flexibility or education, not more risk").")
            }
        }

        if let prot = eval.household.protection {
            Card("Protection — coverage vs need") {
                LedgerRow("Disability gap (monthly)",
                          prot.disabilityGapMonthlyUsd > 0 ? Fmt.usd(prot.disabilityGapMonthlyUsd) : "covered",
                          color: prot.disabilityGapMonthlyUsd > 0 ? Theme.debt : Theme.asset)
                LedgerRow("Life insurance gap",
                          prot.lifeGapUsd > 0 ? Fmt.usd(prot.lifeGapUsd) : "covered",
                          color: prot.lifeGapUsd > 0 ? Theme.debt : Theme.asset)
                LedgerRow("Long-term care unfunded",
                          prot.ltcUnfundedUsd > 0 ? Fmt.usd(prot.ltcUnfundedUsd) : "covered",
                          color: prot.ltcUnfundedUsd > 0 ? Theme.debt : Theme.asset)
                LedgerRow("Umbrella limit", Fmt.usd(prot.umbrellaLimitUsd),
                          color: prot.umbrellaLimitUsd >= bs.grossNetWorthUsd ? Theme.asset : Theme.amber)
                Note("The tails a brokerage statement never shows — coverage measured against a derived need, not a quote. Gaps surface as findings on the planning surface.")
            }
        }

        Card("Assets") {
            StackBar([
                StackSegment("Portfolio", max(0, a.portfolioUsd - a.illiquidAltsUsd), Theme.accent),
                StackSegment("Real estate", a.realEstateUsd, Theme.asset),
                StackSegment("Human capital", a.humanCapitalPvUsd, Theme.amber),
                StackSegment("Social Security", a.socialSecurityPvUsd, Theme.ink.opacity(0.6)),
                StackSegment("Pension", a.pensionPvUsd, Theme.muted),
                StackSegment("Illiquid alts", a.illiquidAltsUsd, Theme.debt.opacity(0.6)),
            ])
            LedgerRow("Investment portfolio", Fmt.usd(a.portfolioUsd), color: Theme.asset)
            LedgerRow("Real estate (gross)", Fmt.usd(a.realEstateUsd), color: Theme.asset)
            LedgerRow("Human capital (PV)", Fmt.usd(a.humanCapitalPvUsd), color: Theme.asset)
            LedgerRow("Social Security (PV)", Fmt.usd(a.socialSecurityPvUsd), color: Theme.asset)
            LedgerRow("Pension (PV)", Fmt.usd(a.pensionPvUsd), color: Theme.asset)
            if a.illiquidAltsUsd > 0 { LedgerRow("Illiquid alternatives", Fmt.usd(a.illiquidAltsUsd), color: Theme.asset) }
        }

        Card("Liabilities", help: Teach.help("netFI")) {
            LedgerRow("Debt (mortgage, HELOC)", Fmt.usd(l.debtUsd), color: Theme.debt)
            LedgerRow("Unfunded commitments", Fmt.usd(l.unfundedCommitmentsUsd), color: Theme.debt)
            LedgerRow("Deferred tax", Fmt.usd(l.deferredTaxUsd), color: Theme.debt)
            LedgerRow("Projected estate tax", Fmt.usd(l.projectedEstateTaxUsd), color: Theme.debt)
            LedgerRow("Goal liability (PV)", Fmt.usd(l.goalLiabilityPvUsd), color: Theme.debt)
            Note("Net fixed income is \(Fmt.usdSigned(bs.netFixedIncomeUsd)): a fixed mortgage is a large short bond position. Every statement shows the bonds and omits the offset.", icon: "exclamationmark.triangle", color: netFIColor)
        }

        Card("Deferred tax — the largest unstated liability") {
            ForEach(bs.deferredTaxDetail.filter { $0.balanceUsd > 0 }) { d in
                LedgerRow(accountLabel(d.accountId) + (d.extinguishedByStepUp ? "  (step-up)" : ""),
                          d.estimatedLiabilityUsd > 0 ? Fmt.usd(d.estimatedLiabilityUsd) : "—",
                          color: d.estimatedLiabilityUsd > 0 ? Theme.debt : Theme.asset)
            }
            Note("A $2M traditional IRA and a $2M Roth are not the same asset. Lots earmarked to step-up carry NO deferred tax — the step-up extinguishes it, so the balance sheet and the disposition engine are linked.")
        }
    }

    private func accountLabel(_ id: String) -> String { eval.household.account(id)?.label ?? id }
}
