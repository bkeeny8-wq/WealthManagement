//  RebalanceModel.swift
//  WealthPolicyDesk
//
//  The rebalance-to-policy trade generator — the last "output, not input" piece.
//  Everything else in the app DERIVES a target; this turns the gap between where
//  the book IS and that derived target into a concrete, tax-aware list of proposed
//  trades: sell this much of this lot in this account, buy this much of this fund
//  there. It is a PROPOSAL a practitioner verifies and places — the app never
//  executes, quotes live prices, or touches an account.
//
//  Doctrine it respects (all read from the policy, not reinvented here):
//   - Moves toward the already-derived, forecast-free-plus-budgeted-tilt target
//     (policy.sleeves[].targetBps). It never invents a target of its own.
//   - Only trades sleeves DRIFTED OUTSIDE their no-trade band, and only
//     correctionFractionBps of the way to target — the policy's "let momentum run,
//     correct partially" rule. Trades below minTradeUsd are dropped.
//   - Locked / gated sleeves (rebalance.excludedLiquidityClasses) sit outside bands.
//   - Tax-aware selling: sheltered accounts first (no current tax), then taxable
//     LOSSES (harvest), then the lowest-gain taxable lots — never realizing gains
//     past the household's transition budget or the policy's rebalancing gain budget.
//   - Honors terminal dispositions: step-up / gift / charitable lots (and any
//     hold-to-step-up flag) are held out of selling entirely.
//   - Tax is the canonical stacked LTCG computation (Engine.ltcgTaxOnGain), summed
//     once over the whole plan — not a flat per-lot rate.

import Foundation

public enum TradeSide: String, Sendable, Hashable { case buy, sell }

public struct RebalanceTrade: Identifiable, Sendable, Hashable {
    public var id: String
    public var side: TradeSide
    public var ticker: String
    public var accountId: String
    public var accountLabel: String
    public var treatment: AccountTaxTreatment
    public var sleeveId: String
    public var sleeveLabel: String
    public var amountUsd: Usd
    public var realizedGainUsd: Usd      // sells in taxable accounts; 0 otherwise
    public var shortTermGainUsd: Usd = 0 // portion of realizedGain held < ~1yr (taxed as ordinary)
    public var longTermGainUsd: Usd = 0
    public var rationale: String
}

public struct RebalanceSleeveGap: Identifiable, Sendable, Hashable {
    public var sleeveId: String
    public var label: String
    public var currentBps: Bps
    public var targetBps: Bps
    public var gapUsd: Usd                // + = underweight (buy), - = overweight (sell); FULL gap to target
    public var status: AllocationRow.Status
    public var traded: Bool               // out of band, tradeable, above minTrade
    public var id: String { sleeveId }
}

public struct RebalancePlan: Sendable {
    public var trades: [RebalanceTrade]
    public var sleeveGaps: [RebalanceSleeveGap]
    public var totalBuysUsd: Usd
    public var totalSellsUsd: Usd
    public var turnoverBps: Bps           // gross traded ÷ portfolio
    public var realizedGainUsd: Usd       // net taxable realized gain (losses net down)
    public var realizedShortTermUsd: Usd  // of which short-term (taxed as ordinary)
    public var realizedLongTermUsd: Usd   // of which long-term (LTCG rates)
    public var estTaxUsd: Usd             // stacked ST-as-ordinary + LT-as-LTCG tax on the net gain
    public var correctionFractionBps: Bps // how far toward target each trade goes
    public var gainBudgetUsd: Usd         // realized-gain headroom available to this plan (0 = none set)
    public var budgetBinds: Bool
    public var fundingGapUsd: Usd         // underweight buys the sells couldn't fund
    public var excessCashUsd: Usd         // sell proceeds beyond what buys absorbed
    public var washSaleDisallowedUsd: Usd // harvested loss disallowed by a same-security re-buy
    public var heldOutUsd: Usd            // value excluded from selling (disposition/locked)
    public var warnings: [String]
    public var asOf: IsoDate
    public var isEmpty: Bool { trades.isEmpty }
}

public extension Engine {

