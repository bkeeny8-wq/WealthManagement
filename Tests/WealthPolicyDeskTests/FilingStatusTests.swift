import XCTest
@testable import WealthPolicyDesk

/// A household cannot be married and filing single.
///
/// The form allowed it: toggling on the second adult left the filing chips wherever they
/// were, and SINGLE is the default. The engine then priced that household — as MFS, since
/// the two share brackets over most of the range — which on a two-earner couple cost 18 bps
/// of required return (294 vs 276) and three points of funded ratio (74.2% vs 77.1%).
///
/// Only the impossible combination is corrected. MFS and HOH are real choices for a married
/// household and must survive untouched, or the correction is just a different defect.
final class FilingStatusTests: XCTestCase {

    private func household(adults n: Int, filing: FilingStatus) -> IntakeModel {
        var m = IntakeModel()
        m.adults = (0..<n).map { i in
            var a = IntakeAdult()
            a.name = ["A", "B"][i]
            a.birthYear = Engine.year(Engine.planningAsOf) - 55
            a.retirementAge = 65
            a.salaryUsd = i == 0 ? 250_000 : 150_000
            return a
        }
        m.filingStatus = filing; m.state = "NJ"; m.planToAge = 92
        m.taxableUsd = 2_000_000; m.retirementSpendingUsd = 220_000; m.annualSavingsUsd = 60_000
        return m
    }

    /// The correction itself, at the boundary where the household reaches the engine.
    func testAMarriedRosterIsNeverHandedToTheEngineAsASingleFiler() {
        XCTAssertEqual(household(adults: 2, filing: .single).buildHousehold().filingStatus, .mfj,
                       "a two-adult roster reached the engine filing SINGLE")
    }

    /// And the mirror, which is where a careless correction does its damage: every other
    /// combination passes through exactly as entered.
    func testEveryOtherCombinationIsPassedThroughUntouched() {
        for filing in [FilingStatus.mfj, .mfs, .hoh] {
            XCTAssertEqual(household(adults: 2, filing: filing).buildHousehold().filingStatus, filing,
                           "a couple's \(filing) was overwritten")
        }
        for filing in FilingStatus.allCases {
            XCTAssertEqual(household(adults: 1, filing: filing).buildHousehold().filingStatus, filing,
                           "a single filer's \(filing) was overwritten")
        }
    }

    /// The consequence, not just the label. A couple who never touched the chips must be
    /// priced the way a couple is priced — identically to one who chose MFJ, and measurably
    /// apart from one who chose MFS.
    func testTheDefaultCoupleIsPricedAsMarriedNotAsSeparate() {
        func rr(_ filing: FilingStatus) -> Bps {
            Engine.evaluate(household(adults: 2, filing: filing).buildHousehold())
                .requiredReturn.requiredRealReturnBps
        }
        let untouched = rr(.single), joint = rr(.mfj), separate = rr(.mfs)
        XCTAssertEqual(untouched, joint,
            "a couple who left the chips alone is priced at \(untouched) bps, not the \(joint) a couple pays")
        XCTAssertNotEqual(joint, separate,
            "fixture check: MFJ and MFS price identically here, so this comparison cannot detect the defect")
    }

    /// No household the matrix builds is married and filing single, whatever route it took.
    func testNoMatrixHouseholdIsMarriedAndFilingSingle() {
        var married = 0
        for c in HouseholdMatrix.built {
            let adults = c.household.people.filter { $0.role == .primary || $0.role == .spouse }
            guard adults.count > 1 else { continue }
            married += 1
            XCTAssertNotEqual(c.household.filingStatus, .single,
                              "\(c.name): \(adults.count) adults filing SINGLE")
        }
        XCTAssertGreaterThan(married, 0, "fixture check: the matrix holds no couples, so this asserts nothing")
    }
}
