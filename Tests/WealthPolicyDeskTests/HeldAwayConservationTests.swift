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

    /// Sweep it: whenever the holding fits inside its OWN owner's stated balance, the
    /// household total is exactly what was entered — whatever the split.
    func testConservationHoldsAcrossEverySplitTheHoldingFitsInside() {
        for split in [(1_000_000.0, 0.0), (600_000.0, 400_000.0), (500_000.0, 500_000.0), (0.0, 1_000_000.0)] {
            for owner in [0, 1] {
                let stated = owner == 0 ? split.0 : split.1
                guard stated >= 150_000 else { continue }   // otherwise the client contradicts themselves
                let m = couple(traditional: split, heldAway: [held("AAPL", 150_000, .taxDeferred, owner: owner)])
                XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1,
                               "split \(split) with the holding in account \(owner) lost money")
                XCTAssertTrue(m.overItemisedAccounts.isEmpty)
            }
        }
    }

    /// A holding filed to an account whose owner stated NO balance is the same contradiction
    /// as any other over-itemisation, and must be treated the same way: that account holds
    /// the holding, the OTHER account is untouched, and the form says so.
    ///
    /// The previous rule redirected such a holding to "the first adult who does have a
    /// balance" — a cross-account relocation term that survived deleting the spill because it
    /// lived in the account lookup rather than in the netting. An advisor entering a spouse's
    /// $400,000 rollover and leaving the balance blank had it filed into the other adult's
    /// IRA, displacing $400,000 of their proxy: the household held $600,000 against the
    /// $1,000,000 entered and the spouse's distributions vanished.
    func testAHoldingFiledToABlankBalanceAccountStaysThere() {
        let m = couple(traditional: (1_000_000, 0),
                       heldAway: [held("MSFT", 400_000, .taxDeferred, owner: 1)])
        let acct = byAccount(m.buildHousehold())
        XCTAssertEqual(acct["acct_trad"] ?? 0, 1_000_000, accuracy: 1,
                       "the other adult's stated balance was never in question")
        XCTAssertEqual(acct["acct_trad_1"] ?? 0, 400_000, accuracy: 1,
                       "the rollover belongs in the account the advisor filed it in")
        XCTAssertEqual(m.overItemisedAccounts.count, 1, "and the blank balance is flagged")
        XCTAssertEqual(m.overItemisedAccounts.first?.owner, "Ben")
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

    // MARK: - When the client's own inputs contradict each other

    /// "Ada's IRA is $600,000" and "here is a $700,000 holding in Ada's IRA" cannot both be
    /// true. The SPECIFIC evidence wins — a holding typed with a ticker, a value and a basis
    /// beats a rounded balance — so that account holds the holding and synthesizes nothing
    /// on top. Crucially, no OTHER account is touched.
    ///
    /// Two earlier rules tried to force the household total to come out right instead. One
    /// netted per account and created money; the other pooled and spilled, which conserved
    /// the total by DRAINING the other spouse's IRA — halving a 76-year-old's required
    /// distributions. Both existed only to hide a contradiction the client should be told
    /// about.
    func testAnOverItemisedAccountHoldsItsHoldingsAndLeavesOthersAlone() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 700_000, .taxDeferred, owner: 0)])
        let acct = byAccount(m.buildHousehold())
        XCTAssertEqual(acct["acct_trad"] ?? 0, 700_000, accuracy: 1,
                       "the itemized holding is the better evidence for Ada's account")
        XCTAssertEqual(acct["acct_trad_1"] ?? 0, 400_000, accuracy: 1,
                       "and Ben's stated balance is not in question, so it must not move")
    }

    /// The contradiction is reported, not silently resolved.
    func testAnOverItemisedAccountIsSurfacedToTheForm() {
        let m = couple(traditional: (600_000, 400_000),
                       heldAway: [held("AAPL", 700_000, .taxDeferred, owner: 0)])
        let flagged = m.overItemisedAccounts
        XCTAssertEqual(flagged.count, 1)
        XCTAssertEqual(flagged.first?.owner, "Ada")
        XCTAssertEqual(flagged.first?.statedUsd ?? 0, 600_000, accuracy: 1)
        XCTAssertEqual(flagged.first?.itemizedUsd ?? 0, 700_000, accuracy: 1)

        let consistent = couple(traditional: (600_000, 400_000),
                                heldAway: [held("AAPL", 100_000, .taxDeferred, owner: 0)])
        XCTAssertTrue(consistent.overItemisedAccounts.isEmpty, "a holding that fits is not a contradiction")
    }

    /// Whatever the itemisation, a NEIGHBOURING account always holds exactly what was stated
    /// for it. This is the invariant that makes relocation impossible by construction.
    func testANeighbouringAccountAlwaysHoldsItsStatedBalance() {
        for itemized in stride(from: 50_000.0, through: 1_400_000.0, by: 50_000.0) {
            let m = couple(traditional: (600_000, 400_000),
                           heldAway: [held("AAPL", itemized, .taxDeferred, owner: 0)])
            XCTAssertEqual(byAccount(m.buildHousehold())["acct_trad_1"] ?? 0, 400_000, accuracy: 1,
                           "a $\(Int(itemized)) holding in ADA's account moved money out of BEN's")
        }
    }

    /// And when the itemisation fits, the household total is exactly what was entered.
    func testTheHouseholdTotalIsExactWheneverTheItemisationFits() {
        for itemized in stride(from: 50_000.0, through: 600_000.0, by: 50_000.0) {
            let m = couple(traditional: (600_000, 400_000),
                           heldAway: [held("AAPL", itemized, .taxDeferred, owner: 0)])
            XCTAssertEqual(m.buildHousehold().value(in: .taxDeferred), 1_000_000, accuracy: 1,
                           "a $\(Int(itemized)) holding inside Ada's balance broke the total")
            XCTAssertTrue(m.overItemisedAccounts.isEmpty)
        }
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

    /// The form's headline figure must agree with the household it builds. It summed the
    /// stated balances alone, so an over-itemised intake printed "Investable assets
    /// $1,400,000" directly above an after-tax net worth computed on $1,500,000 — and the IPS
    /// prose quoted the larger figure to the client while the CRM row shipped both.
    func testTheHeadlineInvestableFigureMatchesTheBuiltHousehold() {
        for holding in [100_000.0, 700_000.0, 1_400_000.0] {
            let m = couple(traditional: (600_000, 400_000),
                           heldAway: [held("AAPL", holding, .taxDeferred, owner: 0)])
            XCTAssertEqual(m.totalInvestableUsd, m.buildHousehold().portfolioValueUsd, accuracy: 1,
                           "a $\(Int(holding)) holding made the form disagree with the plan")
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