    /// Build a proposed rebalance from current holdings toward the derived policy target.
    static func rebalancePlan(_ h: Household, policy: InvestmentPolicy, tax: TaxParameterSet, asOf: IsoDate) -> RebalancePlan {
        let total = max(1, h.portfolioValueUsd)
        let reb = policy.rebalance
        let correction = Double(reb.correctionFractionBps) / 10000        // e.g. 0.60
        let excludedLiquidity = Set(reb.excludedLiquidityClasses)

        // --- Sleeve gaps: current vs derived target, flagged in/out of band.
        // Built and consumed in policy.sleeves order so a plan reproduces exactly. ---
        var gaps: [RebalanceSleeveGap] = []
        for s in policy.sleeves {
            let currentUsd = h.positions.filter { $0.sleeveId == s.id }.reduce(0) { $0 + $1.marketValueUsd }
            let currentBps = (currentUsd / total).bps
            let drift = currentBps - s.targetBps
            let outer = Int(Double(s.bandBps) * reb.outerBandMultiplier)
            let status: AllocationRow.Status = abs(drift) >= outer ? .outerBreach : (abs(drift) >= s.bandBps ? .innerBreach : .within)
            let fullGap = s.targetBps.frac * total - currentUsd
            let excluded = excludedLiquidity.contains(s.liquidityClass)
            let traded = status != .within && !excluded && abs(fullGap * correction) >= reb.minTradeUsd
            gaps.append(RebalanceSleeveGap(sleeveId: s.id, label: s.label, currentBps: currentBps,
                targetBps: s.targetBps, gapUsd: fullGap, status: status, traded: traded))
        }

        // --- Budgets: the binding remaining realized-gain headroom ---
        let transitionRemaining = h.transitionGainBudgetUsd > 0
            ? max(0, h.transitionGainBudgetUsd - h.transitionAnnualRealizedGainUsd) : Double.greatestFiniteMagnitude
        let policyBudget = reb.realizedGainBudgetBps.map { Double($0) / 10000 * total } ?? .greatestFiniteMagnitude
        let budgetCap = min(transitionRemaining, policyBudget)     // NET realized-gain headroom for this plan
        let hasBudget = budgetCap < .greatestFiniteMagnitude
        var budgetBinds = false

        // --- Sells: raise from overweight, out-of-band sleeves, tax-aware ---
        var trades: [RebalanceTrade] = []
        var totalSells: Usd = 0
        var netRealizedGain: Usd = 0
        var totalST: Usd = 0, totalLT: Usd = 0
        var heldOutUsd: Usd = 0

        for gap in gaps where gap.traded && gap.gapUsd < 0 {
            var raise = -gap.gapUsd * correction
            let all = h.positions.filter { $0.sleeveId == gap.sleeveId }
            heldOutUsd += all.filter { !isSellable($0) }.reduce(0) { $0 + $1.marketValueUsd }
            let candidates = all.filter { isSellable($0) }
                .sorted { sellRank($0, treatment: h.treatment(of: $0)) < sellRank($1, treatment: h.treatment(of: $1)) }
            for p in candidates {
                if raise <= 1 { break }
                let t = h.treatment(of: p)
                var sellUsd = min(raise, p.marketValueUsd)
                let gainFrac = p.marketValueUsd > 0 ? p.unrealizedGainUsd / p.marketValueUsd : 0
                var lotGain = sellUsd * gainFrac
                if t == .taxable && lotGain > 0 && hasBudget {           // a taxable gain draws on the NET budget
                    // Remaining NET headroom: losses already sold this run have credited it
                    // back (they lowered netRealizedGain), matching how the plan reports and
                    // taxes the net gain. Applied greedily in policy order.
                    let room = budgetCap - netRealizedGain
                    if room <= 0 { budgetBinds = true; continue }
                    if lotGain > room {                                  // sell only the slice whose gain fits
                        budgetBinds = true
                        sellUsd = gainFrac > 0 ? room / gainFrac : sellUsd
                        lotGain = sellUsd * gainFrac
                    }
                }
                if sellUsd < 1 { continue }
                // Actual short/long-term split of the (possibly budget-capped) slice.
                // Lowest-gain lots sell first, so the split total never exceeds the cap.
                let (stSlice, ltSlice) = (t == .taxable) ? p.realizedGainSplit(sellUsd: sellUsd, asOf: asOf) : (0, 0)
                let taxableGain = stSlice + ltSlice
                totalSells += sellUsd; netRealizedGain += taxableGain; totalST += stSlice; totalLT += ltSlice
                trades.append(RebalanceTrade(id: "sell-\(p.id)", side: .sell, ticker: p.ticker,
                    accountId: p.accountId, accountLabel: h.account(p.accountId)?.label ?? p.accountId,
                    treatment: t, sleeveId: gap.sleeveId, sleeveLabel: gap.label, amountUsd: sellUsd,
                    realizedGainUsd: taxableGain, shortTermGainUsd: stSlice, longTermGainUsd: ltSlice,
                    rationale: sellRationale(p, treatment: t)))
                raise -= sellUsd
            }
        }

        // --- Buys: fund underweight, out-of-band sleeves, scaled to what the sells raised ---
        let desiredBuys = gaps.filter { $0.traded && $0.gapUsd > 0 }.reduce(0) { $0 + $1.gapUsd * correction }
        let scale = desiredBuys > 0 ? min(1.0, totalSells / desiredBuys) : 0
        var totalBuys: Usd = 0
        for gap in gaps where gap.traded && gap.gapUsd > 0 {
            guard let sleeve = policy.sleeve(gap.sleeveId) else { continue }
            let buyUsd = gap.gapUsd * correction * scale
            if buyUsd < reb.minTradeUsd { continue }
            let ticker = sleeve.primaryTicker
            let acct = preferredAccount(for: sleeve, accounts: h.accounts)
            totalBuys += buyUsd
            trades.append(RebalanceTrade(id: "buy-\(gap.sleeveId)", side: .buy, ticker: ticker,
                accountId: acct?.id ?? "", accountLabel: acct?.label ?? "any account",
                treatment: acct?.treatment ?? .taxable, sleeveId: gap.sleeveId,
                sleeveLabel: gap.label, amountUsd: buyUsd, realizedGainUsd: 0,
                rationale: buyRationale(sleeve, ticker: ticker)))
        }

        // Wash sale: a harvested LOSS whose security the plan also BUYS (within the 31-day
        // window) has that loss DISALLOWED — but only in proportion to the replacement
        // bought (§1091), and detected on the loss COMPONENT of a trade, so a loss lot
        // inside a net-gain sell still counts. Disallowed losses are added back before
        // taxing. A TLH partner is a different, not-substantially-identical fund, so it
        // never trips this.
        var boughtByTicker: [String: Usd] = [:]
        for t in trades where t.side == .buy { boughtByTicker[t.ticker, default: 0] += t.amountUsd }
        let washSells = trades.filter { $0.side == .sell && (boughtByTicker[$0.ticker] ?? 0) > 0
            && min(0, $0.shortTermGainUsd) + min(0, $0.longTermGainUsd) < 0 }
        var disallowedST: Usd = 0, disallowedLT: Usd = 0
        for s in washSells {
            let frac = s.amountUsd > 0 ? min(1, (boughtByTicker[s.ticker] ?? 0) / s.amountUsd) : 0
            disallowedST += min(0, s.shortTermGainUsd) * frac
            disallowedLT += min(0, s.longTermGainUsd) * frac
        }
        let washSaleDisallowed = -(disallowedST + disallowedLT)
        let estTax = capitalGainsTaxAggregate(h, shortTerm: totalST - disallowedST, longTerm: totalLT - disallowedLT, asOf: asOf)
        let fundingGap = max(0, desiredBuys - totalSells)
        let excessCash = max(0, totalSells - totalBuys)

        var warnings: [String] = []
        if washSaleDisallowed > 1 {
            let tickers = Set(washSells.map { $0.ticker }).sorted().joined(separator: ", ")
            warnings.append("Wash sale: the plan harvests a loss on \(tickers) while also buying it within \(reb.washSaleWindowDays) days — \(Fmt.usdShort(washSaleDisallowed)) of the loss is DISALLOWED (in proportion to the replacement, added back to the taxable gain). Replace it with a not-substantially-identical fund (a TLH partner) instead.")
        }
        if budgetBinds {
            warnings.append("Selling stopped at the \(Fmt.usdShort(budgetCap)) net realized-gain budget. The rest of the rebalance is deferred — carry it to next tax year, or fund it from losses or new cash.")
        }
        if fundingGap > total / 1000 {
            warnings.append("Underweight sleeves need \(Fmt.usdShort(desiredBuys)) but the sells raised \(Fmt.usdShort(totalSells)); buys are scaled to \(Fmt.pct(scale)). Close the rest with new contributions.")
        }
        if excessCash > total / 1000 {
            warnings.append("Sells raised \(Fmt.usdShort(excessCash)) more than the underweight buys absorb — the surplus lands in the cash sleeve until the next underweight opens up.")
        }
        if heldOutUsd > total / 1000 {
            warnings.append("\(Fmt.usdShort(heldOutUsd)) sits in step-up / gift / charitable lots held out of selling by their disposition — an overweight sleeve can stay overweight by design.")
        }
        if trades.isEmpty {
            warnings.append("Every sleeve is inside its no-trade band. Nothing to rebalance — the bands are doing their job.")
        }

        let grossTraded = totalBuys + totalSells
        return RebalancePlan(trades: trades, sleeveGaps: gaps, totalBuysUsd: totalBuys, totalSellsUsd: totalSells,
            turnoverBps: (grossTraded / total).bps, realizedGainUsd: netRealizedGain,
            realizedShortTermUsd: totalST, realizedLongTermUsd: totalLT, estTaxUsd: estTax,
            correctionFractionBps: reb.correctionFractionBps,
            gainBudgetUsd: hasBudget ? budgetCap : 0, budgetBinds: budgetBinds,
            fundingGapUsd: fundingGap, excessCashUsd: excessCash, washSaleDisallowedUsd: washSaleDisallowed,
            heldOutUsd: heldOutUsd, warnings: warnings, asOf: asOf)
    }

