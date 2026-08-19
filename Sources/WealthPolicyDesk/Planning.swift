//  Planning.swift
//  WealthPolicyDesk
//
//  The planning / action layer. A PlannedAction is a discrete advisor move —
//  sell part or all of one holding and rotate the proceeds into another
//  instrument (e.g. "sell XLK, shift into Consumer Staples / XLP"). It is the
//  first thing on this desk that CHANGES the plan rather than just reading it.
//
//  Design (chosen with the user): "both, explicit commit". A move is composed
//  and STAGED against a draft copy of the household, so the whole desk previews
//  its effect live and non-destructively. Nothing touches the client of record
//  until an explicit COMMIT, which persists the move onto the ClientRecord as a
//  recorded action (its own thesis + review date + status) — a plan of record.
//
//  Moves are equal-dollar by construction: the sale funds the purchase, so total
//  portfolio value is unchanged. What moves is sleeve / sector exposure and — if
//  the sold lot lives in a TAXABLE account — realized capital gains. The engine
//  stays pure, so a move's effect is just Engine.evaluate(household.applying(a)).

import Foundation

// MARK: - Sector <- SPDR ticker (reverse of Sector.spdrTicker)

public extension Sector {
    /// The GICS sector a Select Sector SPDR ticker implements, if it is one.
    static func fromSpdr(_ ticker: String) -> Sector? {
        Sector.allCases.first { $0.spdrTicker == ticker }
    }
}

// MARK: - A planned move

/// Sell `sellUsd` of the holding identified by (account, ticker) and rotate the
/// proceeds into `buyTicker`. Persisted per client once committed.
public struct PlannedAction: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable, Hashable {
        case staged      // previewing on the desk; not saved
        case committed   // written to the client's plan of record
    }
    public var id: UUID
    public var createdAt: Date
    public var sellAccountId: String
    public var sellTicker: String
    public var sellUsd: Usd
    public var buyTicker: String
    public var buySleeveId: String?
    /// Sector.rawValue when this is a sector rotation (drives sector visibility).
    public var buySectorRaw: String?
    public var thesis: String
    /// nil = no review date scheduled.
    public var reviewDate: Date?
    public var status: Status

    public init(id: UUID = UUID(), createdAt: Date = Date(), sellAccountId: String, sellTicker: String, sellUsd: Usd, buyTicker: String, buySleeveId: String? = nil, buySectorRaw: String? = nil, thesis: String = "", reviewDate: Date? = nil, status: Status = .staged) {
        self.id = id; self.createdAt = createdAt
        self.sellAccountId = sellAccountId; self.sellTicker = sellTicker; self.sellUsd = sellUsd
        self.buyTicker = buyTicker; self.buySleeveId = buySleeveId; self.buySectorRaw = buySectorRaw
        self.thesis = thesis; self.reviewDate = reviewDate; self.status = status
    }

    public var buySector: Sector? { buySectorRaw.flatMap(Sector.init(rawValue:)) }

    /// Forward-compatible decode: a missing/renamed field never drops the action.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        createdAt = ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil) ?? Date()
        sellAccountId = ((try? c.decodeIfPresent(String.self, forKey: .sellAccountId)) ?? nil) ?? ""
        sellTicker = ((try? c.decodeIfPresent(String.self, forKey: .sellTicker)) ?? nil) ?? ""
        sellUsd = ((try? c.decodeIfPresent(Usd.self, forKey: .sellUsd)) ?? nil) ?? 0
        buyTicker = ((try? c.decodeIfPresent(String.self, forKey: .buyTicker)) ?? nil) ?? ""
        buySleeveId = (try? c.decodeIfPresent(String.self, forKey: .buySleeveId)) ?? nil
        buySectorRaw = (try? c.decodeIfPresent(String.self, forKey: .buySectorRaw)) ?? nil
        thesis = ((try? c.decodeIfPresent(String.self, forKey: .thesis)) ?? nil) ?? ""
        reviewDate = (try? c.decodeIfPresent(Date.self, forKey: .reviewDate)) ?? nil
        status = ((try? c.decodeIfPresent(Status.self, forKey: .status)) ?? nil) ?? .committed
    }
}

// MARK: - Applying a move to the household (pure)

