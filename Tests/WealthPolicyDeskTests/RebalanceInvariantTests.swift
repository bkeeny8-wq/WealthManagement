import XCTest
@testable import WealthPolicyDesk

/// Properties of the rebalance plan, asserted across `HouseholdMatrix`.
///
/// This path has shipped more defects than any other in the codebase: the held-to-maturity
/// ladder sold to fund an equity buy, a charitable beneficiary designation freezing the
/// entire taxable book, proceeds spent in an account they could never reach, a location rank
/// that preferred the account a sleeve cannot be held in, buys ordered alphabetically so an
/// outer-band breach went unfunded, an underweight tilt buying the very fund its thesis
/// avoids, and a dropped buy stranding the cash it had reserved.
///
/// Each was caught by a reviewer constructing the one household that exposed it. Every
/// assertion below is written in BOTH directions — the previous invariant batch caught only
/// two of six replayed defects precisely because it asserted "never too much" and never
/// "never too little", which is the same mistake the defects themselves were.
final class RebalanceInvariantTests: XCTestCase {

    private struct Plan {
        let name: String
        let eval: Evaluation
        let policy: InvestmentPolicy
        let plan: RebalancePlan
    }

    /// Built exactly as RebalanceTab does: the derived policy with each sleeve's target
    /// overwritten by the tactical allocation the drift is measured against.
    private static func plan(_ name: String, _ h: Household) -> Plan {
        let eval = Engine.evaluate(h)
        var p = eval.legacyPolicy
        p.sleeves = p.sleeves.map { s in
            var s = s
            if let row = eval.allocation.first(where: { $0.sleeveId == s.id }) { s.targetBps = row.targetBps }
            return s
        }
        return Plan(name: name, eval: eval, policy: p,
                    plan: Engine.rebalancePlan(eval.household, policy: p, tax: eval.tax, asOf: eval.asOf))
    }

    /// Three shapes the intake-built matrix cannot express, each of which a real defect lived
    /// in. Without them the corresponding invariants are vacuous — they passed a replay of the
    /// ladder sale, the sells-based funding gap and the cash-stranding dropped buy, because no
    /// household in the matrix has a ladder, a committed tilt, or proceeds that strand.
    private static var structuralCases: [Plan] {
        var out: [Plan] = []

        // The shipped sample is the only household with a held-to-maturity LADDER, which is
        // what the sell ladder reached for first when the earmark guard was removed.
        out.append(plan("shipped sample (has a ladder)", Seed.sampleHousehold))

        // A committed UNDERWEIGHT on the sector sleeve's own default instrument: the state in
        // which no instrument has a thesis and no buy should be proposed.
        var tilted = Seed.sampleHousehold
        if let sleeve = Seed.legacyPolicy.sleeve("us_sector_tilt") {
            tilted.tacticalTilts = [TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: -300,
                                                       sourceName: "Tech", ticker: sleeve.primaryTicker,
                                                       thesis: "trim it", status: .committed)]
        }
        out.append(plan("committed underweight on the sleeve's own default", tilted))

        // Proceeds that STRAND: a slice in a second account below the minimum trade size, so
        // sells exceed buys and only a buys-based funding gap can see the shortfall.
        var stranding = Seed.sampleHousehold
        stranding.tacticalTilts = []
        if let overweight = stranding.positions.first(where: { $0.layer == .strategic && $0.marketValueUsd > 100_000 }) {
            var slice = overweight
            slice.id = overweight.id + "_ira_slice"
            slice.accountId = stranding.accounts.first { $0.treatment == .taxDeferred }?.id ?? overweight.accountId
            slice.marketValueUsd = 800
            slice.costBasisUsd = 800
            stranding.positions.append(slice)
        }
        out.append(plan("proceeds stranded below the minimum trade size", stranding))

