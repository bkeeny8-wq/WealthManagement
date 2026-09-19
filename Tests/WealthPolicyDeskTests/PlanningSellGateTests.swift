import XCTest
@testable import WealthPolicyDesk

/// Planning used to offer every position with market value, including lots
/// Rebalance (and Portfolio KEEP) treat as locked. A mid-flight style or holdings
/// edit could also orphan a staged sell; Commit then wrote a no-op onto the plan.
final class PlanningSellGateTests: XCTestCase {

    /// The Harrison sample's VOO / AAPL are hold-to-step-up and BND is a ladder
    /// rung. Planning must not offer them; Rebalance already refuses.
    func testHarrisonPlanningSellListOmitsStepUpAndLadder() {
        let h = Seed.sampleHousehold
        let tickers = Set(h.sellableForPlanning.map(\.ticker))
        XCTAssertFalse(tickers.contains("VOO"), "hold-to-step-up VOO is not a Planning sell")
        XCTAssertFalse(tickers.contains("AAPL"), "hold-to-step-up AAPL is not a Planning sell")
        XCTAssertFalse(tickers.contains("BND"), "ladder BND is not a Planning sell")
        XCTAssertTrue(tickers.contains("VEA"), "strategic taxable VEA remains sellable")
        XCTAssertTrue(tickers.contains("XLK"), "charitable routing is not a lock")
    }

    func testSellableForPlanningMatchesIsSellable() {
        let h = Seed.sampleHousehold
        let ids = Set(h.sellableForPlanning.map(\.id))
        for p in h.positions where p.marketValueUsd > 1 {
            XCTAssertEqual(ids.contains(p.id), Engine.isSellable(p),
                           "\(p.ticker) sellableForPlanning must match Engine.isSellable")
        }
        XCTAssertFalse(h.sellableForPlanning.contains { $0.marketValueUsd <= 1 })
    }

    /// Removing the sold holding (holdings Apply / intake rename) flags the staged
    /// move unresolved. applying() is a no-op, so Commit must refuse rather than
    /// write a committed row that never sold.
    func testRemovingTheSoldHoldingMarksTheStagedMoveUnresolved() {
        var h = Seed.sampleHousehold
        guard let vea = h.positions.first(where: { $0.ticker == "VEA" }) else {
            return XCTFail("fixture: sample holds VEA")
        }
        XCTAssertTrue(Engine.isSellable(vea))
        let move = PlannedAction(sellAccountId: vea.accountId, sellTicker: "VEA", sellUsd: 10_000,
                                 buyTicker: "XLP", buySleeveId: "us_sector_tilt", status: .staged)
        XCTAssertFalse(h.hasUnresolvedMoves([move]))
        XCTAssertTrue(h.replayStatuses([move])[0].resolved)

        h.positions.removeAll { $0.id == vea.id }
        XCTAssertTrue(h.hasUnresolvedMoves([move]), "a missing ticker is unresolved")
        XCTAssertFalse(h.replayStatuses([move])[0].resolved)
        let after = h.applying(move)
        XCTAssertFalse(after.positions.contains { $0.ticker == "XLP" },
                       "unresolved apply is a no-op — Commit must not record it")
    }

    /// Style rewrites synthesized US-size tickers immediately (not via staging).
    /// Sample VB is sellable mid/small blend; flipping small → growth maps VB → VBK
    /// and would orphan a staged VB sell unless Commit is refused.
    func testStyleFlipOrphansAStagedSellAgainstTheOldTicker() {
        let blend = Seed.sampleHousehold
        guard let vb = blend.positions.first(where: { $0.ticker == "VB" && $0.sleeveId != nil }) else {
            return XCTFail("fixture: sample holds synthesized VB")
        }
        XCTAssertTrue(Engine.isSellable(vb), "VB is not a step-up lock")
        let move = PlannedAction(sellAccountId: vb.accountId, sellTicker: "VB", sellUsd: 10_000,
                                 buyTicker: "XLP", buySleeveId: "us_sector_tilt", status: .staged)
        XCTAssertFalse(blend.hasUnresolvedMoves([move]))

        let growth = blend.withEquityStyle(USEquityStyleTilt(small: .growth))
        XCTAssertTrue(growth.positions.contains { $0.ticker == "VBK" })
        XCTAssertTrue(growth.hasUnresolvedMoves([move]),
                      "style rewrite to VBK orphans a VB sell; Commit must refuse")
    }
}
