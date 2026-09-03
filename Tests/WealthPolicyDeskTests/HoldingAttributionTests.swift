import XCTest
@testable import WealthPolicyDesk

/// Guards the third batch of audit fixes: making the desk tell ONE truth about holdings.
/// A client's real, entered positions were counted in the portfolio total but not against
/// any sleeve, and a committed trade could be silently orphaned by an equity-style change.
final class HoldingAttributionTests: XCTestCase {

    /// An intake with a large real VOO position held away in the taxable account.
    private func intakeHoldingVOO(_ usd: Usd = 700_000) -> IntakeModel {
        var m = IntakeModel()
        m.taxableUsd = 1_000_000; m.traditionalUsd = 0; m.rothUsd = 0
        var p = IntakeHeldPosition()
        p.ticker = "VOO"; p.marketValueUsd = usd; p.costBasisUsd = usd * 0.7; p.treatment = .taxable
        m.heldAwayPositions = [p]
        return m
    }

    // MARK: - Real holdings count toward their sleeve

    /// The bug: `portfolioValueUsd` (the denominator) counted the entered VOO, but the
    /// numerator only summed positions carrying that sleeveId — and an itemized holding
    /// carries none. Every sleeve therefore read underweight, and the desk advised adding
    /// to a sleeve the client was already concentrated in.
    func testEnteredHoldingCountsTowardItsSleeve() {
        let h = intakeHoldingVOO().buildHousehold()
        let itemized = h.positions.filter { $0.sleeveId == nil && $0.ticker == "VOO" }
        XCTAssertEqual(itemized.count, 1, "fixture check: VOO is itemized, so it carries no sleeveId")

        let e = Engine.evaluate(h)
        guard let core = e.allocation.first(where: { $0.sleeveId == "us_large_core" }) else {
            return XCTFail("expected a US Large Core row")
        }
        // $700k of a ~$1M book is ~70% in large core, far above its ~16.5% target.
        XCTAssertGreaterThan(core.currentBps, 5000, "the entered VOO must be visible to the allocation gap")
        XCTAssertGreaterThan(core.driftBps, 0, "a 70% holding against a ~16% target is overweight, not underweight")
    }

    /// Attribution must NOT mutate the stored sleeveId — that nil is what marks a holding as
    /// advisor-entered for the Portfolio tab and the concentration rules.
    func testAttributionDoesNotRewriteTheStoredSleeveId() {
        let h = intakeHoldingVOO().buildHousehold()
        _ = Engine.evaluate(h)
        let voo = h.positions.first { $0.ticker == "VOO" && $0.marketValueUsd == 700_000 }
        XCTAssertNotNil(voo)
        XCTAssertNil(voo?.sleeveId, "the holding stays itemized; only the attribution is derived")
        XCTAssertEqual(Engine.effectiveSleeveId(voo!), "us_large_core")
    }

    /// A holding with no classifiable home stays unattributed rather than being forced
    /// into a sleeve — a bare single name has no policy home, which is why it is reviewed.
    func testUnclassifiableHoldingIsNotForcedIntoASleeve() {
        var m = IntakeModel()
        m.taxableUsd = 500_000
        var p = IntakeHeldPosition()
        p.ticker = "ZZZZ"; p.marketValueUsd = 100_000; p.costBasisUsd = 50_000; p.treatment = .taxable
        m.heldAwayPositions = [p]
        let h = m.buildHousehold()
        let zz = h.positions.first { $0.ticker == "ZZZZ" }
        XCTAssertNotNil(zz)
        XCTAssertNil(Engine.effectiveSleeveId(zz!), "no ticker match and no sector means no sleeve")
    }

    /// The rebalancer must see the same book the allocation does, or it trades only the
    /// synthesized proxies and ignores everything the client actually owns.
    func testRebalanceSeesEnteredHoldings() {
        let h = intakeHoldingVOO().buildHousehold()
        let e = Engine.evaluate(h)
        let plan = Engine.rebalancePlan(h, policy: e.legacyPolicy, tax: Seed.tax2026, asOf: Engine.planningAsOf)
        guard let core = plan.sleeveGaps.first(where: { $0.sleeveId == "us_large_core" }) else {
            return XCTFail("expected a US Large Core gap")
        }
        XCTAssertGreaterThan(core.currentBps, 5000, "the rebalancer must weigh the entered VOO")
        XCTAssertLessThan(core.gapUsd, 0, "hugely overweight means a sell gap, not a buy gap")
    }

    // MARK: - A committed trade survives an equity-style change

    /// The bug: `household()` replayed committed moves BEFORE the style re-flavored the
    /// synthesized proxies, so a trade staged against the styled ticker (VUG) found nothing
    /// to sell and silently vanished from the plan of record.
    func testCommittedMoveAgainstAStyledTickerStillResolves() {
        var m = IntakeModel()
        m.taxableUsd = 0; m.traditionalUsd = 1_000_000; m.rothUsd = 0   // sheltered, so the sale is untaxed
        var overrides = HouseholdOverrides()
        overrides.usEquityStyle = USEquityStyleTilt(large: .growth)      // VOO -> VUG

        // Sanity: with the style applied, the synthesized large-core proxy is VUG.
        let styled = m.buildHousehold().withEquityStyle(overrides.usEquityStyle!)
        XCTAssertTrue(styled.positions.contains { $0.ticker == "VUG" }, "fixture check: large core is re-flavored to VUG")
        guard let vug = styled.positions.first(where: { $0.ticker == "VUG" }) else { return XCTFail() }

        let move = PlannedAction(sellAccountId: vug.accountId, sellTicker: "VUG", sellUsd: 10_000,
                                 buyTicker: "BND", buySleeveId: "fixed_income_liquid",
                                 thesis: "trim growth", status: .committed)
        let rec = ClientRecord(intake: m, practice: PracticeMetadata(), actions: [move], driverOverrides: overrides)

        let statuses = rec.committedStatuses()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertTrue(statuses[0].resolved, "the move must find the styled holding it was staged against")
        XCTAssertGreaterThan(statuses[0].appliedUsd, 0, "and must actually apply, not silently vanish")
    }

    /// With no style set, the plan of record is unchanged — the reordering must be a no-op
    /// for every client who never touches the style control.
    func testNeutralStyleLeavesThePlanOfRecordUnchanged() {
        let m = intakeHoldingVOO()
        let rec = ClientRecord(intake: m, practice: PracticeMetadata())
        let viaRecord = rec.household()
        let direct = m.buildHousehold()
        XCTAssertEqual(viaRecord.portfolioValueUsd, direct.portfolioValueUsd, accuracy: 0.5)
        XCTAssertEqual(Set(viaRecord.positions.map { $0.ticker }), Set(direct.positions.map { $0.ticker }))
    }
}
