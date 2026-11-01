import XCTest
@testable import WealthPolicyDesk

/// Equity compensation that vests on a SCHEDULE.
///
/// The app used to carry one number per person — `employerStockUsd`, an undated lump. That
/// cannot say when the money arrives, how much is still contingent on staying, or what a
/// departure would forfeit. It also carried the GROSS award, which a client never receives: a
/// supplemental withholding rate near 42% turns a $29,527 grant letter into about $17,191.
///
/// The fixture is a real annual-grant ladder — four grants outstanding at once, each part-vested,
/// tranches interleaving across four years — because that is the shape a single number hides.
final class VestingScheduleTests: XCTestCase {

    private let asOf: IsoDate = "2026-11-01"
    private var planYear: Int { Engine.year(asOf) }

    /// Four annual grants, 471 units unvested, vesting across six dates from 2027 to 2030.
    private func ladder(withholdingBps: Bps = 4178) -> IntakeModel {
        func g(_ label: String, units: Double, dates: [IsoDate], perDate: [Double]) -> IntakeRsuGrant {
            var r = IntakeRsuGrant()
            r.label = label; r.employer = "BAC"; r.ticker = "BAC"
            r.unitsUnvested = units; r.sharePriceUsd = 62.69
            r.vestDates = dates; r.unitsByDate = perDate
            return r
        }
        var a = IntakeAdult()
        a.name = "A"; a.birthYear = planYear - 36; a.retirementAge = 65
        a.salaryUsd = 225_000; a.bonusUsd = 200_000
        a.grantWithholdingBps = withholdingBps
        a.rsuGrants = [
            g("23BSS", units: 45,  dates: ["2027-03-15"], perDate: [45]),
            g("24BSS", units: 120, dates: ["2027-03-15", "2028-03-15"], perDate: [60, 60]),
            g("25BSS", units: 143, dates: ["2027-03-01", "2028-03-01", "2029-03-01"], perDate: [48, 47, 48]),
            g("26BSS", units: 163, dates: ["2027-03-01", "2028-03-01", "2029-03-01", "2030-03-01"], perDate: [40, 41, 41, 41]),
        ]
        var m = IntakeModel()
        m.adults = [a]
        m.state = "NJ"; m.planToAge = 92; m.taxableUsd = 17_000
        m.retirementSpendingUsd = 140_000
        return m
    }

    // MARK: - The schedule exists at all

    /// Every unvested unit lands on a date, and the dates span the real vesting horizon.
    func testEveryUnvestedUnitIsPlacedInAYear() {
        let h = ladder().buildHousehold(asOf: asOf)
        let tranches = h.deferredComp.flatMap(\.vesting)
        XCTAssertEqual(tranches.reduce(0) { $0 + $1.units }, 471, accuracy: 0.01,
                       "the grants hold 471 unvested units; the schedule accounts for a different number")
        XCTAssertEqual(Engine.undatedUnvestedNetUsd(h), 0, accuracy: 1,
                       "a grant was carried with no vest date, so its value cannot be placed in any year")
        XCTAssertEqual(Engine.lastVestPlanYear(h, asOf: asOf), 4,
                       "the last tranche vests in 2030, four plan years out")
    }

    /// Grants INTERLEAVE. Summing per-year across every grant is the whole point: 2027 draws from
    /// all four at once, which no single grant's own schedule would show.
    func testInterleavedGrantsAreSummedPerYear() {
        let h = ladder().buildHousehold(asOf: asOf)
        let keep = 1 - 0.4178
        // 2027: 23BSS 45 + 24BSS 60 + 25BSS 48 + 26BSS 40 = 193 units
        XCTAssertEqual(Engine.vestingNetInYear(h, year: 1, asOf: asOf), 193 * 62.69 * keep, accuracy: 1,
                       "plan year 1 should draw from all four grants at once")
        // 2028: 24BSS 60 + 25BSS 47 + 26BSS 41 = 148
        XCTAssertEqual(Engine.vestingNetInYear(h, year: 2, asOf: asOf), 148 * 62.69 * keep, accuracy: 1)
        // 2029: 25BSS 48 + 26BSS 41 = 89
        XCTAssertEqual(Engine.vestingNetInYear(h, year: 3, asOf: asOf), 89 * 62.69 * keep, accuracy: 1)
        // 2030: 26BSS 41
        XCTAssertEqual(Engine.vestingNetInYear(h, year: 4, asOf: asOf), 41 * 62.69 * keep, accuracy: 1)
        XCTAssertEqual(Engine.vestingNetInYear(h, year: 5, asOf: asOf), 0, accuracy: 1,
                       "nothing vests after the last tranche")

        // And the years sum to the whole grant, net — nothing created, nothing lost.
        let total = (1...6).reduce(0.0) { $0 + Engine.vestingNetInYear(h, year: $1, asOf: asOf) }
        XCTAssertEqual(total, Engine.unvestedNetUsd(h), accuracy: 1,
                       "the per-year schedule does not add up to the unvested total")
    }

