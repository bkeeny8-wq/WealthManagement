//  TaxTab.swift
//  WealthPolicyDesk

import SwiftUI

struct TaxTab: View {
    let eval: Evaluation
    private var it: ItemizationAnalysis { eval.itemization }
    private var mc: MuniCrossover { eval.muni }
    private var embedded: (shortTerm: Usd, longTerm: Usd, taxUsd: Usd, longTermOnlyTaxUsd: Usd, hasLots: Bool) {
        Engine.embeddedGains(eval.household, asOf: eval.asOf)
    }
    private var isoAmt: IsoAmtResult? { Engine.isoAmt(eval.household) }
    private var qsbs: QsbsExclusion? { Engine.qsbsExclusion(eval.household) }
    private var disabilityPv: Usd { Engine.disabilityGapPv(eval.household) }

    var body: some View {
        embeddedGainsCard
        decisionFlagsCard

        Card("SALT window & the marginal mortgage dollar", help: Teach.help("salt")) {
            HeadlineFigure(Fmt.pctBps(it.marginalValueOfMortgageInterestBps),
                           caption: it.itemizes ? "value of the next mortgage-interest dollar" : "not itemizing — no value",
                           color: it.marginalValueOfMortgageInterestBps > 0 ? Theme.asset : Theme.muted)
            LedgerRow("Itemizes?", it.itemizes ? "Yes — \(Fmt.usd(it.totalItemizedUsd))" : "No — takes \(Fmt.usd(it.standardDeductionUsd))", color: it.itemizes ? Theme.asset : Theme.muted)
            LedgerRow("SALT paid", Fmt.usd(it.input.stateIncomeTaxUsd + it.input.propertyTaxUsd), color: Theme.ink)
            LedgerRow("Effective SALT cap", Fmt.usd(it.effectiveSaltCapUsd), color: Theme.ink)
            LedgerRow("SALT deductible", Fmt.usd(it.saltDeductibleUsd), color: Theme.asset)
            LedgerRow("Standard deduction", Fmt.usd(it.standardDeductionUsd), color: Theme.muted)
            if it.inPhaseDownBand {
                LedgerRow("In phase-down band", "eff. \(Fmt.pctBps(it.effectiveMarginalRateInBandBps))", color: Theme.debt, bold: true)
            }
            if let y = it.yearsUntilSaltReversion {
                Note("SALT cap capped on state + property tax alone, so mortgage interest is fully incremental. The cap reverts in \(y) years (2030) — a reason to keep the mortgage through the window, the opposite of default advice.")
            }
        }

        Card("Muni crossover", help: Teach.help("salt")) {
            HStack(spacing: 8) {
                StatTile("Muni yield", Fmt.pctBps(mc.muniYieldBps), sub: "tax-free", color: Theme.ink)
                StatTile("Taxable-equiv.", Fmt.pctBps(mc.taxableEquivalentYieldBps), sub: "incl. NIIT + MAGI", color: Theme.asset)
            }
            LedgerRow("Treasury (taxable)", Fmt.pctBps(mc.treasuryYieldBps), color: Theme.muted)
            LedgerRow("Corporate IG (taxable)", Fmt.pctBps(mc.corporateYieldBps), color: Theme.muted)
            LedgerRow("Marginal ordinary rate", Fmt.pctBps(mc.marginalOrdinaryRateBps) + (mc.niitApplies ? " + NIIT" : ""), color: Theme.ink)
            Note(mc.muniPreferred ? "Muni preferred: its taxable-equivalent yield beats both taxable alternatives. The naive rate misses NIIT and the MAGI effect — muni interest stays out of the phase-down band, IRMAA and NIIT." : "Muni not preferred at these yields.", icon: mc.muniPreferred ? "checkmark.circle" : "info.circle", color: mc.muniPreferred ? Theme.asset : Theme.muted)
        }

        Card("Pay down or invest", help: Teach.help("paydown")) {
            ForEach(eval.paydowns, id: \.liabilityId) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(liabilityLabel(p.liabilityId)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text(p.recommendation.label.uppercased())
                            .font(.system(size: 11.5, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3.5)
                            .background(recColor(p.recommendation), in: Capsule())
                    }
                    HStack {
                        Text("after-tax debt \(Fmt.pctBps(p.afterTaxDebtRateBps))  vs  FI \(Fmt.pctBps(p.comparableFiYieldAfterTaxBps))")
                            .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("spread \(Fmt.bpsSigned(p.spreadBps))").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(p.spreadBps > 0 ? Theme.debt : Theme.asset)
                    }
                    Text(p.rationale).font(.system(size: 13)).foregroundStyle(Theme.ink.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 7)
                .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.rule), alignment: .bottom)
            }
        }

        Card("Roth-conversion window") {
            if let w = eval.policy.withdrawal.conversionWindow {
                LedgerRow("Bracket-fill target", Fmt.pctBps(eval.policy.withdrawal.targetBracketRateBps), color: Theme.ink)
                LedgerRow("Conversion window", "age \(w.fromAge)–\(w.toAge)", color: Theme.ink)
                LedgerRow("Cliffs watched", eval.policy.withdrawal.cliffAwareness.joined(separator: ", ").uppercased(), color: Theme.amber)
                Note("The retirement-to-RMD window is worth more than any tilt. v1 flags opportunities — ‘you have headroom in the 22% bracket’ — rather than optimizing, capturing most of the value without being right about future law.")
            }
        }
    }

    @ViewBuilder private var decisionFlagsCard: some View {
        if isoAmt != nil || qsbs != nil || disabilityPv > 0 {
            Card("Decision-grade flags — equity comp & protection") {
                if let a = isoAmt {
                    Note("Exercising ISOs and HOLDING creates an AMT preference — tax due with no shares sold. The crossover is how much bargain element you can exercise before AMT bites; stage exercises across years to stay under it.")
                    LedgerRow("ISO bargain element", Fmt.usd(a.bargainElementUsd), color: Theme.ink)
                    LedgerRow("AMT due — cash, no proceeds", Fmt.usd(a.amtOwedUsd), color: a.amtOwedUsd > 0 ? Theme.debt : Theme.asset, bold: true)
                    if a.amtOwedUsd > 0 { LedgerRow("Effective AMT rate", Fmt.pctBps(a.effectiveAmtRateBps), color: Theme.debt) }
                    LedgerRow("AMT-free crossover this year", Fmt.usd(a.crossoverBargainUsd), color: Theme.asset, bold: true)
                    Note("Tentative minimum tax \(Fmt.usdShort(a.tentativeMinTaxUsd)) vs regular tax \(Fmt.usdShort(a.regularTaxUsd)) on AMTI \(Fmt.usdShort(a.amtiUsd)) (the standard deduction added back). AMT parameters are dated 2026 estimates under OBBBA — verify.", color: Theme.muted)
                }
                if let q = qsbs {
                    if isoAmt != nil { Divider().overlay(Theme.rule).padding(.vertical, 2) }
                    LedgerRow("§1202 QSBS — status", q.status.label, color: Theme.ink)
                    LedgerRow("Exclusion cap per issuer", Fmt.usd(q.perIssuerCapUsd), color: Theme.asset)
                    LedgerRow("Federal tax it can erase", Fmt.usd(q.maxFederalTaxExcludedUsd), color: Theme.asset, bold: true)
                    Note("Greater of $10M or 10× basis, 100% excluded for stock acquired after 2010 and held 5+ years. Verify the holding-period and $50M gross-asset tests.", color: Theme.muted)
                }
                if disabilityPv > 0 {
                    if isoAmt != nil || qsbs != nil { Divider().overlay(Theme.rule).padding(.vertical, 2) }
                    LedgerRow("Disability gap — present value", Fmt.usd(disabilityPv), color: Theme.debt, bold: true)
                    Note("The unfunded monthly disability-income gap, valued over the working years at the safe real rate — what the coverage shortfall is really worth as a lump.", color: Theme.muted)
                }
            }
        }
    }

    @ViewBuilder private var embeddedGainsCard: some View {
        let e = embedded
        if e.shortTerm != 0 || e.longTerm != 0 {
            let penalty = e.taxUsd - e.longTermOnlyTaxUsd
            Card("Embedded capital gains — short vs long term") {
                Note("The unrealized gains in your taxable, sellable holdings, split by how long each lot has been held. A short-term lot — under about a year — is taxed as ORDINARY income, not at the lower long-term rate, so realizing it costs more. Hold-to-step-up lots are excluded (they extinguish at death).")
                LedgerRow("Long-term gain", Fmt.usd(e.longTerm), color: e.longTerm >= 0 ? Theme.asset : Theme.debt)
                LedgerRow("Short-term gain", Fmt.usd(e.shortTerm), color: e.shortTerm > 0 ? Theme.amber : Theme.muted)
                LedgerRow("Tax if realized today", Fmt.usd(e.taxUsd), color: Theme.ink, bold: true)
                if penalty > 100 {
                    LedgerRow("Short-term penalty", Fmt.usdSigned(penalty), color: Theme.debt, bold: true)
                    Note("Letting the short-term lots season past a year would cut the realize-today tax by \(Fmt.usdShort(penalty)) — the cost of selling a recently bought lot at ordinary rates.", icon: "clock", color: Theme.muted)
                }
                if !e.hasLots {
                    Note("No dated tax lots on file — gains are assumed long-term. Enter real lots to see the short-term split.", color: Theme.muted)
                }
            }
        }
    }

    private func liabilityLabel(_ id: String) -> String { eval.household.liabilities.first { $0.id == id }?.kind.label ?? id }
    private func recColor(_ r: PaydownAnalysis.Recommendation) -> Color {
        switch r { case .payDown: return Theme.debt; case .maintain: return Theme.asset; case .borrowMore: return Theme.accent; case .refinance: return Theme.amber }
    }
}
