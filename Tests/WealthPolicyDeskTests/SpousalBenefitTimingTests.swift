import XCTest
@testable import WealthPolicyDesk

/// A spousal Social Security benefit cannot begin until the WORKER has filed for their own —
/// the spouse's filing does not unlock it. That was unreachable while one household claiming
/// age applied to both people. Per-person claiming ages made it reachable, and a spouse
/// claiming at 62 against a worker claiming at 70 collected eight years of a benefit nobody
/// was entitled to yet.
final class SpousalBenefitTimingTests: XCTestCase {

    private let asOf = Engine.planningAsOf

    /// A high earner and a spouse whose own benefit is far below half the earner's, so the
    /// spouse is genuinely taking the spousal benefit.
    private func household(workerClaims: Int, spouseClaims: Int) -> Household {
        var m = IntakeModel()
        var a = IntakeAdult(); a.name = "Ada"; a.birthYear = 1964; a.retirementAge = 62
        a.salaryUsd = 300_000; a.socialSecurityMonthlyUsd = 4_000; a.ssClaimAge = workerClaims
        a.traditionalUsd = 800_000
        var b = IntakeAdult(); b.name = "Ben"; b.birthYear = 1964; b.retirementAge = 62
        b.salaryUsd = 20_000; b.socialSecurityMonthlyUsd = 500; b.ssClaimAge = spouseClaims
        m.adults = [a, b]
        m.taxableUsd = 900_000
        m.retirementSpendingUsd = 150_000
        return m.buildHousehold()
    }

    private func income(_ h: Household, atAge: Int) -> Usd {
        let now = Engine.age(birthDate: h.primary!.birthDate, asOf: asOf)
        return Engine.socialSecurityAnnual(h, year: atAge - now, asOf: asOf)
    }

    /// The defect: with the worker filing at 70, nothing spousal may arrive at 63.
    func testNoSpousalBenefitBeforeTheWorkerHasFiled() {
        let h = household(workerClaims: 70, spouseClaims: 62)
        // Ben's OWN benefit ($500/mo = $6,000/yr) may start at 62. The spousal top-up to half
        // of Ada's may not, so the household's income before Ada files must stay near Ben's
        // own benefit rather than jumping to half of Ada's.
        let beforeAdaFiles = income(h, atAge: 65)
        XCTAssertLessThan(beforeAdaFiles, 12_000,
                          "the household is collecting a spousal benefit years before the worker filed (got \(Int(beforeAdaFiles)))")
    }

    /// And once the worker files, it does arrive.
    func testTheSpousalBenefitArrivesOnceTheWorkerFiles() {
        let h = household(workerClaims: 70, spouseClaims: 62)
        let after = income(h, atAge: 72)
        XCTAssertGreaterThan(after, income(h, atAge: 65),
                             "the spousal benefit must begin once the worker has claimed")
    }

    /// When the worker files FIRST, the spouse's own claiming age governs — the gate must
    /// not delay a benefit the worker has already unlocked. (Comparing two different worker
    /// claim ages would confound the gate with the delayed-retirement credit, which
    /// legitimately reduces an early claimer's own benefit for life.)
    func testTheGateDoesNotDelayABenefitTheWorkerHasAlreadyUnlocked() {
        let h = household(workerClaims: 62, spouseClaims: 67)
        let beforeSpouseFiles = income(h, atAge: 66)
        let afterSpouseFiles = income(h, atAge: 68)
        XCTAssertGreaterThan(beforeSpouseFiles, 0, "the worker has filed, so the household has income at 66")
        XCTAssertGreaterThan(afterSpouseFiles, beforeSpouseFiles,
                             "the spousal benefit must begin at the spouse's own claiming age, not later")
    }

    /// A single filer has no spousal leg and must be untouched by any of this.
    func testASingleFilerIsUnaffected() {
        var m = IntakeModel()
        var a = IntakeAdult(); a.birthYear = 1964; a.retirementAge = 62
        a.salaryUsd = 200_000; a.socialSecurityMonthlyUsd = 3_000; a.ssClaimAge = 67
        m.adults = [a]; m.taxableUsd = 800_000; m.retirementSpendingUsd = 120_000
        let h = m.buildHousehold()
        XCTAssertEqual(income(h, atAge: 66), 0, accuracy: 1, "nothing before 67")
        XCTAssertGreaterThan(income(h, atAge: 68), 30_000, "and the full benefit after")
    }
}
