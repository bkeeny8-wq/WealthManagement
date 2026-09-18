import XCTest
@testable import WealthPolicyDesk

/// A client can be exported from two menus: per-client from the roster, and as part of the
/// whole-book NDJSON/CSV. Both must produce the same record, or the same household leaves
/// the device with two different required returns depending on which button was pressed.
///
/// That agreement previously lived only inside a `private` helper on a SwiftUI View, which
/// no test could reach — reverting it to `intake.buildHousehold().applying(committed)`
/// silently dropped the driver overrides and the equity-style re-flavour, and the suite
/// stayed green.
final class ExportAgreementTests: XCTestCase {

    /// A record that exercises every layer the composition has to fold in: committed moves,
    /// committed tilts, driver overrides and an equity-style tilt.
    private func layeredRecord() -> ClientRecord {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1970; a.retirementAge = 65
                      a.salaryUsd = 300_000; return a }()]
        m.taxableUsd = 1_200_000; m.traditionalUsd = 800_000; m.rothUsd = 150_000
        m.retirementSpendingUsd = 180_000; m.annualSavingsUsd = 60_000; m.state = "NJ"

        var practice = PracticeMetadata()
        practice.clientName = "Ada Test"; practice.advisorName = "Advisor"

        var rec = ClientRecord(intake: m, practice: practice)
        var o = HouseholdOverrides()
        o.legacyFloorUsd = 750_000
        o.annualSavingsUsd = 95_000                     // materially different from intake
        o.usEquityStyle = USEquityStyleTilt(large: .value, mid: .value, small: .value)
        rec.driverOverrides = o
        return rec
    }

    /// The headline: the roster CSV and the per-client record must be the same record.
    func testTheBookExportUsesTheSameRecordAsThePerClientExport() {
        let rec = layeredRecord()
        let direct = rec.exportRecord()
        let viaBook = BookExport.ndjson([rec])
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let expected = String(data: try! enc.encode(direct), encoding: .utf8)!
        XCTAssertEqual(viaBook, expected, "the whole-book export and the per-client export disagree")
    }

    func testTheCsvRowMatchesTheSameRecord() {
        let rec = layeredRecord()
        let rows = BookExport.csv([rec]).split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 2, "header plus one client")
        XCTAssertEqual(rows[1], rec.exportRecord().csvRow())
    }

    /// The composition must actually fold the overrides in. Dropping them is the exact
    /// regression the private helper allowed, so the exported figure has to MOVE when an
    /// override changes.
    func testDriverOverridesReachTheExportedFigures() {
        let base = layeredRecord()
        var raised = base
        raised.driverOverrides.annualSavingsUsd = 250_000

        let a = base.exportRecord(), b = raised.exportRecord()
        XCTAssertNotEqual(a.requiredRealReturnBps, b.requiredRealReturnBps,
                          "an override that changes savings by $155k must move the exported required return")
        XCTAssertGreaterThan(a.requiredRealReturnBps ?? 0, b.requiredRealReturnBps ?? 0,
                             "saving more must lower the required return")
        XCTAssertEqual(a.solved, true)
        XCTAssertNotNil(a.requiredRealReturnBps)
        XCTAssertNotNil(a.fundedRatioBps)
    }

    /// And the equity-style tilt, which re-flavours the synthesized proxies before committed
    /// moves are replayed against them.
    func testTheEquityStyleTiltReachesTheExportedHousehold() {
        var growth = layeredRecord()
        growth.driverOverrides.usEquityStyle = USEquityStyleTilt(large: .growth, mid: .growth, small: .growth)
        var value = layeredRecord()
        value.driverOverrides.usEquityStyle = USEquityStyleTilt(large: .value, mid: .value, small: .value)

        let growthTickers = Set(growth.household().positions.map(\.ticker))
        let valueTickers = Set(value.household().positions.map(\.ticker))
        XCTAssertNotEqual(growthTickers, valueTickers, "the style tilt must re-flavour the exported book")
        XCTAssertTrue(growthTickers.contains("VUG"), "large-cap growth should hold VUG")
        XCTAssertTrue(valueTickers.contains("VTV"), "large-cap value should hold VTV")
    }

    /// Archived clients stay out of the roster export, but the per-client record still
    /// builds — the filter belongs to the book, not the record.
    func testArchivedClientsAreExcludedFromTheBookButStillExportable() {
        var rec = layeredRecord()
        rec.archived = true
        XCTAssertEqual(BookExport.ndjson([rec]), "", "an archived client is not part of the roster export")
        XCTAssertFalse(rec.exportRecord().client.isEmpty, "but the record itself still builds")
    }

    /// Unsolvable plans must not ship the 20% / 999% clamp as a CRM rate.
    func testUnsolvablePlansExportASolvedFlagAndOmitSentinelRates() {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.birthYear = 1985; a.retirementAge = 65
                      a.salaryUsd = 150_000; return a }()]
        m.taxableUsd = 25_000
        m.emergencyReserveUsd = 50_000
        m.retirementSpendingUsd = 20_000
        let rec = ClientRecord(intake: m, practice: PracticeMetadata())
        let row = rec.exportRecord()
        XCTAssertFalse(row.solved)
        XCTAssertNil(row.requiredRealReturnBps, "a 20% ceiling is a sentinel, not a required return")
        XCTAssertNil(row.fundedRatioBps)
        let csv = row.csvRow()
        XCTAssertTrue(csv.contains("false"), "CSV must flag solved=false")
        XCTAssertTrue(csv.contains("—"), "CSV must not print the clamp as a number")
    }

    /// Export age follows the plan date, not the intake module's pinned 2026.
    func testExportedPrimaryAgeFollowsThePlanDate() {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.birthYear = 1975; a.retirementAge = 65
                      a.salaryUsd = 200_000; return a }()]
        m.taxableUsd = 1_000_000
        m.retirementSpendingUsd = 80_000
        var rec = ClientRecord(intake: m, practice: PracticeMetadata())
        rec.planAsOf = "2031-06-30"
        XCTAssertEqual(m.primaryAge, 51, "fixture check: the intake wheel still uses 2026")
        XCTAssertEqual(rec.exportRecord().primaryAge, 56,
                       "a 2031 review must export age 56, not the 2026 age of 51")
    }

    /// Roster `displayName` already falls back to the primary adult; CRM export and the
    /// desk strip must use the same name when the envelope's clientName was left blank.
    func testExportFallsBackToThePrimaryAdultName() {
        var m = IntakeModel()
        m.adults = [{ var a = IntakeAdult(); a.name = "Ada Lovelace"; a.birthYear = 1985
                      a.retirementAge = 65; a.salaryUsd = 150_000; return a }()]
        m.taxableUsd = 1_000_000
        m.retirementSpendingUsd = 80_000
        var practice = PracticeMetadata()
        practice.clientName = ""
        let rec = ClientRecord(intake: m, practice: practice)
        XCTAssertEqual(rec.displayName, "Ada Lovelace")
        XCTAssertEqual(rec.exportRecord().client, "Ada Lovelace")
        XCTAssertEqual(practice.header(fallbackName: rec.displayName).title, "Ada Lovelace")
    }
}