    // MARK: - Gross is not what the client gets

    /// The balance sheet carries the NET figure. Both directions asserted: netting must happen,
    /// and it must not happen twice or to grants that never stated a rate.
    func testUnvestedIsCountedNetOfWithholdingAndOnlyOnce() {
        let gross = 471 * 62.69
        let withheld = ladder(withholdingBps: 4178).buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.unvestedNetUsd(withheld), gross * (1 - 0.4178), accuracy: 1,
                       "unvested equity is not being netted of the stated withholding")
        XCTAssertLessThan(Engine.unvestedNetUsd(withheld), gross,
                          "net unvested is not below gross — withholding was ignored")

        // Mirror: a grant with NO stated rate must come through at gross, not silently haircut.
        let bare = ladder(withholdingBps: 0).buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.unvestedNetUsd(bare), gross, accuracy: 1,
                       "a grant that never stated a withholding rate was haircut anyway")
    }

    /// And it reaches the balance sheet, not just the helper.
    func testTheBalanceSheetUsesTheNetFigure() {
        let withheld = Engine.evaluate(ladder(withholdingBps: 4178).buildHousehold(asOf: asOf), asOf: asOf)
        let bare = Engine.evaluate(ladder(withholdingBps: 0).buildHousehold(asOf: asOf), asOf: asOf)
        XCTAssertLessThan(withheld.balanceSheet.grossNetWorthUsd, bare.balanceSheet.grossNetWorthUsd,
                          "withholding on a grant changed nothing on the balance sheet")
    }

    // MARK: - The undated lump still works

    /// A client who can only give a total still gets a line. The lump and the ladder are the same
    /// money, so listing grants must REPLACE it rather than add to it.
    func testAnUndatedLumpStillCountsButIsNeverDoubleCounted() {
        var lumpOnly = ladder()
        lumpOnly.adults[0].rsuGrants = []
        lumpOnly.adults[0].employerStockUsd = 29_527
        let lh = lumpOnly.buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.unvestedNetUsd(lh), 29_527 * (1 - 0.4178), accuracy: 1,
                       "an undated lump stopped being counted")
        XCTAssertGreaterThan(Engine.undatedUnvestedNetUsd(lh), 0,
                             "an undated lump should be reported as undated so it can be chased")

        var both = ladder()
        both.adults[0].employerStockUsd = 29_527          // the same money, stated twice
        let bh = both.buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.unvestedNetUsd(bh), 471 * 62.69 * (1 - 0.4178), accuracy: 1,
                       "the lump and the dated grants were both counted — the same units twice")
    }

    // MARK: - Future grants

    /// Compensation delivered as stock does not stop at today's grants. A client whose bonus
    /// arrives half in stock has a rolling ladder for as long as they work, and modelling only
    /// what is already awarded makes them look like someone paid entirely in cash.
    func testExpectedFutureGrantsKeepTheLadderRolling() {
        var m = ladder()
        m.adults[0].expectedAnnualGrantUsd = 100_000
        m.adults[0].expectedGrantVestYears = 4
        let h = m.buildHousehold(asOf: asOf)

        // Years well beyond the last real tranche now carry value.
        XCTAssertGreaterThan(Engine.vestingNetInYear(h, year: 8, asOf: asOf), 0,
                             "no future grant vests in year 8 — the ladder stopped rolling")
        // NOT lastVestPlanYear — that measures the AWARDED tie-in horizon and deliberately
        // ignores expected grants. The ladder rolling is a statement about the income stream.
        XCTAssertGreaterThan(Engine.vestingNetInYear(h, year: 20, asOf: asOf), 0,
                             "future grants should keep landing while the client is still working")
        XCTAssertEqual(Engine.lastVestPlanYear(h, asOf: asOf), 4,
                       "expected grants leaked into the awarded tie-in horizon")

        // Mirror: with no expectation stated, nothing is invented.
        let none = ladder().buildHousehold(asOf: asOf)
        XCTAssertEqual(Engine.vestingNetInYear(none, year: 8, asOf: asOf), 0, accuracy: 1,
                       "a household that stated no future grants was given some anyway")

        // A client already PAST their retirement age gets no future grants at all.
        //
        // The real ladder's own tranches fill plan years 1-4, and the grant loop is clamped with
        // `max(1, retirementAge - age)` so a retired person would still receive one year's award
        // vesting into exactly those years. Probing year 8 therefore could not tell "no future
        // grants" from "one future grant that has already finished vesting" — the arm has to hold
        // NO listed grants, so anything landing in years 1-4 can only have been invented.
        var retired = ladder()
        retired.adults[0].rsuGrants = []
        retired.adults[0].retirementAge = 30          // age 36 today
        retired.adults[0].expectedAnnualGrantUsd = 100_000
        let rh = retired.buildHousehold(asOf: asOf)
        for y in 1...8 {
            XCTAssertEqual(Engine.vestingNetInYear(rh, year: y, asOf: asOf), 0, accuracy: 1,
                           "plan year \(y) awarded a grant to someone already past their retirement age")
        }
        XCTAssertEqual(Engine.lastVestPlanYear(rh, asOf: asOf), 0,
                       "a retired client with no listed grants still has a vesting horizon")
    }

    // MARK: - Concentration

    /// Unvested employer stock is single-employer exposure, and it must be measured on the net
    /// figure like everything else — on gross it overstates the breach.
    func testSingleEmployerConcentrationSeesTheGrants() {
        var m = ladder()
        m.taxableUsd = 1_000                                  // make the grants dominate
        m.adults[0].rsuGrants[0].unitsUnvested = 20_000       // a genuinely concentrated position
        let e = Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf)
        XCTAssertTrue(e.findings.contains { $0.ruleId == "employer_credit_concentration" },
                      "a book dominated by unvested employer stock did not trip the concentration rule")
    }

    /// An expected future grant is an INCOME STREAM, not an asset. The employer has not made it;
    /// the client does not own it; it cannot be sold, pledged or diversified.
    ///
    /// Counting it as owned inflates net worth by the whole remaining career. On the first real
    /// case study a $60k expected annual grant over 29 working years appeared as $1,030,218 of
    /// "unvested" value and took net worth from $178k to $1.2M before this separation existed.
    func testExpectedGrantsAreIncomeNotAnAsset() {
        var m = ladder()
        m.adults[0].expectedAnnualGrantUsd = 60_000
        m.adults[0].expectedGrantVestYears = 4
        let h = m.buildHousehold(asOf: asOf)
        let awardedNet = 471 * 62.69 * (1 - 0.4178)

        // Not owned: absent from every ownership measure.
        XCTAssertEqual(Engine.unvestedNetUsd(h), awardedNet, accuracy: 1,
                       "expected future grants are being counted as unvested value the client owns")
        XCTAssertEqual(Engine.deferredCompNetUsd(h), awardedNet, accuracy: 1,
                       "expected future grants reached the balance sheet")
        XCTAssertEqual(Engine.lastVestPlanYear(h, asOf: asOf), 4,
                       "the employer tie-in horizon should count AWARDED grants only")

        // But they are income: they show up in the years they land.
        XCTAssertGreaterThan(Engine.vestingNetInYear(h, year: 6, asOf: asOf), 0,
                             "expected grants vanished from the income stream as well")

        // And the balance sheet agrees with the ownership measure.
        let e = Engine.evaluate(h, asOf: asOf)
        XCTAssertEqual(e.balanceSheet.assets.unvestedCompUsd, awardedNet, accuracy: 1,
                       "the balance sheet's unvested line disagrees with what the client owns")

        // Mirror: awarded grants must still reach the balance sheet.
        var awardedOnly = ladder()
        awardedOnly.adults[0].expectedAnnualGrantUsd = 0
        let a = Engine.evaluate(awardedOnly.buildHousehold(asOf: asOf), asOf: asOf)
        XCTAssertEqual(a.balanceSheet.assets.unvestedCompUsd, awardedNet, accuracy: 1,
                       "awarded grants stopped reaching the balance sheet")
    }

    /// Single-employer concentration prices what is AWARDED. A grant the employer has not yet made
    /// is not exposure to that employer, and counting it would fire the rule on everyone whose
    /// comp includes stock.
    func testConcentrationPricesAwardedGrantsOnly() {
        var m = ladder()
        m.taxableUsd = 1_000
        m.adults[0].expectedAnnualGrantUsd = 500_000   // enormous, and entirely in the future
        let e = Engine.evaluate(m.buildHousehold(asOf: asOf), asOf: asOf)
        let fired = e.findings.first { $0.ruleId == "employer_credit_concentration" }
        if let fired {
            XCTAssertLessThan(fired.magnitudeUsd, 471 * 62.69,
                              "concentration is being measured on grants the employer has not made")
        }
    }
}
