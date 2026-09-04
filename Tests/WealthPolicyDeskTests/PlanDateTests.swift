import XCTest
@testable import WealthPolicyDesk

/// The plan date used to be a module constant (`Engine.planningAsOf`, pinned to 2026-08-11),
/// so every household ever opened was evaluated as if it were that day: a client onboarded a
/// year later was still aged, retirement-dated and RMD-scheduled off the pin, and the
/// annual-review cycle the app is built around could not advance time at all.
///
/// The fix carries the date ON the household (`Household.planAsOf`), stamped by the view
/// layer when a client record is created or a review is saved. The engine stays pure — it
/// never reads a clock, it reads the date the household was handed.
///
/// These tests lock the four things that has to mean: the date reaches the engine, it
/// actually ages the plan, it survives a save/reload, and no legacy plan or seeded fixture
/// moves because of it.
final class PlanDateTests: XCTestCase {

    private let later: IsoDate = "2031-06-30"      // ~5 years past the pin

    // MARK: - The date reaches the engine

    /// `evaluate` must default to the household's OWN date. If it silently fell back to the
    /// module pin, every downstream date-sensitive number (ages, years-to-retirement, RMD
    /// start, glide position) would be computed for 2026 no matter what the record says.
    func testEvaluateDefaultsToTheHouseholdsOwnPlanDate() {
        var h = Seed.sampleHousehold
        h.planAsOf = later
        XCTAssertEqual(Engine.evaluate(h).asOf, later, "the household's plan date must drive the evaluation")
        XCTAssertEqual(Engine.evaluate(Seed.sampleHousehold).asOf, Engine.planningAsOf,
                       "a household that never set one still evaluates as of the pinned date")
    }

    /// The explicit parameter remains available for re-running a delivered plan as of the day
    /// it was delivered, and must win over the stored date.
    func testExplicitAsOfOverridesTheStoredDate() {
        var h = Seed.sampleHousehold
        h.planAsOf = later
        XCTAssertEqual(Engine.evaluate(h, asOf: "2026-01-01").asOf, "2026-01-01")
    }

    // MARK: - The date actually ages the plan

    /// The point of the whole change: five years on, the client is five years older and five
    /// years closer to retirement. A frozen date reports the same distance forever.
    func testALaterPlanDateAgesTheClientAndShortensTheRunway() {
        var intake = IntakeModel()
        intake.adults = [{ var a = IntakeAdult(); a.name = "A"; a.birthYear = 1975; a.retirementAge = 65; a.salaryUsd = 200_000; return a }()]
        intake.retirementStartAge = 65
        intake.planToAge = 95
        intake.taxableUsd = 1_000_000

        let now = intake.buildHousehold(asOf: "2026-08-11")
        let then = intake.buildHousehold(asOf: later)

        XCTAssertEqual(Engine.age(birthDate: now.primary!.birthDate, asOf: now.planAsOf), 51)
        XCTAssertEqual(Engine.age(birthDate: then.primary!.birthDate, asOf: then.planAsOf), 56,
                       "five calendar years must age the client five years")
        XCTAssertEqual(Engine.householdSaveYears(now, asOf: now.planAsOf), 14)
        XCTAssertEqual(Engine.householdSaveYears(then, asOf: then.planAsOf), 9,
                       "the accumulation runway must shrink as the plan ages")
    }

    /// `buildHousehold` derives the goal calendar from the plan date too, not just the ages —
    /// retirement must not stay a fixed number of years away.
    func testRetirementGoalMovesCloserAsThePlanAges() {
        var intake = IntakeModel()
        intake.adults = [{ var a = IntakeAdult(); a.birthYear = 1975; a.retirementAge = 65; return a }()]
        intake.retirementStartAge = 65
        intake.planToAge = 95
        func retirementStart(_ asOf: IsoDate) -> Int {
            intake.buildHousehold(asOf: asOf).goals
                .first { $0.id == "g_spending" }?.outflows.map(\.year).min() ?? -1
        }
        XCTAssertEqual(retirementStart("2026-08-11"), 14)
        XCTAssertEqual(retirementStart(later), 9, "retirement is nine years out in 2031, not fourteen")
    }

    /// The stamped date must survive the trip through the record, not be re-derived.
    func testClientRecordEvaluatesAsOfItsOwnStampedDate() {
        var intake = IntakeModel()
        intake.adults = [{ var a = IntakeAdult(); a.birthYear = 1975; a.retirementAge = 65; a.salaryUsd = 200_000; return a }()]
        intake.taxableUsd = 2_000_000
        var rec = ClientRecord(intake: intake, practice: PracticeMetadata())
        rec.planAsOf = later
        XCTAssertEqual(rec.household().planAsOf, later)
        XCTAssertEqual(Engine.evaluate(rec.household()).asOf, later,
                       "opening a client must evaluate the plan as of the date it is dated")
    }

    // MARK: - Nothing that already exists moves

    /// Every plan written before this field existed was evaluated at the pin. Decoding one
    /// must reproduce that exactly — a JSON with no `planAsOf` key is not a plan dated today.
    func testLegacyRecordsWithoutAPlanDateDecodeToThePinnedDate() throws {
        let legacy = """
        {"id":"00000000-0000-0000-0000-0000000000AA","intake":{},"practice":{},
         "updatedAt":"2025-01-02T03:04:05Z","archived":false,"actions":[]}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let rec = try d.decode(ClientRecord.self, from: legacy)
        XCTAssertEqual(rec.planAsOf, Engine.planningAsOf,
                       "a pre-existing plan must keep evaluating exactly as it did before the field was added")
        XCTAssertEqual(rec.household().planAsOf, Engine.planningAsOf)
    }

    /// A default-constructed household and a default-built intake both sit on the pin, which
    /// is what keeps the golden master and every existing test stable.
    func testDefaultsStayPinned() {
        XCTAssertEqual(IntakeModel().buildHousehold().planAsOf, Engine.planningAsOf,
                       "an intake that names no date builds a household on the pin")
        XCTAssertEqual(Seed.sampleHousehold.planAsOf, Engine.planningAsOf,
                       "the shipped sample is a fixed teaching case and must not drift with the calendar")
    }

    /// An IPS review records the date the plan was drawn as of, so review history reads as a
    /// timeline rather than a stack of undated snapshots.
    func testReviewRecordsThePlanDateItWasDrawnAsOf() {
        var h = Seed.sampleHousehold
        h.planAsOf = later
        let review = IPSReview.from(Engine.evaluate(h), overrides: HouseholdOverrides(),
                                    at: Date(timeIntervalSinceReferenceDate: 700_000_000), note: "annual")
        XCTAssertEqual(review.planAsOf, later)
    }

    // MARK: - The clock read itself

    /// The one clock read in the module is a pure function of the Date it is handed, and has
    /// no default argument — an engine routine cannot pick up the wall clock by omission.
    func testTodayIsoDateFormatsTheDateItIsGiven() {
        var c = DateComponents(); c.year = 2031; c.month = 6; c.day = 30; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone.current
        XCTAssertEqual(todayIsoDate(cal.date(from: c)!), "2031-06-30")
        c.year = 2027; c.month = 1; c.day = 5
        XCTAssertEqual(todayIsoDate(cal.date(from: c)!), "2027-01-05", "single digits are zero-padded")
    }
}