    // MARK: - helpers

    /// A position may be sold only if no terminal disposition earmarks it to be held.
    static func isSellable(_ p: Position) -> Bool {
        if p.holdToStepUp { return false }
        switch p.disposition {
        case .holdToStepUp, .giftDuringLife, .charitableAtDeath: return false
        case .stepUpThenSell, .consume: return true
        }
    }

    /// Sell-order rank (lower = sell first): sheltered (0) before taxable losses (1)
    /// before taxable gains (2+, ordered so the lowest gain-per-dollar sells first).
    private static func sellRank(_ p: Position, treatment: AccountTaxTreatment) -> Double {
        if treatment != .taxable { return 0 }
        if p.unrealizedGainUsd < 0 { return 1 }
        return 2 + (1 - Double(p.basisRatioBps) / 10000)   // higher basis ratio → less gain → sell sooner
    }

    private static func preferredAccount(for sleeve: Sleeve, accounts: [Account]) -> Account? {
        for pref in sleeve.locationPreference {
            if let a = accounts.first(where: { $0.treatment == pref }) { return a }
        }
        return accounts.first
    }

    private static func sellRationale(_ p: Position, treatment: AccountTaxTreatment) -> String {
        if treatment != .taxable { return "In a \(treatment.short.lowercased()) account — no tax on the sale." }
        if p.unrealizedGainUsd < 0 { return "Harvests a \(Fmt.usdShort(-p.unrealizedGainUsd)) loss." }
        let gainPct = p.marketValueUsd > 0 ? Int((p.unrealizedGainUsd / p.marketValueUsd * 100).rounded()) : 0
        return "Lowest-gain taxable lot (~\(gainPct)% embedded gain)."
    }

    private static func buyRationale(_ sleeve: Sleeve, ticker: String) -> String {
        let loc = sleeve.locationPreference.first.map { " · best held \($0.short.lowercased())" } ?? ""
        return "Fund \(sleeve.label) with \(ticker)\(loc)."
    }
}