        // The two states no realistic household in the matrix reaches, built directly.
        // Derived policies always leave the sector sleeve overweight on the sample, so the
        // underweight-tilt path is never entered; and nothing strands, so a funding gap
        // measured against SELLS is indistinguishable from one measured against BUYS.
        func synthetic(_ id: String, _ ticker: String, target: Bps,
                       prefs: [AccountTaxTreatment]) -> Sleeve {
            Sleeve(id: id, label: id, tier: .satellite, role: .growth, targetBps: target,
                   bandBps: 50, maxBps: 10000, taxEfficiency: .moderate, locationPreference: prefs,
                   liquidityClass: .daily, instruments: [.init(ticker: ticker, role: .primary)], rationale: "")
        }
        func withPolicy(_ name: String, _ h: Household, _ sleeves: [Sleeve]) -> Plan {
            var p = Seed.legacyPolicy; p.sleeves = sleeves; p.altBudgets = []
            let eval = Engine.evaluate(h)
            return Plan(name: name, eval: eval, policy: p,
                        plan: Engine.rebalancePlan(h, policy: p, tax: Seed.tax2026, asOf: Engine.planningAsOf))
        }

        // Cash raised in an IRA, below the minimum trade size, against an underweight sleeve
        // in taxable: sells exceed buys and the shortfall is only visible from the buy side.
        var strandsForReal = Seed.sampleHousehold
        strandsForReal.tacticalTilts = []
        strandsForReal.accounts = [Account(id: "acct_taxable", label: "Brokerage", treatment: .taxable),
                                   Account(id: "acct_ira", label: "IRA", treatment: .taxDeferred)]
        strandsForReal.positions = [
            Position(id: "ira_slice", accountId: "acct_ira", ticker: "OVER", sleeveId: "zz_over",
                     marketValueUsd: 800, costBasisUsd: 800, layer: .strategic,
                     disposition: .consume, holdToStepUp: false),
            Position(id: "tax_lot", accountId: "acct_taxable", ticker: "OVER", sleeveId: "zz_over",
                     marketValueUsd: 200_000, costBasisUsd: 200_000, layer: .strategic,
                     disposition: .consume, holdToStepUp: false),
        ]
        out.append(withPolicy("stranded IRA slice against a taxable underweight", strandsForReal,
                              [synthetic("zz_over", "OVER", target: 0, prefs: [.taxable, .taxDeferred]),
                               synthetic("aa_under", "UNDER", target: 9960, prefs: [.taxable])]))

        // An UNDERWEIGHT sleeve whose only listed instrument is the one its committed tilt
        // rules out: the state in which no buy should be proposed and no cash reserved.
        var noDefensibleBuy = Seed.sampleHousehold
        noDefensibleBuy.accounts = [Account(id: "acct_taxable", label: "Brokerage", treatment: .taxable)]
        noDefensibleBuy.positions = [
            Position(id: "sellable", accountId: "acct_taxable", ticker: "SELLME", sleeveId: "zz_sell",
                     marketValueUsd: 300_000, costBasisUsd: 300_000, layer: .strategic,
                     disposition: .consume, holdToStepUp: false),
            Position(id: "locked", accountId: "acct_taxable", ticker: "SELLME", sleeveId: "zz_sell",
                     marketValueUsd: 700_000, costBasisUsd: 700_000, layer: .strategic,
                     disposition: .holdToStepUp, holdToStepUp: true),
        ]
        noDefensibleBuy.tacticalTilts = [TacticalTiltAction(sleeveId: "aa_tilted", deviationBps: -300,
                                                            sourceName: "Tilted", ticker: "TILTP",
                                                            thesis: "trim it", status: .committed)]
        out.append(withPolicy("underweight sleeve whose only instrument is ruled out", noDefensibleBuy,
                              [synthetic("zz_sell", "SELLME", target: 0, prefs: [.taxable]),
                               synthetic("aa_tilted", "TILTP", target: 6000, prefs: [.taxable]),
                               synthetic("bb_ok", "OKAY", target: 4000, prefs: [.taxable])]))

