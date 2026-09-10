import XCTest
@testable import WealthPolicyDesk

/// Money must be conserved between what the client enters and what the plan holds.
///
/// Itemized held-away holdings are entered as real positions, and the REST of the stated
/// account balance is synthesized into a policy-shaped proxy — so the itemized value has to
/// be subtracted from the balance exactly once. That total was keyed by TREATMENT, which
/// was correct only while a treatment had exactly one account. Once each adult owned their
/// own IRA, every one of those accounts subtracted the same household-wide total and the
/// difference simply vanished from the portfolio.
final class HeldAwayConservationTests: XCTestCase {

    private func held(_ ticker: String, _ value: Usd, _ treatment: AccountTaxTreatment, owner: Int = 0) -> IntakeHeldPosition {
        var h = IntakeHeldPosition()
        h.ticker = ticker; h.marketValueUsd = value; h.costBasisUsd = value * 0.7
        h.treatment = treatment; h.ownerIndex = owner
        return h
    }

    private func couple(traditional: (Usd, Usd), heldAway: [IntakeHeldPosition]) -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1968; a.retirementAge = 65
        a.salaryUsd = 200_000; a.traditionalUsd = traditional.0
        var b = IntakeAdult(); b.name = "Ben"; b.birthYear = 1970; b.retirementAge = 65
        b.salaryUsd = 150_000; b.traditionalUsd = traditional.1
        m.adults = [a, b]
        m.taxableUsd = 400_000
        m.heldAwayPositions = heldAway
        return m
    }

    /// The reported defect, end to end: nothing may go missing.
    func testItemizedHoldingsAreSubtractedExactlyOnce() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 100_000, .taxDeferred, owner: 0)])
        let h = m.buildHousehold()
        XCTAssertEqual(h.value(in: .taxDeferred), 1_000_000, accuracy: 1,
                       "the couple entered $1,000,000 of IRAs; the plan must hold $1,000,000")
        XCTAssertEqual(h.portfolioValueUsd, 1_400_000, accuracy: 1)
    }

    /// And with holdings itemized in BOTH spouses' accounts.
    func testConservationHoldsWithItemizedHoldingsInEachSpousesAccount() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 100_000, .taxDeferred, owner: 0),
                                  held("MSFT", 250_000, .taxDeferred, owner: 1)])
        XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1)
    }

    /// Sweep it: whatever the split and wherever the holdings sit, the total is the total.
    func testConservationHoldsAcrossEverySplit() {
        for split in [(1_000_000.0, 0.0), (600_000.0, 400_000.0), (500_000.0, 500_000.0), (0.0, 1_000_000.0)] {
            for owner in [0, 1] {
                let m = couple(traditional: split, heldAway: [held("AAPL", 150_000, .taxDeferred, owner: owner)])
                XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1,
                               "split \(split) with the holding in account \(owner) lost money")
            }
        }
    }

    /// A holding names whose account it is in, so it distributes on THAT owner's schedule.
    /// Every itemized retirement holding used to be filed under the primary.
    func testAnItemizedHoldingSitsInItsOwnersAccount() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("MSFT", 250_000, .taxDeferred, owner: 1)])
        let h = m.buildHousehold()
        let msft = h.positions.first { $0.ticker == "MSFT" }
        XCTAssertEqual(msft?.accountId, "acct_trad_1", "Ben's rollover holding belongs in Ben's account")
        XCTAssertEqual(h.account("acct_trad_1")?.ownership.ownerPersonId, "p_1")
    }

    /// An owner index pointing at nobody must not invent an account.
    func testAnOutOfRangeOwnerFallsBackToThePrimary() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 100_000, .taxDeferred, owner: 7)])
        let h = m.buildHousehold()
        XCTAssertEqual(h.positions.first { $0.ticker == "AAPL" }?.accountId, "acct_trad")
        XCTAssertEqual(h.value(in: .taxDeferred), 1_000_000, accuracy: 1, "and money is still conserved")
    }

    /// Taxable holdings are unaffected — there is one titled brokerage, not one per person.
    func testTaxableHoldingsStillLandInTheOneBrokerage() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("VTI", 120_000, .taxable, owner: 1)])
        let h = m.buildHousehold()
        XCTAssertEqual(h.positions.first { $0.ticker == "VTI" }?.accountId, "acct_taxable")
        XCTAssertEqual(h.value(in: .taxable), 400_000, accuracy: 1)
    }

    /// The owner must survive a save and reload, or the holding silently moves back to the
    /// primary's account — and onto the wrong distribution schedule — on the next load.
    func testTheOwnerRoundTrips() throws {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("MSFT", 250_000, .taxDeferred, owner: 1)])
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONEncoder().encode(m))
        XCTAssertEqual(back.heldAwayPositions.first?.ownerIndex, 1)
    }
}