public extension Household {
    /// Return a copy with the move applied: shrink/remove the sold lot, and grow
    /// or create the bought lot in the same account. Equal-dollar — the sale
    /// funds the buy, so portfolio value is unchanged. The bought lot's basis is
    /// its purchase price (a fresh, at-market cost basis). A move whose sold
    /// holding no longer exists (e.g. after an intake change) is a safe no-op.
    func applying(_ a: PlannedAction) -> Household {
        var h = self
        let want = max(0, a.sellUsd)
        guard want > 0,
              let i = h.positions.firstIndex(where: { $0.accountId == a.sellAccountId && $0.ticker == a.sellTicker })
        else { return h }

        let sold = h.positions[i]
        let sell = min(want, sold.marketValueUsd)
        guard sell > 0 else { return h }
        let frac = sold.marketValueUsd > 0 ? sell / sold.marketValueUsd : 0
        let newMV = sold.marketValueUsd - sell
        let removed = newMV <= 1                                  // no ≤$1 dust lot left behind
        let proceeds = removed ? sold.marketValueUsd : sell       // what actually leaves the sold lot

        // A taxable sale realizes tax, paid in cash from the proceeds — so only the
        // remainder is reinvested and the portfolio genuinely shrinks by the tax.
        // In a sheltered account the tax is $0, so the full proceeds rotate.
        let tax = Engine.realizedGainTaxOn(self, sold, sellUsd: proceeds).taxUsd
        let reinvest = max(0, proceeds - tax)

        // 1) Reduce (or remove) the sold lot, shrinking basis — and its tax lots —
        //    proportionally (an approximate pro-rata sale that keeps the aggregate
        //    consistent with the per-lot detail).
        if removed {
            h.positions.remove(at: i)
        } else {
            h.positions[i].marketValueUsd = newMV
            h.positions[i].costBasisUsd = sold.costBasisUsd * (1 - frac)
            h.positions[i].lots = sold.lots.map {
                TaxLot(id: $0.id, marketValueUsd: $0.marketValueUsd * (1 - frac),
                       costBasisUsd: $0.costBasisUsd * (1 - frac), acquisitionDate: $0.acquisitionDate)
            }
        }

        // 2) Grow an existing bought lot, or create one, in the same account. A freshly
        //    bought lot is dated today, so it is correctly short-term until it seasons.
        let freshLot = TaxLot(id: "\(a.sellAccountId)_\(a.buyTicker)_\(a.id.uuidString.prefix(8))",
                              marketValueUsd: reinvest, costBasisUsd: reinvest, acquisitionDate: Engine.planningAsOf)
        let sleeveForBuy = a.buySleeveId ?? sold.sleeveId
        if let j = h.positions.firstIndex(where: { $0.accountId == a.sellAccountId && $0.ticker == a.buyTicker }) {
            h.positions[j].marketValueUsd += reinvest
            h.positions[j].costBasisUsd += reinvest
            if !h.positions[j].lots.isEmpty { h.positions[j].lots.append(freshLot) }   // keep the empty=aggregate invariant
            if let sec = a.buySector { h.positions[j].sector = sec }
        } else {
            h.positions.append(Position(
                id: "\(a.sellAccountId)_plan_\(a.buyTicker)",
                accountId: a.sellAccountId, ticker: a.buyTicker, sleeveId: sleeveForBuy,
                marketValueUsd: reinvest, costBasisUsd: reinvest, layer: sold.layer,
                disposition: sold.disposition, holdToStepUp: false, isConcentrated: false,
                sector: a.buySector, lots: [freshLot]))
        }
        return h
    }

    /// Fold a list of moves in order.
    func applying(_ actions: [PlannedAction]) -> Household {
        actions.reduce(self) { $0.applying($1) }
    }

    /// Replay diagnostics: fold the actions and report, per action, whether it
    /// still resolves against the portfolio and how much actually sells. Surfaces
    /// a committed move whose sold holding an intake edit later removed, renamed,
    /// or shrank — so it would silently no-op or clamp on replay.
    func replayStatuses(_ actions: [PlannedAction]) -> [CommittedMoveStatus] {
        var h = self
        var out: [CommittedMoveStatus] = []
        for a in actions {
            let pos = h.positions.first { $0.accountId == a.sellAccountId && $0.ticker == a.sellTicker }
            let applied = pos.map { min(max(0, a.sellUsd), $0.marketValueUsd) } ?? 0
            out.append(CommittedMoveStatus(action: a, resolved: pos != nil && applied > 1, appliedUsd: applied))
            h = h.applying(a)
        }
        return out
    }
}

/// The replay state of one committed move against the current portfolio.
public struct CommittedMoveStatus: Identifiable, Hashable, Sendable {
    public var action: PlannedAction
    public var resolved: Bool       // the sold holding still exists
    public var appliedUsd: Usd      // amount actually sold on replay (may clamp below action.sellUsd)
    public var id: UUID { action.id }
    public var clamped: Bool { resolved && appliedUsd + 1 < action.sellUsd }
}

