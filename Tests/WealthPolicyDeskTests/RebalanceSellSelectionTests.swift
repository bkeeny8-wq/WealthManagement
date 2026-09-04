import XCTest
@testable import WealthPolicyDesk

/// WHICH lot the rebalancer reaches for, not just whether the totals add up.
///
/// The existing rebalance tests assert accounting identities, budget bounds and
/// determinism — all of which held while the sell selection silently flipped from
/// $160,000 of strategic municipal bonds to $171,270 of the household's held-to-maturity
/// ladder. 161 tests stayed green through that change. These pin the selection itself.
final class RebalanceSellSelectionTests: XCTestCase {

    /// Built exactly as RebalanceTab does: the derived strategic policy with each sleeve's
    /// target overwritten by the tactical allocation the drift is measured against.
    private func makePlan(_ h: Household) -> RebalancePlan {
        let eval = Engine.evaluate(h)
        var p = eval.legacyPolicy
        p.sleeves = p.sleeves.map { s in
            var s = s
            if let row = eval.allocation.first(where: { $0.sleeveId == s.id }) { s.targetBps = row.targetBps }
            return s
        }
        return Engine.rebalancePlan(eval.household, policy: p, tax: eval.tax, asOf: eval.asOf)
    }

    private func positions(_ h: Household) -> [Position] { Engine.evaluate(h).household.positions }

    // MARK: - The ladder is not a funding source

    /// The ladder funds dated near-term spending and is held to maturity. Because sheltered
    /// lots rank ahead of every taxable lot, it was the FIRST thing the sell ladder reached
    /// for — raising a fixed-income breach by liquidating 57% of the ladder, in the same
    /// evaluation that raised a hard `liquidity_floor` finding for being short of defensive
    /// assets. The plan sold the very thing it was being told it did not have enough of.
    func testNoSellEverTouchesALadderRung() {
        let h = Seed.sampleHousehold
        let pos = positions(h)
        let ladder = pos.filter { $0.layer == .ladder }
        XCTAssertFalse(ladder.isEmpty, "fixture check: the sample holds a ladder")

        for t in makePlan(h).trades where t.side == .sell {
            let sold = pos.first { $0.ticker == t.ticker && $0.accountId == t.accountId }
            XCTAssertNotEqual(sold?.layer, .ladder,
                              "\(t.ticker) in \(t.accountId) is a held-to-maturity ladder rung and must never be a funding source")
        }
    }

    /// A rung excluded from selling has to be REPORTED as held out, or the advisor reads a
    /// smaller sellable book than the one the engine actually used.
    func testLadderValueIsCountedAsHeldOut() {
        let h = Seed.sampleHousehold
        let ladderUsd = positions(h).filter { $0.layer == .ladder }.reduce(0) { $0 + $1.marketValueUsd }
        XCTAssertGreaterThanOrEqual(makePlan(h).heldOutUsd, ladderUsd,
                                    "the ladder is excluded from selling, so its value belongs in heldOutUsd")
    }

    // MARK: - The sample's actual selection, pinned

    /// The specific lots. Any change to sell ranking, sellability or the sleeve gap moves
    /// these, which is the point — the previous suite let the selection change silently.
    func testSampleSellsTheLowestGainTaxableLots() {
        let sells = makePlan(Seed.sampleHousehold).trades.filter { $0.side == .sell }
        XCTAssertEqual(Set(sells.map(\.ticker)), ["VEA", "MUB"],
                       "the sample funds its rebalance from taxable strategic lots")
        let byTicker = Dictionary(uniqueKeysWithValues: sells.map { ($0.ticker, $0.amountUsd) })
        XCTAssertEqual(byTicker["VEA"] ?? 0, 73_950, accuracy: 1)
        XCTAssertEqual(byTicker["MUB"] ?? 0, 160_000, accuracy: 1)
        XCTAssertEqual(makePlan(Seed.sampleHousehold).heldOutUsd, 1_020_000, accuracy: 1)
    }

    // MARK: - Charitable routing is not an instrument lock

    /// Intake stamps `.charitableAtDeath` on EVERY taxable position when the client names
    /// taxable as their bequest source — a live intake choice. Treating that as a per-lot
    /// hold froze the entire taxable book: held-out value jumped to $1.19M, every sell had
    /// to come from the IRA, and the plan could not be funded.
    func testATaxableCharitableBequestDoesNotFreezeTheBook() {
        var h = Seed.sampleHousehold
        h.positions = h.positions.map { p in
            var q = p
            if h.treatment(of: p) == .taxable { q.disposition = .charitableAtDeath }
            return q
        }
        let base = makePlan(Seed.sampleHousehold), routed = makePlan(h)
        XCTAssertEqual(routed.totalSellsUsd, base.totalSellsUsd, accuracy: 1,
                       "naming taxable as the bequest source must not change what can be traded")
        XCTAssertEqual(routed.heldOutUsd, base.heldOutUsd, accuracy: 1)
        XCTAssertEqual(Set(routed.trades.map(\.ticker)), Set(base.trades.map(\.ticker)))
    }

    /// The two predicates answer different questions and must not be collapsed back into
    /// one: the rebalancer may trade a charitable-routed lot, while the desk still leads
    /// with the earmark instead of telling the client to unwind it.
    func testSellabilityAndEarmarkAreSeparateQuestions() {
        let charity = Position(id: "c", accountId: "a", ticker: "VTI", sleeveId: "us_large_core",
                               marketValueUsd: 100_000, costBasisUsd: 20_000, layer: .strategic,
                               disposition: .charitableAtDeath, holdToStepUp: false)
        XCTAssertTrue(Engine.isSellable(charity))
        XCTAssertTrue(Engine.hasTerminalEarmark(charity))

        let rung = Position(id: "r", accountId: "a", ticker: "BND", sleeveId: "fixed_income_liquid",
                            marketValueUsd: 100_000, costBasisUsd: 100_000, layer: .ladder,
                            disposition: .consume, holdToStepUp: false)
        XCTAssertFalse(Engine.isSellable(rung), "a ladder rung is held to maturity")
        XCTAssertFalse(Engine.hasTerminalEarmark(rung), "but the client declared no endpoint for it")

        let gift = Position(id: "g", accountId: "a", ticker: "VTI", sleeveId: "us_large_core",
                            marketValueUsd: 100_000, costBasisUsd: 10_000, layer: .strategic,
                            disposition: .giftDuringLife, holdToStepUp: false)
        XCTAssertFalse(Engine.isSellable(gift), "a gift earmark is a genuine lock")
        XCTAssertTrue(Engine.hasTerminalEarmark(gift))
    }
}
