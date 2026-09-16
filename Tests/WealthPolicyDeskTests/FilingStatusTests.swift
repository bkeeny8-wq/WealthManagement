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

    /// The exported row's label must be the status its own numbers were solved on. The CRM
    /// record mixes the two sources — `filingStatus` came from the stored field while
    /// `requiredRealReturnBps`, `fundedRatioBps` and `afterTaxNetWorthUsd` come from evaluating
    /// the CORRECTED household — so a plan saved before the intake gate exported a row reading
    /// "single" beside figures solved on MFJ brackets, the MFJ standard deduction, the joint
    /// NIIT threshold and a two-head IRMAA count. Internally consistent and wrong beat
    /// self-contradictory: the fix that corrected the pricing has to reach the label too.
    func testTheExportedFilingStatusIsTheOneTheRowsNumbersWereSolvedOn() {
        var m = household(adults: 2, filing: .mfj)
        m.filingStatus = .single                      // the pre-gate state, set past the UI
        let rec = ClientRecord(intake: m, practice: PracticeMetadata())
        XCTAssertEqual(rec.household().filingStatus, .mfj, "fixture check: the correction fired")
        XCTAssertEqual(rec.exportRecord().filingStatus, rec.household().filingStatus.rawValue,
            "the exported filing_status disagrees with the status its own figures were priced on")
    }

    /// And the mirror: the export must not start overriding a status the household really has.
    func testEveryHonestFilingStatusExportsAsItself() {
        for (n, filing) in [(2, FilingStatus.mfj), (2, .mfs), (2, .hoh), (1, .single), (1, .hoh), (1, .mfj)] {
            let rec = ClientRecord(intake: household(adults: n, filing: filing), practice: PracticeMetadata())
            XCTAssertEqual(rec.exportRecord().filingStatus, filing.rawValue,
                           "\(n) adult(s) filing \(filing) exported as something else")
        }
    }

    /// A plan saved before the gate is repaired on the way IN, so the stored field and the
    /// priced one never diverge in the first place. Without this the filing chips render a
    /// legacy couple with nothing selected at all — `ChoiceChips` has no rendering for a
    /// selection absent from its options, and the gate removes SINGLE from a couple's list.
    func testALegacyCoupleFilingSingleIsRepairedOnDecode() throws {
        let born = Engine.year(Engine.planningAsOf) - 55
        let json = """
        {"adults":[{"birthYear":\(born),"retirementAge":65,"salaryUsd":250000},
                   {"birthYear":\(born),"retirementAge":65,"salaryUsd":150000}],
         "filingStatus":"single","planToAge":92,"taxableUsd":2000000,"retirementSpendingUsd":220000}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(IntakeModel.self, from: json)
        XCTAssertEqual(m.filingStatus, .mfj, "a two-adult roster decoded still filing single")
        XCTAssertEqual(m.filingStatus, m.buildHousehold().filingStatus,
                       "the stored status and the priced status still disagree after decode")
    }

    /// The mirror again: decode must not rewrite a status that is possible.
    func testDecodeLeavesEveryPossibleFilingStatusAlone() throws {
        let born = Engine.year(Engine.planningAsOf) - 55
        let one = "{\"birthYear\":\(born),\"retirementAge\":65,\"salaryUsd\":250000}"
        for (roster, filing) in [("[\(one)]", "single"), ("[\(one)]", "mfj"), ("[\(one)]", "hoh"),
                                 ("[\(one),\(one)]", "mfj"), ("[\(one),\(one)]", "mfs"), ("[\(one),\(one)]", "hoh")] {
            let json = "{\"adults\":\(roster),\"filingStatus\":\"\(filing)\",\"planToAge\":92}".data(using: .utf8)!
            let m = try JSONDecoder().decode(IntakeModel.self, from: json)
            XCTAssertEqual(m.filingStatus.rawValue, filing, "decode rewrote a legitimate \(filing) roster")
        }
    }
}