// MARK: - Realized-gain tax preview (pure)

public extension Engine {
    static let planningAsOf: IsoDate = "2026-08-11"

    /// The capital-gains tax that selling `sellUsd` of `p` in `h` realizes TODAY.
    /// Zero inside a tax-deferred or Roth account. For a taxable lot: an estimated
    /// long-term cap-gains tax (assumes a long-term holding — Position carries no
    /// acquisition date) stacked on the household's CURRENT ordinary income
    /// (wages + pension + RMD + taxable Social Security), with the unused standard
    /// deduction sheltering the gain and NIIT on top — mirroring the decumulation
    /// engine's own year tax. The returned gain is SIGNED (a loss is negative).
    static func realizedGainTaxOn(_ h: Household, _ p: Position, sellUsd: Usd, asOf: IsoDate = Engine.planningAsOf) -> (gainUsd: Usd, taxUsd: Usd, taxable: Bool, ordinaryTaxableUsd: Usd) {
        let sell = min(max(0, sellUsd), p.marketValueUsd)
        let frac = p.marketValueUsd > 0 ? sell / p.marketValueUsd : 0
        let rawGain = p.unrealizedGainUsd * frac                 // signed: a loss stays negative
        guard h.treatment(of: p) == .taxable else { return (rawGain, 0, false, 0) }
        // Split the realized gain by holding period; short-term is taxed as ordinary. A
        // position with no lots yields (0, rawGain) — the original long-term assumption.
        let (st, lt) = p.realizedGainSplit(sellUsd: sell, asOf: asOf)
        let (grossOrdinary, ordinaryTaxable) = currentOrdinaryIncome(h, asOf: asOf, capGains: max(0, st + lt))
        let taxUsd = capitalGainsTax(shortTerm: st, longTerm: lt, grossOrdinary: grossOrdinary,
                                     ordinaryTaxable: ordinaryTaxable, filing: h.filingStatus, tax: Seed.tax2026)
        return (rawGain, taxUsd, true, ordinaryTaxable)
    }

    /// Action-level convenience.
    static func realizedGainTax(_ h: Household, _ a: PlannedAction, asOf: IsoDate = Engine.planningAsOf) -> (gainUsd: Usd, taxUsd: Usd, taxable: Bool, ordinaryTaxableUsd: Usd) {
        guard let p = h.positions.first(where: { $0.accountId == a.sellAccountId && $0.ticker == a.sellTicker }) else {
            return (0, 0, false, 0)
        }
        return realizedGainTaxOn(h, p, sellUsd: a.sellUsd, asOf: asOf)
    }

    /// The tax on an already-aggregated realized gain — for stacking several
    /// taxable moves and taxing the total once, rather than each in isolation
    /// (independent per-move taxing understates by ignoring bracket stacking).
    static func ltcgTaxOnGain(_ h: Household, gain: Usd, asOf: IsoDate = Engine.planningAsOf) -> Usd {
        // A long-term-only gain; the short/long-term-aware path with shortTerm: 0.
        capitalGainsTaxAggregate(h, shortTerm: 0, longTerm: gain, asOf: asOf)
    }

    /// The household's current-year ordinary income for stacking a realized gain:
    /// wages + pension + this year's RMD + the taxable portion of Social Security.
    /// Returns (gross, taxable-after-standard-deduction). Mirrors the decumulation
    /// engine's year-0 build so the preview and the projection agree.
    static func currentOrdinaryIncome(_ h: Household, asOf: IsoDate, capGains: Usd) -> (gross: Usd, taxable: Usd) {
        let tax = Seed.tax2026
        let filing = h.filingStatus
        let stdDed = tax.standardDeduction[filing] ?? 0
        let wages = h.humanCapital.reduce(0) { $0 + $1.annualIncomeUsd }
        let pension = pensionAnnual(h, year: 0)
        var rmd: Usd = 0
        if let primary = h.primary {
            let a = age(birthDate: primary.birthDate, asOf: asOf)
            if a >= tax.rmdStartAge { rmd = h.value(in: .taxDeferred) / uniformLifetimeDivisor(a) }
        }
        let ordinaryExSS = wages + pension + rmd
        let ss = socialSecurityAnnual(h, year: 0, asOf: asOf)
        let ssTaxable = taxableSocialSecurity(ss: ss, otherIncome: ordinaryExSS + capGains, filing: filing)
        let gross = ordinaryExSS + ssTaxable
        return (gross, max(0, gross - stdDed))
    }
}
