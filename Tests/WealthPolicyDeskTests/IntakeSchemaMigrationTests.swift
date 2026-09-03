import XCTest
@testable import WealthPolicyDesk

/// Guards the data-loss landmine the audit found: the intake's child records used
/// synthesized Codable, which FAILS a value outright when a newly-added non-optional key
/// is absent from older JSON. The parent decodes each array inside a `try?`, so one such
/// element discarded EVERY element — and the next save wrote that loss to disk.
final class IntakeSchemaMigrationTests: XCTestCase {

    private func twoAdultTwoHoldingIntake() -> IntakeModel {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Robert"; a.birthYear = 1963; a.salaryUsd = 220_000
        var b = IntakeAdult(); b.name = "Susan";  b.birthYear = 1965; b.salaryUsd = 140_000
        m.adults = [a, b]
        var p = IntakeHeldPosition(); p.ticker = "VOO"; p.marketValueUsd = 400_000; p.costBasisUsd = 100_000
        var q = IntakeHeldPosition(); q.ticker = "AAPL"; q.marketValueUsd = 250_000; q.costBasisUsd = 30_000
        m.heldAwayPositions = [p, q]
        return m
    }

    /// Drop `key` from the first element of the array stored at `arrayKey`, simulating JSON
    /// written before that field existed.
    private func encodeDropping(_ key: String, fromFirstOf arrayKey: String, _ m: IntakeModel) throws -> Data {
        let data = try JSONEncoder().encode(m)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var arr = try XCTUnwrap(obj[arrayKey] as? [[String: Any]])
        XCTAssertNotNil(arr.first?[key], "fixture check: '\(key)' should be present before we strip it")
        arr[0].removeValue(forKey: key)
        obj[arrayKey] = arr
        return try JSONSerialization.data(withJSONObject: obj)
    }

    /// The headline case: one adult missing a field must not cost the client BOTH adults.
    func testMissingFieldOnOneAdultDoesNotWipeTheHousehold() throws {
        let m = twoAdultTwoHoldingIntake()
        let mangled = try encodeDropping("salaryUsd", fromFirstOf: "adults", m)
        let back = try JSONDecoder().decode(IntakeModel.self, from: mangled)

        XCTAssertEqual(back.adults.count, 2, "both adults must survive a single missing key")
        XCTAssertEqual(back.adults[0].name, "Robert", "the rest of that adult's data is intact")
        XCTAssertEqual(back.adults[0].birthYear, 1963)
        XCTAssertEqual(back.adults[0].salaryUsd, IntakeAdult().salaryUsd, "only the absent field falls back to its default")
        XCTAssertEqual(back.adults[1].name, "Susan", "the untouched adult is unaffected")
        XCTAssertEqual(back.adults[1].salaryUsd, 140_000)
    }

    /// Same guarantee for the holdings the Portfolio tab depends on.
    func testMissingFieldOnOneHoldingDoesNotWipeThePortfolio() throws {
        let m = twoAdultTwoHoldingIntake()
        let mangled = try encodeDropping("costBasisUsd", fromFirstOf: "heldAwayPositions", m)
        let back = try JSONDecoder().decode(IntakeModel.self, from: mangled)

        XCTAssertEqual(back.heldAwayPositions.count, 2, "both holdings must survive")
        XCTAssertEqual(back.heldAwayPositions[0].ticker, "VOO")
        XCTAssertEqual(back.heldAwayPositions[1].ticker, "AAPL")
        XCTAssertEqual(back.heldAwayPositions[1].costBasisUsd, 30_000)
    }

    /// A wholly unreadable element degrades to defaults rather than taking the array with it.
    func testUnreadableElementDoesNotTakeTheArrayWithIt() throws {
        let m = twoAdultTwoHoldingIntake()
        let data = try JSONEncoder().encode(m)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var arr = try XCTUnwrap(obj["adults"] as? [[String: Any]])
        arr[0] = ["name": "Robert"]                       // almost everything gone
        obj["adults"] = arr
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONSerialization.data(withJSONObject: obj))

        XCTAssertEqual(back.adults.count, 2)
        XCTAssertEqual(back.adults[0].name, "Robert")
        XCTAssertEqual(back.adults[1].name, "Susan", "the healthy record is untouched")
    }

    /// Optional fields added later must decode as nil, not as a failure.
    func testNewOptionalFieldIsAbsentSafely() throws {
        var m = IntakeModel()
        var p = IntakeHeldPosition(); p.ticker = "MSFT"; p.marketValueUsd = 100_000; p.sector = .technology
        m.heldAwayPositions = [p]
        let data = try JSONEncoder().encode(m)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var arr = try XCTUnwrap(obj["heldAwayPositions"] as? [[String: Any]])
        arr[0].removeValue(forKey: "sector")
        obj["heldAwayPositions"] = arr
        let back = try JSONDecoder().decode(IntakeModel.self, from: try JSONSerialization.data(withJSONObject: obj))

        XCTAssertEqual(back.heldAwayPositions.count, 1)
        XCTAssertEqual(back.heldAwayPositions[0].ticker, "MSFT")
        XCTAssertNil(back.heldAwayPositions[0].sector)
    }
}
