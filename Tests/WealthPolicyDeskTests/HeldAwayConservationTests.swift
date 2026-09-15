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

    /// The reported defect's mirror: an itemized holding LARGER than its own owner's stated
    /// balance must not create money. `remainder` clamps at zero, so the owner's account
    /// absorbed only part of the holding while every other account of that treatment still
    /// synthesized its balance in full.
    func testAnItemizedHoldingLargerThanItsOwnersBalanceDoesNotCreateMoney() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 700_000, .taxDeferred, owner: 0)])
        XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1,
                       "the couple entered $1,000,000 of IRAs; a $700k holding in one of them cannot make it $1.1M")
    }

    /// And on the ordinary input that made it reachable — a lopsided split where the holding
    /// simply exceeds the smaller account. This needed no unusual data at all.
    func testALopsidedSplitConservesWhenTheHoldingExceedsTheSmallerAccount() {
        let m = couple(traditional: (100_000, 900_000),
                       heldAway: [held("AAPL", 250_000, .taxDeferred, owner: 0)])
        XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1)
    }

    /// Several holdings that together exceed one account must spill rather than duplicate.
    func testMultipleHoldingsSpillAcrossTheTreatmentsAccounts() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 500_000, .taxDeferred, owner: 0),
                                  held("MSFT", 300_000, .taxDeferred, owner: 0)])
        XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1)
    }

    /// Sweep the boundary: any itemized total up to the household's stated total conserves.
    func testConservationHoldsAtEveryItemizedSize() {
        for itemized in stride(from: 50_000.0, through: 1_000_000.0, by: 50_000.0) {
            let m = couple(traditional: (600_000, 400_000),
                           heldAway: [held("AAPL", itemized, .taxDeferred, owner: 0)])
            XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1,
                           "a $\(Int(itemized)) itemized holding broke conservation")
        }
    }

    /// Itemising MORE than the stated balances is contradictory input. The holdings win —
    /// they are specific facts the client typed, the balance is the estimate — but nothing
    /// may be duplicated on top of them.
    func testOverItemisingKeepsTheHoldingsAndSynthesizesNothingExtra() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 1_400_000, .taxDeferred, owner: 0)])
        XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_400_000, accuracy: 1,
                       "the entered holding stands alone; no proxy is synthesized alongside it")
    }

    // MARK: - Per-ACCOUNT conservation, not just the household total

    private func byAccount(_ h: Household) -> [String: Usd] {
        Dictionary(grouping: h.positions, by: \.accountId)
            .mapValues { $0.reduce(0) { $0 + $1.marketValueUsd } }
    }

    /// The household total being right does not mean the money is in the right ACCOUNTS.
    /// Pooling the raw itemized total conserved the household figure while draining one
    /// spouse's IRA to absorb the other's holding — and the test asserting only the total
    /// certified it.
    func testItemizedValueNeverMovesBetweenOwnersAccounts() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 100_000, .taxDeferred, owner: 0),
                                  held("MSFT", 250_000, .taxDeferred, owner: 1)])
        let acct = byAccount(m.buildHousehold())
        XCTAssertEqual(acct["acct_trad"] ?? 0, 600_000, accuracy: 1, "Ada stated $600,000 and must hold $600,000")
        XCTAssertEqual(acct["acct_trad_1"] ?? 0, 400_000, accuracy: 1, "Ben stated $400,000 and must hold $400,000")
    }

    /// The consequence that makes it matter: an older spouse past her required beginning date
    /// must keep her own distributions, whoever itemized what.
    func testAnItemizedHoldingCannotDeleteTheOtherSpousesRmds() {
        func firstRmd(ownerOfHolding: Int) -> (age: Int, usd: Usd) {
            var m = IntakeModel()
            var ada = IntakeAdult(); ada.name = "Ada"; ada.birthYear = 1950; ada.retirementAge = 62
            ada.salaryUsd = 0; ada.traditionalUsd = 600_000
            var ben = IntakeAdult(); ben.name = "Ben"; ben.birthYear = 1980; ben.retirementAge = 65
            ben.salaryUsd = 150_000; ben.traditionalUsd = 400_000
            m.adults = [ada, ben]
            m.taxableUsd = 300_000
            m.retirementSpendingUsd = 120_000
            m.heldAwayPositions = [held("MSFT", 300_000, .taxDeferred, owner: ownerOfHolding)]
            let years = Engine.evaluate(m.buildHousehold()).decumulation.baseline.years
            guard let y = years.first(where: { $0.rmdUsd > 0 }) else { return (0, 0) }
            return (y.age, y.rmdUsd)
        }
        let filedToBen = firstRmd(ownerOfHolding: 1), filedToAda = firstRmd(ownerOfHolding: 0)
        XCTAssertGreaterThan(filedToBen.usd, 0, "Ada is 76 and past her required beginning date")
        XCTAssertEqual(filedToBen.age, filedToAda.age,
                       "whose rollover was itemized cannot change when distributions begin")
        XCTAssertEqual(filedToBen.usd, filedToAda.usd, accuracy: 1,
                       "nor how large they are — Ada's IRA was drained to absorb Ben's holding")
    }

    /// Sweep three adults and every owner, asserting per-account, not just the total.
    func testPerAccountConservationHoldsAcrossThreeAdults() {
        for owner in [0, 1, 2] {
            var m = IntakeModel()
            let balances: [Usd] = [300_000, 300_000, 400_000]
            m.adults = balances.enumerated().map { i, b in
                var a = IntakeAdult(); a.name = "A\(i)"; a.birthYear = 1970; a.retirementAge = 65
                a.salaryUsd = 100_000; a.traditionalUsd = b; return a
            }
            m.taxableUsd = 200_000
            m.heldAwayPositions = [held("AAPL", 250_000, .taxDeferred, owner: owner)]
            let acct = byAccount(m.buildHousehold())
            for (i, b) in balances.enumerated() {
                let id = i == 0 ? "acct_trad" : "acct_trad_\(i)"
                XCTAssertEqual(acct[id] ?? 0, b, accuracy: 1,
                               "holding filed to owner \(owner) moved money out of account \(i)")
            }
        }
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
