import XCTest
@testable import WealthPolicyDesk

/// The Roth-conversion window the Tax tab prints has to be the window the projection
/// actually converts in. It was a firm-level seeded constant (age 62–73) written before
/// SECURE 2.0 moved the RMD age, while `decumulation` converts from the primary's
/// retirement until the year before their OWN RMDs begin. For the sample that is 65–74:
/// the tab printed "age 62–73" on the same screen the Decumulation tab reported a first
/// RMD at 75, and it truncated the two highest-value conversion years.
///
/// Anyone whose conversion window is open today was born in 1960 or later, so the wrong
/// figure applied to the entire live cohort.
final class ConversionWindowTests: XCTestCase {

    private func window(_ h: Household) -> (fromAge: Int, toAge: Int)? {
        Engine.evaluate(h).policy.withdrawal.conversionWindow
    }

    /// The sample: Robert, born 1963, retires at 65, RMDs at 75.
    func testTheWindowRunsFromRetirementToTheYearBeforeRmds() {
        guard let w = window(Seed.sampleHousehold) else { return XCTFail("expected a window") }
        XCTAssertEqual(w.fromAge, 65, "conversions start when the primary retires")
        XCTAssertEqual(w.toAge, 74, "and run through the year before RMDs begin at 75")
    }

    /// The printed window must match the ages the projection actually converts in — the
    /// two disagreeing is the whole defect.
    func testThePrintedWindowMatchesWhereConversionsActuallyHappen() {
        var h = Seed.sampleHousehold
        // Scale the deferred balance so the bracket-fill optimizer converts across the
        // whole window rather than draining the account early.
        h.positions = h.positions.map { p in
            guard h.treatment(of: p) == .taxDeferred else { return p }
            var q = p; q.marketValueUsd *= 20; q.costBasisUsd *= 20; return q
        }
        let e = Engine.evaluate(h)
        guard let w = e.policy.withdrawal.conversionWindow else { return XCTFail("expected a window") }
        let converting = e.decumulation.plan.years.filter { $0.rothConversionUsd > 0 }.map(\.age)
        guard let first = converting.min(), let last = converting.max() else {
            return XCTFail("fixture check: expected the optimizer to convert")
        }
        XCTAssertGreaterThanOrEqual(first, w.fromAge, "a conversion happened before the window the tab prints")
        XCTAssertLessThanOrEqual(last, w.toAge, "a conversion happened after the window the tab prints")
        XCTAssertEqual(last, w.toAge, "the window's last year must be usable, not decorative")
    }

    /// Birth year moves the window, because SECURE 2.0 moves the RMD age.
    func testTheWindowFollowsTheClientsOwnRmdAge() {
        func toAge(bornIn year: Int) -> Int? {
            var h = Seed.sampleHousehold
            h.people = h.people.map { p in
                var q = p
                if q.role == .primary { q.birthDate = "\(year)-03-01"; q.expectedRetirementAge = 62 }
                return q
            }
            return window(h)?.toAge
        }
        XCTAssertEqual(toAge(bornIn: 1949), 71, "born before 1951: RMDs at 72")
        XCTAssertEqual(toAge(bornIn: 1955), 72, "born 1951–1959: RMDs at 73")
        XCTAssertEqual(toAge(bornIn: 1963), 74, "born 1960 or later: RMDs at 75")
    }

    /// A client who retires at or past their RMD age has no window, and the card must not
    /// render a backwards range.
    func testRetiringPastRmdAgeReportsNoWindow() {
        var h = Seed.sampleHousehold
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.expectedRetirementAge = 78 }
            return q
        }
        XCTAssertNil(window(h), "there is no retirement-to-RMD window left to convert in")
    }

    /// The seeded firm default must no longer reach a client-facing figure.
    func testTheFirmDefaultIsNoLongerReported() {
        guard let w = window(Seed.sampleHousehold) else { return XCTFail("expected a window") }
        XCTAssertNotEqual(w.toAge, 73, "73 is the pre-SECURE-2.0 default, not this client's RMD age")
        XCTAssertNotEqual(w.fromAge, 62, "62 is a firm placeholder, not this client's retirement age")
    }
}
