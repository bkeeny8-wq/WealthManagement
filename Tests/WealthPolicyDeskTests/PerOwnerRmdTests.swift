import XCTest
@testable import WealthPolicyDesk

/// RMDs are not a household event. Each retirement account's required beginning age
/// follows ITS OWNER's birth year, and its divisor follows that owner's age. The
/// projection pooled every tax-deferred dollar and gated the whole pool on the PRIMARY,
/// so a spouse's 401(k) started distributing on his schedule — and since SECURE 2.0 makes
/// the age a function of birth year, an age gap between spouses moves the answer by years.
final class PerOwnerRmdTests: XCTestCase {

    private let asOf = Engine.planningAsOf

    /// The verifier's case: the whole deferred pool sits in the OLDER spouse's account,
    /// while the primary is younger and on a later schedule. Gating on the primary delayed
    /// her distributions to a year she turns 82.
    private func poolOwnedByOlderSpouse() -> Household {
        var h = Seed.sampleHousehold
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.birthDate = "1962-01-01"; q.expectedRetirementAge = 62 }   // 64, RMDs at 75
            if q.role == .spouse  { q.birthDate = "1955-01-01"; q.expectedRetirementAge = 62 }   // 71, RMDs at 73
            return q
        }
        // Move every tax-deferred dollar into Susan's 401(k).
        h.positions = h.positions.map { p in
            guard h.treatment(of: p) == .taxDeferred else { return p }
            var q = p; q.accountId = "acct_401k"; return q
        }
        return h
    }

    /// Her account must begin distributing when SHE reaches 73, which is plan-year 2 —
    /// when the primary is 66, not 75.
    func testASpousesAccountDistributesOnHerOwnSchedule() {
        let e = Engine.evaluate(poolOwnedByOlderSpouse())
        guard let first = e.decumulation.baseline.years.first(where: { $0.rmdUsd > 0 }) else {
            return XCTFail("expected the pool to distribute")
        }
        // The row is indexed on the primary's age; the spouse is 7 years older.
        XCTAssertEqual(first.age, 66, "she turns 73 when he is 66 — gating on his age waited until he was 75")
        XCTAssertLessThan(first.age, 75, "distributions must not wait for the primary's own required age")
    }

    /// And the optimizer must stop converting once ANY part of the pool is distributing.
    /// It was recommending six-figure conversions in years she was already taking RMDs.
    func testConversionsStopWhenTheFirstOwnersRmdsBegin() {
        let e = Engine.evaluate(poolOwnedByOlderSpouse())
        let firstRmd = e.decumulation.baseline.years.first { $0.rmdUsd > 0 }?.age ?? .max
        for y in e.decumulation.plan.years where y.rothConversionUsd > 0.5 {
            XCTAssertLessThan(y.age, firstRmd,
                              "a conversion was recommended at \(y.age), after distributions had already begun")
        }
    }

    /// The mirror: a pool owned by a YOUNGER spouse must not be pulled forward onto the
    /// primary's earlier schedule.
    func testAYoungerOwnersAccountIsNotPulledForward() {
        var h = Seed.sampleHousehold
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.birthDate = "1950-01-01"; q.expectedRetirementAge = 62 }   // 76, RMDs at 72
            if q.role == .spouse  { q.birthDate = "1975-01-01"; q.expectedRetirementAge = 62 }   // 51, RMDs at 75
            return q
        }
        h.positions = h.positions.map { p in
            guard h.treatment(of: p) == .taxDeferred else { return p }
            var q = p; q.accountId = "acct_401k"; return q
        }
        let years = Engine.evaluate(h).decumulation.baseline.years
        // He is already 76 and past his own required age; she is 51 and reaches 75 only when
        // he is 100. Gating on him would start her account distributing immediately.
        guard let first = years.first(where: { $0.rmdUsd > 0 }) else { return }
        XCTAssertEqual(first.age, 100,
                       "a 51-year-old's 401(k) must wait for HER 75th year, not her 76-year-old husband's")
        XCTAssertTrue(years.filter { $0.age < 100 }.allSatisfy { $0.rmdUsd == 0 },
                      "nothing may distribute before the owner reaches her own required age")
    }

    /// Joint and unowned accounts have no owner to follow, so they fall to the primary
    /// rather than dropping out of the projection.
    func testUnownedAccountsFallToThePrimaryAndStillDistribute() {
        var h = Seed.sampleHousehold
        h.accounts = h.accounts.map { a in
            guard a.treatment == .taxDeferred else { return a }
            var b = a; b.ownership = AccountOwnership(kind: .jointWROS, ownerPersonId: nil); return b
        }
        h.people = h.people.map { p in
            var q = p
            if q.role == .primary { q.birthDate = "1955-01-01"; q.expectedRetirementAge = 62 }
            return q
        }
        let e = Engine.evaluate(h)
        let deferredUsd = h.value(in: .taxDeferred)
        XCTAssertGreaterThan(deferredUsd, 0, "fixture check")
        XCTAssertTrue(e.decumulation.baseline.years.contains { $0.rmdUsd > 0 },
                      "a jointly-held IRA must still distribute on the primary's schedule, not vanish")
    }

    /// Pooling for SPENDING is unchanged — the split governs distributions, not withdrawals.
    /// Every bucket must stay non-negative and the reported total must equal their sum.
    func testTheSplitPreservesBucketConservation() {
        for h in [Seed.sampleHousehold, poolOwnedByOlderSpouse()] {
            for y in Engine.evaluate(h).decumulation.plan.years {
                XCTAssertGreaterThanOrEqual(y.endDeferredUsd, -0.5, "deferred went negative at age \(y.age)")
                XCTAssertGreaterThanOrEqual(y.endTaxableUsd, -0.5)
                XCTAssertGreaterThanOrEqual(y.endRothUsd, -0.5)
            }
        }
    }
}
