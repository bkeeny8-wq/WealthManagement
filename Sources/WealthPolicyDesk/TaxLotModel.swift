//  TaxLotModel.swift
//  WealthPolicyDesk
//
//  Real tax lots — the layer that lets the engine tell SHORT-term from LONG-term
//  capital gains instead of assuming everything is long-term. A Position may carry
//  real lots (each with a cost basis and an acquisition date); when it does, a
//  realized gain splits by holding period, and a short-term gain is taxed as
//  ORDINARY income rather than at the lower long-term rate. A position with no lots
//  keeps the app's original behaviour: one aggregated lot of unknown vintage, taxed
//  long-term.
//
//  Pure and deterministic: the holding period compares two given date strings
//  (the lot's acquisition date and the plan's asOf) — no clock is read.

import Foundation

public struct TaxLot: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var marketValueUsd: Usd
    public var costBasisUsd: Usd
    public var acquisitionDate: IsoDate          // "YYYY-MM-DD"
    public init(id: String, marketValueUsd: Usd, costBasisUsd: Usd, acquisitionDate: IsoDate) {
        self.id = id; self.marketValueUsd = marketValueUsd
        self.costBasisUsd = costBasisUsd; self.acquisitionDate = acquisitionDate
    }
    public var unrealizedGainUsd: Usd { marketValueUsd - costBasisUsd }

    /// Long-term = held about a year or more (IRS: more than one year). Compares the
    /// acquisition date + 1 year against asOf on (year, month-day); an unparseable date
    /// defaults to long-term (matches the "unknown vintage" assumption).
    public func isLongTerm(asOf: IsoDate) -> Bool {
        guard acquisitionDate.count >= 10, asOf.count >= 10,
              let ay = Int(acquisitionDate.prefix(4)), let sy = Int(asOf.prefix(4)) else { return true }
        if sy > ay + 1 { return true }
        if sy < ay + 1 { return false }
        return String(asOf.dropFirst(4)) > String(acquisitionDate.dropFirst(4))   // MORE than a year: the anniversary day itself is still short-term
    }
}

public extension Position {
    /// Embedded unrealized gain split by holding period (signed). No lots → all long-term.
    func gainSplit(asOf: IsoDate) -> (shortTerm: Usd, longTerm: Usd) {
        guard !lots.isEmpty else { return (0, unrealizedGainUsd) }
        var st: Usd = 0, lt: Usd = 0
        for lot in lots { if lot.isLongTerm(asOf: asOf) { lt += lot.unrealizedGainUsd } else { st += lot.unrealizedGainUsd } }
        return (st, lt)
    }

    /// The short/long-term gain realized by selling `sellUsd`, choosing lots tax-first:
    /// losses (to harvest) → long-term lowest-gain → short-term last (defer ordinary-rate
    /// gains). No lots → the whole slice is long-term (unknown vintage).
    func realizedGainSplit(sellUsd: Usd, asOf: IsoDate) -> (shortTerm: Usd, longTerm: Usd) {
        let r = afterSelling(sellUsd: sellUsd, asOf: asOf)
        return (r.shortTerm, r.longTerm)
    }

    /// Sell `sellUsd` choosing lots tax-first, and return the SPECIFIC lots' realized
    /// short/long-term gain together with the position after exactly those lots are
    /// removed (basis and lots kept consistent) — so a committed sale seasons the right
    /// lots. No lots → pro-rata shrink, long-term (unknown vintage).
    func afterSelling(sellUsd: Usd, asOf: IsoDate) -> (shortTerm: Usd, longTerm: Usd, position: Position) {
        let sell = min(max(0, sellUsd), marketValueUsd)
        guard !lots.isEmpty else {
            let frac = marketValueUsd > 0 ? sell / marketValueUsd : 0
            var p = self
            p.marketValueUsd = marketValueUsd - sell
            p.costBasisUsd = costBasisUsd * (1 - frac)
            return (0, unrealizedGainUsd * frac, p)
        }
        func rank(_ l: TaxLot) -> (Int, Double) {
            if l.unrealizedGainUsd < 0 { return (0, l.unrealizedGainUsd) }              // losses first, most-negative first
            let perDollar = l.marketValueUsd > 0 ? l.unrealizedGainUsd / l.marketValueUsd : 0
            return (l.isLongTerm(asOf: asOf) ? 1 : 2, perDollar)                        // LT before ST; lowest gain first
        }
        let ordered = lots.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b)); return ra.0 != rb.0 ? ra.0 < rb.0 : ra.1 < rb.1
        }
        var remaining = sell, st: Usd = 0, lt: Usd = 0, newLots: [TaxLot] = []
        for lot in ordered {
            guard remaining > 0.005 else { newLots.append(lot); continue }
            let take = min(remaining, lot.marketValueUsd)
            let frac = lot.marketValueUsd > 0 ? take / lot.marketValueUsd : 0
            let g = lot.unrealizedGainUsd * frac
            if lot.isLongTerm(asOf: asOf) { lt += g } else { st += g }
            remaining -= take
            let leftMV = lot.marketValueUsd - take
            if leftMV > 0.01 {                                                          // keep the un-sold remainder of a partially-sold lot
                newLots.append(TaxLot(id: lot.id, marketValueUsd: leftMV,
                                      costBasisUsd: lot.costBasisUsd * (1 - frac), acquisitionDate: lot.acquisitionDate))
            }
        }
        var p = self
        p.lots = newLots
        p.marketValueUsd = newLots.reduce(0) { $0 + $1.marketValueUsd }
        p.costBasisUsd = newLots.reduce(0) { $0 + $1.costBasisUsd }
        return (st, lt, p)
    }
}

