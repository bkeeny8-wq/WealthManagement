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
    private var isoAmt: IsoAmtResult? { Engine.isoAmt(eval.household, asOf: eval.asOf) }
    private var qsbs: QsbsExclusion? { Engine.qsbsExclusion(eval.household) }
    private var disabilityPv: Usd { Engine.disabilityGapPv(eval.household, asOf: eval.asOf) }

    var body: some View {
        Note("Federal tax figures are 2026 estimates (last verified \(eval.tax.lastVerifiedAt)), not IRS Rev. Proc. tables. State income tax is out of scope for the return solve; muni and paydown use a dated effective-rate snapshot.",
             color: Theme.muted)
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
            // Gated on the HOUSEHOLD, not just the parameter set. `yearsUntilSaltReversion`
            // is a property of the tax law, so this fired for anyone — including a household
            // the very row above says does not itemize. The old hardcoded state profile made
            // every homeowner max out SALT, which kept the branch unreachable; reading the
            // client's real state and giving made it reachable, and a Texas household with a
            // small mortgage was told to keep it "through the window" ten lines under a
            // headline saying the deduction is worth nothing to them.
            if let y = it.yearsUntilSaltReversion, it.itemizes, it.marginalValueOfMortgageInterestBps > 0 {
                Note("SALT is capped on state + property tax alone, so mortgage interest is fully incremental. The cap reverts in \(y) years (2030) — a reason to keep the mortgage through the window, the opposite of default advice.")
            } else if it.yearsUntilSaltReversion != nil, !it.itemizes {
                Note("Not itemizing, so the SALT cap and the mortgage-interest deduction are both worth nothing here. The 2030 reversion only matters if deductions later exceed the standard deduction.", icon: "info.circle", color: Theme.muted)
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
            LedgerRow("State income rate", Fmt.pctBps(mc.stateIncomeRateBps), color: Theme.muted)
            LedgerRow("After tax — muni / Treasury / corporate",
                      "\(Fmt.pctBps(mc.muniAfterTaxBps)) · \(Fmt.pctBps(mc.treasuryAfterTaxBps)) · \(Fmt.pctBps(mc.corporateAfterTaxBps))",
                      color: Theme.ink)
            Note(mc.muniPreferred ? "Muni preferred: it wins after every tax that applies. Modelled as a NATIONAL muni fund, so state-taxable — an in-state fund would look better still, and Treasuries are already state-exempt. The naive rate misses NIIT and the MAGI effect — muni interest stays out of the SALT phase-down band and NIIT, though it IS added back for IRMAA and the Social-Security formula." : "Muni not preferred at these yields.", icon: mc.muniPreferred ? "checkmark.circle" : "info.circle", color: mc.muniPreferred ? Theme.asset : Theme.muted)
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
                if eval.isSolvable {
                    LedgerRow("Bracket-fill target",
                              eval.decumulation.targetBracketBps > 0
                                ? Fmt.pctBps(eval.decumulation.targetBracketBps)
                                : "none — conversions do not reduce lifetime tax",
                              color: Theme.ink)
                    LedgerRow("Conversion window", "age \(w.fromAge)–\(w.toAge)", color: Theme.ink)
                    LedgerRow("Cliffs watched", eval.policy.withdrawal.cliffAwareness.joined(separator: ", ").uppercased(), color: Theme.amber)
                    Note("This card names the window. The Decumulation tab sizes the conversions — a lowest-lifetime-tax path filling these years, not a market call. Federal estimates as of \(eval.tax.lastVerifiedAt); verify before acting.")
                } else {
                    // The optimizer still runs at `rr.requiredRealReturnBps` even when that
                    // figure is the ±5%/20% clamp, so a 22% fill (or "none") here would be
                    // a clamp-grown conclusion, not a client path. Window ages are policy.
                    LedgerRow("Conversion window", "age \(w.fromAge)–\(w.toAge)", color: Theme.ink)
                    Note("Nothing to solve yet. The bracket-fill target is the Decumulation optimizer's fill, grown at the plan's required return — and that return has no solution until this household has balances and spending. The figure that would appear here would be grown at a clamp, not a rate. The ages above are the policy window, not a conversion ticket.",
                         icon: "questionmark.circle", color: Theme.muted)
                }
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
                // `capitalGainsTax` is documented as FEDERAL tax, and this row dropped the word.
                // Name it, and say plainly that state tax is not in it.
                //
                // No dollar estimate. An earlier version multiplied the gain by
                // `StateTaxProfile.incomeRate` and called the result an upper bound from the
                // state's "top marginal rate". Both halves were wrong. Seed.swift heads that
                // table "EFFECTIVE state income and property tax rates ... these drive only the
                // SALT/itemization estimate behind the muni-crossover and paydown comparisons,
                // never a filed return", and the stored values agree with the effective reading,
                // not the marginal one — NJ 6.37% against a 10.75% statutory top, CA 9.30%
                // against 12.3% plus the 1% surcharge. So the figure was not a ceiling at all:
                // it understated a top-bracket Californian by roughly a third, in a row that
                // promised it could only be too high. Sizing this honestly needs sourced
                // effective (or true marginal) capital-gain rates for all 51 jurisdictions,
                // which is the same open data task as the SALT row's.
                LedgerRow("Federal tax if realized today", Fmt.usd(e.taxUsd), color: Theme.ink, bold: true)
                // Three-way, decided in the engine where it can be tested — see
                // Engine.stateGainTreatment for why this rule does not live in the view.
                switch Engine.stateGainTreatment(eval.household) {
                case .noStateIncomeTax(let name):
                    Note("\(name) levies no state income tax, so for this household the federal figure above is "
                         + "the whole realize-today liability. Rates are a dated, teaching-grade snapshot — verify.",
                         color: Theme.muted)
                case .taxesGain(let name):
                    Note("This is the FEDERAL figure only. \(name) taxes capital gain too, and that is ON TOP of "
                         + "the number above — not included in it. The app does not size it: the state rates it carries "
                         + "are a dated, teaching-grade snapshot scoped to the SALT and muni comparisons, not to a "
                         + "realization decision. Get the state number from the client's preparer before acting on this row.",
                         color: Theme.muted)
                case .noStateOnFile:
                    Note("This is the FEDERAL figure only, and no state of residence is on file. Most states tax capital "
                         + "gain as well — set the residence on the intake's Household step, then treat any state liability "
                         + "as additional to the number above.",
                         color: Theme.muted)
                }
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
