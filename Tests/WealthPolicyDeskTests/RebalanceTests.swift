import XCTest
@testable import WealthPolicyDesk

/// The rebalance-to-policy trade generator — the only concrete trades a practitioner
/// would place, and (per the reproducibility doctrine) they must be deterministic. These
/// lock the accounting identities and the tax-budget bound on the sample's drifted book.
final class RebalanceTests: XCTestCase {

    /// The plan built exactly as RebalanceTab does: the derived strategic policy with each
    /// sleeve's target overwritten by the tactical allocation the drift is measured against.
    private func makePlan() -> RebalancePlan {
        let eval = Engine.evaluate(Seed.sampleHousehold)
        var p = eval.legacyPolicy
        p.sleeves = p.sleeves.map { s in
            var s = s
            if let row = eval.allocation.first(where: { $0.sleeveId == s.id }) { s.targetBps = row.targetBps }
            return s
        }
        return Engine.rebalancePlan(eval.household, policy: p, tax: eval.tax, asOf: eval.asOf)
    }

    func testSampleActuallyProducesTrades() {
        XCTAssertFalse(makePlan().isEmpty, "the sample's synthesized book drifts off target — expect trades")
    }

    func testTotalsMatchTheTradeList() {
        let p = makePlan()
        let buys = p.trades.filter { $0.side == .buy }.reduce(0) { $0 + $1.amountUsd }
        let sells = p.trades.filter { $0.side == .sell }.reduce(0) { $0 + $1.amountUsd }
        XCTAssertEqual(p.totalBuysUsd, buys, accuracy: 0.5)
        XCTAssertEqual(p.totalSellsUsd, sells, accuracy: 0.5)
    }

    func testBuysAreFundedBySellsAndNeverExceedThem() {
        let p = makePlan()
        XCTAssertLessThanOrEqual(p.totalBuysUsd, p.totalSellsUsd + 1, "buys are funded from sell proceeds")
    }

    func testRealizedGainSplitsSumToTheNet() {
        let p = makePlan()
        XCTAssertEqual(p.realizedGainUsd, p.realizedShortTermUsd + p.realizedLongTermUsd, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(p.estTaxUsd, 0)
        XCTAssertGreaterThanOrEqual(p.heldOutUsd, 0)
        XCTAssertGreaterThanOrEqual(p.washSaleDisallowedUsd, 0)
    }

    func testRealizedGainRespectsTheGainBudget() {
        let p = makePlan()
        if p.gainBudgetUsd > 0 {
            XCTAssertLessThanOrEqual(p.realizedGainUsd, p.gainBudgetUsd + 1,
                                     "the plan must not realize gains past the transition/rebalancing budget")
        }
    }

    /// Only taxable sells realize a gain; sheltered-account sells never do.
    func testShelteredSellsRealizeNoGain() {
        for t in makePlan().trades where t.side == .sell && t.treatment != .taxable {
            XCTAssertEqual(t.realizedGainUsd, 0, accuracy: 0.5, "\(t.ticker) in a sheltered account realized a gain")
        }
    }

    func testPlanIsDeterministic() {
        let a = makePlan(), b = makePlan()
        XCTAssertEqual(a.trades, b.trades, "same inputs must yield the identical trade list, in the same order")
        XCTAssertEqual(a.realizedGainUsd, b.realizedGainUsd, accuracy: 0.0001)
        XCTAssertEqual(a.totalSellsUsd, b.totalSellsUsd, accuracy: 0.0001)
    }
}