public extension Engine {
    /// Federal tax on a realized gain split into short- and long-term components:
    /// short-term stacks as ORDINARY income; long-term stacks above it at LTCG rates;
    /// unused standard deduction shelters short-term first then long-term; NIIT applies
    /// to both. ST and LT losses cross-offset (a simplified §1(h) netting). Inputs are
    /// signed; a net loss yields zero tax here.
    static func capitalGainsTax(shortTerm stIn: Usd, longTerm ltIn: Usd,
                                grossOrdinary: Usd, ordinaryTaxable: Usd,
                                filing: FilingStatus, tax: TaxParameterSet) -> Usd {
        var st = stIn, lt = ltIn
        if st < 0 { lt += st; st = 0 }               // ST loss offsets LT
        if lt < 0 { st += lt; lt = 0 }               // LT loss offsets ST
        st = max(0, st); lt = max(0, lt)
        guard st + lt > 0 else { return 0 }
        let stdDed = tax.standardDeduction[filing] ?? 0
        var unused = max(0, stdDed - grossOrdinary)  // standard deduction the ordinary income didn't absorb
        let stShelter = min(st, unused); unused -= stShelter
        let taxableST = st - stShelter
        let taxableLT = max(0, lt - min(lt, unused))
        let ordBrackets = tax.ordinaryBrackets[filing] ?? []
        let ordinaryOnST = progressiveTax(ordinaryTaxable + taxableST, brackets: ordBrackets)
                         - progressiveTax(ordinaryTaxable, brackets: ordBrackets)
        let ltcg = ltcgTaxStacked(taxableLT, ordinaryTaxable: ordinaryTaxable + taxableST,
                                  breakpoints: tax.ltcgBreakpoints[filing] ?? [])
        let niit = niitTax(magi: grossOrdinary + st + lt, netInvestmentIncome: st + lt, filing: filing, tax: tax)
        return ordinaryOnST + ltcg + niit
    }

    /// Tax on an aggregated realized gain (short + long term), stacking once — the
    /// short/long-term generalization of ltcgTaxOnGain.
    static func capitalGainsTaxAggregate(_ h: Household, shortTerm: Usd, longTerm: Usd,
                                         asOf: IsoDate = planningAsOf) -> Usd {
        let totalGain = max(0, shortTerm + longTerm)
        let (grossOrdinary, ordinaryTaxable) = currentOrdinaryIncome(h, asOf: asOf, capGains: totalGain)
        return capitalGainsTax(shortTerm: shortTerm, longTerm: longTerm,
                               grossOrdinary: grossOrdinary, ordinaryTaxable: ordinaryTaxable,
                               filing: h.filingStatus, tax: Seed.tax2026)
    }

    /// The taxable book's embedded unrealized gains split by holding period (excluding
    /// hold-to-step-up lots, which extinguish at death), and the tax if realized today —
    /// short-term as ordinary, long-term at LTCG. `longTermOnlyTaxUsd` taxes the same
    /// gain as if it were all long-term; the gap is the short-term penalty.
    static func embeddedGains(_ h: Household, asOf: IsoDate = planningAsOf)
        -> (shortTerm: Usd, longTerm: Usd, taxUsd: Usd, longTermOnlyTaxUsd: Usd, hasLots: Bool) {
        var st: Usd = 0, lt: Usd = 0, hasLots = false
        for p in h.positions where h.treatment(of: p) == .taxable && !p.holdToStepUp {
            if !p.lots.isEmpty { hasLots = true }
            let (s, l) = p.gainSplit(asOf: asOf); st += s; lt += l
        }
        return (st, lt,
                capitalGainsTaxAggregate(h, shortTerm: st, longTerm: lt, asOf: asOf),
                capitalGainsTaxAggregate(h, shortTerm: 0, longTerm: st + lt, asOf: asOf),
                hasLots)
    }
}
