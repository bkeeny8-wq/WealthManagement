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

    /// The spousal TOP-UP waits for the worker; the spouse's OWN benefit does not.
    ///
    /// Asserted as an equality against the exact own benefit. The previous version asserted
    /// only an upper bound, which zero satisfies — and zero is precisely what the first
    /// version of this gate produced, by clamping the whole leg instead of just the top-up.
    /// A spouse with an $1,800/mo PIA claiming at 62 against a worker claiming at 70 lost
    /// nine years of earned benefit, about $136,000, and the test passed.
    func testTheSpouseKeepsTheirOwnBenefitWhileTheTopUpWaitsForTheWorker() {
        let h = household(workerClaims: 70, spouseClaims: 62)
        // Ben: $500/mo PIA claimed at 62, five years before an FRA of 67 ⇒ −6%/yr.
        let ownAnnual = 500.0 * 12 * (1 - 0.06 * 5)
        XCTAssertEqual(income(h, atAge: 65), ownAnnual, accuracy: 1,
                       "the spouse's own earned benefit must be paid from their own claim age")
        XCTAssertGreaterThan(ownAnnual, 0, "fixture check")
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

    /// Claiming EARLY must never be strictly worse than claiming late. Carrying the
    /// early-claim haircut through years the gate pays nothing made a spouse claiming at 62
    /// receive the same first payment as one claiming at 70, permanently smaller for life.
    func testClaimingEarlyIsNeverStrictlyDominated() {
        let early = household(workerClaims: 70, spouseClaims: 62)
        let late  = household(workerClaims: 70, spouseClaims: 70)
        // Claiming late legitimately pays MORE later — delaying your own benefit earns
        // credits. What must not happen is claiming early paying less for life while
        // starting no sooner, which is what a permanent early-claim haircut on a top-up the
        // gate had not yet begun paying produced.
        XCTAssertGreaterThan(income(early, atAge: 65), 0,
                             "claiming at 62 must actually pay from 62, years before the worker files")
        XCTAssertEqual(income(late, atAge: 65), 0, accuracy: 1, "fixture check: claiming at 70 pays nothing at 65")

        // The top-up itself commences at 70 in both cases, so neither may carry an
        // early-claim reduction on it. Ada's own benefit is identical either way, so the
        // difference between the two households at 72 is exactly the difference in BEN's own
        // benefit — nothing more.
        let benOwnEarly = 500.0 * 12 * (1 - 0.06 * 5)
        let benOwnLate  = 500.0 * 12 * (1 + 0.08 * 3)
        XCTAssertEqual(income(late, atAge: 72) - income(early, atAge: 72),
                       benOwnLate - benOwnEarly, accuracy: 1,
                       "the spousal top-up is being reduced for an early claim it never paid out on")
    }

    /// Spousal eligibility is a fact about whose PIA is higher, not about the order the
    /// adults were typed into intake. The same two people, statements and claim ages gave
    /// $18,000/yr and 132 bps of required return apart depending on who was entered first.
    func testEligibilityDoesNotDependOnDataEntryOrder() {
        func built(highEarnerFirst: Bool) -> Household {
            var m = IntakeModel()
            var hi = IntakeAdult(); hi.name = "Hi"; hi.birthYear = 1964; hi.retirementAge = 62
            hi.salaryUsd = 300_000; hi.socialSecurityMonthlyUsd = 4_000; hi.ssClaimAge = 67
            var lo = IntakeAdult(); lo.name = "Lo"; lo.birthYear = 1964; lo.retirementAge = 62
            lo.salaryUsd = 20_000; lo.socialSecurityMonthlyUsd = 500; lo.ssClaimAge = 67
            m.adults = highEarnerFirst ? [hi, lo] : [lo, hi]
            m.taxableUsd = 900_000; m.retirementSpendingUsd = 150_000
            return m.buildHousehold()
        }
        let a = built(highEarnerFirst: true), b = built(highEarnerFirst: false)
        XCTAssertEqual(income(a, atAge: 70), income(b, atAge: 70), accuracy: 1,
                       "Social Security income turned on data-entry order alone")
        XCTAssertEqual(Engine.evaluate(a).requiredReturn.requiredRealReturnBps,
                       Engine.evaluate(b).requiredReturn.requiredRealReturnBps,
                       "and so did the headline required return")
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