        return out
    }

    private static let plans: [Plan] = {
        HouseholdMatrix.evaluated.map { c in
            plan(c.name, c.eval.household)
        } + structuralCases
    }()
    private var plans: [Plan] { Self.plans }

    private func netByAccount(_ p: RebalancePlan) -> [String: (sold: Usd, bought: Usd)] {
        var out: [String: (sold: Usd, bought: Usd)] = [:]
        for t in p.trades {
            var e = out[t.accountId] ?? (0, 0)
            if t.side == .sell { e.sold += t.amountUsd } else { e.bought += t.amountUsd }
            out[t.accountId] = e
        }
        return out
    }

    // MARK: - The matrix must actually produce trades

    /// Every invariant below is vacuous on a household with nothing to rebalance. If the
    /// matrix stops drifting, they all pass for the wrong reason.
    func testTheMatrixProducesRealRebalancePlans() {
        let trading = plans.filter { !$0.plan.trades.isEmpty }
        XCTAssertGreaterThanOrEqual(trading.count, 8,
            "only \(trading.count) households produce trades — the rebalance invariants are mostly vacuous")
        XCTAssertTrue(trading.contains { $0.plan.trades.contains { $0.side == .sell } }, "no sells anywhere")
        XCTAssertTrue(trading.contains { $0.plan.trades.contains { $0.side == .buy } }, "no buys anywhere")

        // The three structural shapes, each of which a real defect lived in. A replay of
        // those defects passes silently if the corresponding shape is missing.
        XCTAssertTrue(plans.contains { p in p.eval.household.positions.contains { $0.layer == .ladder } },
                      "no household holds a ladder — the ladder invariant is vacuous")
        XCTAssertTrue(plans.contains { !$0.eval.household.tacticalTilts.isEmpty },
                      "no household carries a committed tilt — the instrument invariants are vacuous")
        XCTAssertTrue(plans.contains { $0.plan.excessCashUsd > 1 && $0.plan.fundingGapUsd > 1 },
                      "no household both strands proceeds AND has a shortfall — a sells-based funding gap is indistinguishable from a buys-based one")
        XCTAssertTrue(plans.contains { p in
            p.plan.sleeveGaps.contains { gap in
                guard gap.traded, gap.gapUsd > 0, let sleeve = p.policy.sleeve(gap.sleeveId) else { return false }
                return Engine.buyTicker(for: sleeve, household: p.eval.household,
                                        style: p.eval.household.equityStyle).isEmpty
            }
        }, "no household has an UNDERWEIGHT sleeve whose instrument is ruled out — the dropped-buy invariant is vacuous")
    }

    // MARK: - Cash

    /// Money cannot cross an account boundary — and the mirror: an account that raised cash
    /// and has an underweight sleeve it can hold must SPEND it. Dropping an unfundable buy
    /// after allocation left $300,000 sitting idle while a perfectly fundable sleeve beside
    /// it stayed out of band.
    func testAnAccountSpendsWhatItRaisedAndNoMore() {
        for p in plans {
            for (accountId, e) in netByAccount(p.plan) {
                XCTAssertLessThanOrEqual(e.bought, e.sold + 0.5,
                    "\(p.name): \(accountId) spent \(Int(e.bought)) having raised \(Int(e.sold))")
            }
            // Mirror: idle proceeds are only defensible when nothing is left to fund.
            let idle = p.plan.excessCashUsd
            guard idle > p.eval.household.portfolioValueUsd / 1000 else { continue }
            let unfunded = p.plan.sleeveGaps.filter { $0.traded && $0.gapUsd > 0 }
                .filter { gap in !p.plan.trades.contains { $0.side == .buy && $0.sleeveId == gap.sleeveId } }
                .filter { gap in
                    guard let sleeve = p.policy.sleeve(gap.sleeveId) else { return false }
                    // Only count sleeves that HAVE a defensible instrument; one ruled out by a
                    // committed underweight tilt is meant to go unfunded.
                    return !Engine.buyTicker(for: sleeve, household: p.eval.household,
                                             style: p.eval.household.equityStyle).isEmpty
                }
            XCTAssertTrue(unfunded.isEmpty,
                "\(p.name): \(Int(idle)) of proceeds sit idle while \(unfunded.map(\.sleeveId)) are underweight and fundable")
        }
    }

    /// The reported totals are the trades. A plan whose headline figures disagree with its
    /// own ticket list is not a plan.
    func testTheReportedTotalsAreTheTrades() {
        for p in plans {
            let buys = p.plan.trades.filter { $0.side == .buy }.reduce(0) { $0 + $1.amountUsd }
            let sells = p.plan.trades.filter { $0.side == .sell }.reduce(0) { $0 + $1.amountUsd }
            XCTAssertEqual(p.plan.totalBuysUsd, buys, accuracy: 0.5, "\(p.name)")
            XCTAssertEqual(p.plan.totalSellsUsd, sells, accuracy: 0.5, "\(p.name)")
            XCTAssertEqual(p.plan.excessCashUsd, max(0, sells - buys), accuracy: 0.5, "\(p.name)")
        }
    }

    /// The funding gap measures what could not be BOUGHT. Measuring it against SELLS made
    /// stranded cash — proceeds below the minimum trade size, or in an account with nothing
    /// it can hold — report as no gap at all.
    func testTheFundingGapMeasuresWhatWasNotBought() {
        for p in plans {
            let desired = p.plan.sleeveGaps.filter { $0.traded && $0.gapUsd > 0 }
                .reduce(0) { $0 + $1.gapUsd * Double(p.policy.rebalance.correctionFractionBps) / 10_000 }
            XCTAssertEqual(p.plan.fundingGapUsd, max(0, desired - p.plan.totalBuysUsd), accuracy: 1,
                "\(p.name): the gap does not equal what went unbought")
        }
    }

    // MARK: - What may be sold

    /// The ladder funds dated near-term spending and is held to maturity. Because sheltered
    /// lots rank ahead of every taxable lot it was the FIRST thing the sell ladder reached
    /// for — raising a fixed-income breach by liquidating the ladder, in the same evaluation
    /// that raised a hard finding for being short of defensive assets.
    func testNoSellEverTouchesALadderRungOrAnEarmarkedLot() {
        for p in plans {
            for t in p.plan.trades where t.side == .sell {
                guard let sold = p.eval.household.positions
                    .first(where: { $0.ticker == t.ticker && $0.accountId == t.accountId }) else { continue }
                XCTAssertNotEqual(sold.layer, .ladder, "\(p.name): sold a ladder rung (\(t.ticker))")
                XCTAssertFalse(sold.holdToStepUp, "\(p.name): sold a step-up earmark (\(t.ticker))")
                XCTAssertNotEqual(sold.disposition, .giftDuringLife, "\(p.name): sold a gift earmark (\(t.ticker))")
            }
        }
    }

    /// The mirror: a charitable beneficiary designation is routing, not an instrument lock.
    /// Treating it as one froze the ENTIRE taxable book — intake stamps it on every taxable
    /// position when the client names taxable as their bequest source — and left the plan
    /// unfundable. Routing a book to charity must not change what can be traded.
    func testACharitableBequestDoesNotFreezeTheBook() {
        for p in plans where !p.plan.trades.isEmpty {
            var routed = p.eval.household
            routed.positions = routed.positions.map { pos in
                var q = pos
                if routed.treatment(of: pos) == .taxable { q.disposition = .charitableAtDeath }
                return q
            }
            let after = Engine.rebalancePlan(routed, policy: p.policy, tax: p.eval.tax, asOf: p.eval.asOf)
            XCTAssertEqual(after.totalSellsUsd, p.plan.totalSellsUsd, accuracy: 1,
                "\(p.name): naming taxable as the bequest source changed what can be traded")
            XCTAssertEqual(after.heldOutUsd, p.plan.heldOutUsd, accuracy: 1, "\(p.name)")
        }
    }

    /// Realized gains stay inside the stated budget whenever one binds.
    func testRealizedGainsRespectTheBudget() {
        for p in plans where p.plan.budgetBinds {
            XCTAssertLessThanOrEqual(p.plan.realizedGainUsd, p.plan.gainBudgetUsd + 1,
                "\(p.name): realized \(Int(p.plan.realizedGainUsd)) against a budget of \(Int(p.plan.gainBudgetUsd))")
        }
    }

    // MARK: - What is bought, and where

    /// Every trade names an account that exists, with that account's own treatment.
    func testEveryTradeNamesARealAccount() {
        for p in plans {
            for t in p.plan.trades {
                guard let account = p.eval.household.account(t.accountId) else {
                    XCTFail("\(p.name): trade in unknown account \(t.accountId)"); continue
                }
                XCTAssertEqual(account.treatment, t.treatment,
                    "\(p.name): \(t.ticker) reports \(t.treatment) in a \(account.treatment) account")
            }
            XCTAssertFalse(p.plan.trades.contains { $0.ticker.isEmpty },
                "\(p.name): a trade with no instrument reached the ticket")
        }
    }

    /// A ticket placed outside the sleeve's preferred home says so. It used to print
    /// "best held tax-deferred" on a trade it was placing in a taxable account.
    func testASecondBestLocationIsDisclosed() {
        for p in plans {
            for t in p.plan.trades where t.side == .buy {
                guard let sleeve = p.policy.sleeve(t.sleeveId),
                      let preferred = sleeve.locationPreference.first, preferred != t.treatment else { continue }
                let r = t.rationale.lowercased()
                XCTAssertTrue(r.contains("second-best") || r.contains("not its preferred"),
                    "\(p.name): \(t.ticker) landed in \(t.treatment.short) with its preferred home \(preferred.short) unmentioned")
            }
        }
    }

    /// A committed tilt decides the instrument, in both directions: an OVERWEIGHT names what
    /// to buy, an UNDERWEIGHT names what to avoid and licenses no substitute. Honouring the
    /// ticker unconditionally made a "short technology" view buy financials, picked by
    /// declaration order; ignoring it made an energy overweight buy technology.
    func testACommittedTiltDecidesTheInstrumentInBothDirections() {
        for p in plans where !p.plan.trades.isEmpty {
            guard let sleeve = p.policy.sleeve("us_sector_tilt"),
                  let energy = sleeve.instruments.first(where: { $0.ticker == "XLE" })?.ticker else { continue }

            var over = p.eval.household
            over.tacticalTilts = [TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: 300,
                                                     sourceName: "Energy", ticker: energy,
                                                     thesis: "t", status: .committed)]
            XCTAssertEqual(Engine.buyTicker(for: sleeve, household: over, style: over.equityStyle), energy,
                "\(p.name): an energy overweight must buy energy")

            var under = p.eval.household
            under.tacticalTilts = [TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: -300,
                                                      sourceName: "Energy", ticker: energy,
                                                      thesis: "t", status: .committed)]
            XCTAssertNotEqual(Engine.buyTicker(for: sleeve, household: under, style: under.equityStyle), energy,
                "\(p.name): an energy underweight must not buy energy")

            var avoidPrimary = p.eval.household
            avoidPrimary.tacticalTilts = [TacticalTiltAction(sleeveId: "us_sector_tilt", deviationBps: -300,
                                                             sourceName: "Primary", ticker: sleeve.primaryTicker,
                                                             thesis: "t", status: .committed)]
            XCTAssertEqual(Engine.buyTicker(for: sleeve, household: avoidPrimary, style: avoidPrimary.equityStyle), "",
                "\(p.name): underweighting the sleeve's own default must propose no buy, not a substitute nobody argued for")
        }
    }

    // MARK: - Reproducibility

    /// The plan is a trade ticket. The same inputs must produce the same tickets, in the same
    /// order, every time.
    func testThePlanIsDeterministic() {
        for p in plans {
            let again = Engine.rebalancePlan(p.eval.household, policy: p.policy, tax: p.eval.tax, asOf: p.eval.asOf)
            let a = p.plan.trades.map { "\($0.side)|\($0.ticker)|\($0.accountId)|\(Int($0.amountUsd))" }
            let b = again.trades.map { "\($0.side)|\($0.ticker)|\($0.accountId)|\(Int($0.amountUsd))" }
            XCTAssertEqual(a, b, "\(p.name)")
            XCTAssertEqual(p.plan.warnings, again.warnings, "\(p.name)")
        }
    }
}
