import XCTest
@testable import WealthPolicyDesk

/// The intake editor, as a question about values rather than about SwiftUI.
///
/// The defect these guard: "Edit client profile" on a saved client presented an EMPTY
/// form — no name, the default birth year, no state, every balance zero — over a record
/// holding a full plan, with "Create my policy statement" sitting under it. The editor
/// was seeded by writing the answers into one piece of view state and raising a separate
/// "show it" flag in the same gesture; the presentation read that state back stale and
/// got the default model it had been initialized with.
///
/// Two things are asserted here, and neither can be answered by the running app alone:
///   1. opening the editor on a record yields THAT RECORD'S answers, never a fresh model;
///   2. a save carrying no answers cannot replace a record that has them.
final class IntakeEditorTests: XCTestCase {

    // MARK: - Fixtures

    /// A client who has answered things — deliberately spread across several unrelated
    /// corners of the model, so a seed that drops any one branch is caught.
    private func populatedIntake() -> IntakeModel {
        var m = IntakeModel()
        m.adults = [IntakeAdult()]
        m.adults[0].name = "Dana Reyes"
        m.adults[0].birthYear = 1982
        m.adults[0].salaryUsd = 240_000
        m.adults[0].traditionalUsd = 310_000
        m.state = "NJ"
        m.filingStatus = .single
        m.taxableUsd = 185_000
        m.retirementSpendingUsd = 120_000
        m.heldAwayPositions = [held("VOO", 90_000, 55_000), held("BND", 40_000, 41_000)]
        return m
    }

    private func held(_ ticker: String, _ market: Usd, _ basis: Usd) -> IntakeHeldPosition {
        var p = IntakeHeldPosition()
        p.ticker = ticker; p.marketValueUsd = market; p.costBasisUsd = basis
        return p
    }

    private func record(_ intake: IntakeModel, name: String = "Dana Reyes") -> ClientRecord {
        var p = PracticeMetadata()
        p.clientName = name
        return ClientRecord(intake: intake, practice: p, planAsOf: "2026-08-11")
    }

    // MARK: - What the editor opens on

    func testEditingARecordOpensOnThatRecordsStoredAnswers() {
        let rec = record(populatedIntake())
        let book = [record(IntakeModel(), name: "Someone else"), rec]

        let session = IntakeEditSession.open(rec.id, in: book)

        XCTAssertEqual(session.editingId, rec.id, "the editor must be pointed at the record it was opened from")
        XCTAssertEqual(session.intake, rec.intake,
                       "the editor opened on something other than the record's stored intake — this is the blank-form defect")
        XCTAssertEqual(session.practice, rec.practice)
        XCTAssertEqual(session.planAsOf, rec.planAsOf, "the review card must age against the plan being edited, not today")
        XCTAssertFalse(session.intake.answersNothing, "a populated record must never open a form that answers nothing")
    }

    func testTheSeedSurvivesFieldByField() {
        let rec = record(populatedIntake())
        let seed = IntakeEditSession.open(rec.id, in: [rec]).intake

        XCTAssertEqual(seed.adults.first?.name, "Dana Reyes")
        XCTAssertEqual(seed.adults.first?.birthYear, 1982, "the birth year came up at the model default")
        XCTAssertEqual(seed.adults.first?.salaryUsd, 240_000)
        XCTAssertEqual(seed.state, "NJ", "the state came up 'not set'")
        XCTAssertEqual(seed.taxableUsd, 185_000)
        XCTAssertEqual(seed.heldAwayPositions.count, 2, "the holdings did not reach the form")
    }

    func testOpeningWithNoClientIsABlankNewClient() {
        let book = [record(populatedIntake())]
        for id in [nil, UUID()] as [UUID?] {
            let session = IntakeEditSession.open(id, in: book)
            XCTAssertNil(session.editingId, "a session with no record behind it must not be able to overwrite one")
            XCTAssertTrue(session.intake.answersNothing)
        }
    }

    func testEveryOpenIsItsOwnPresentation() {
        let rec = record(populatedIntake())
        XCTAssertNotEqual(IntakeEditSession.open(rec.id, in: [rec]).id,
                          IntakeEditSession.open(rec.id, in: [rec]).id,
                          "identity must change per open, or the editor revives the last one's state")
    }

    // MARK: - "Answers nothing"

    func testAFreshModelAnswersNothing() {
        XCTAssertTrue(IntakeModel().answersNothing)
        var twoBlankAdults = IntakeModel()
        twoBlankAdults.adults = [IntakeAdult(), IntakeAdult()]
        XCTAssertTrue(twoBlankAdults.answersNothing, "adult identities are not answers")
    }

    func testAnySingleAnswerCountsAsAnAnswer() {
        var name = IntakeModel();     name.adults[0].name = "A"
        var year = IntakeModel();     year.adults[0].birthYear = 1982
        var salary = IntakeModel();   salary.adults[0].salaryUsd = 1
        var state = IntakeModel();    state.state = "NJ"
        var taxable = IntakeModel();  taxable.taxableUsd = 1
        var kids = IntakeModel();     kids.childrenBirthYears = [2015]
        var holding = IntakeModel()
        holding.heldAwayPositions = [held("VOO", 1, 1)]

        for (label, m) in [("name", name), ("birth year", year), ("salary", salary), ("state", state),
                           ("taxable", taxable), ("children", kids), ("holdings", holding)] {
            XCTAssertFalse(m.answersNothing, "\(label) is an answer and must register as one")
        }
    }

    func testPopulatedIntakeAnswersSomething() {
        XCTAssertFalse(populatedIntake().answersNothing)
    }

    // MARK: - What a record will accept back

    func testAPopulatedRecordRefusesAnIntakeThatAnswersNothing() {
        let rec = record(populatedIntake())
        XCTAssertFalse(rec.accepts(IntakeModel()),
                       "a blank form must not be allowed to replace a populated plan")
        XCTAssertTrue(rec.accepts(populatedIntake()), "a real edit must still go through")
    }

    func testAnEmptyRecordAcceptsAnything() {
        let rec = record(IntakeModel())
        XCTAssertTrue(rec.accepts(IntakeModel()), "there is nothing to lose, so nothing to refuse")
        XCTAssertTrue(rec.accepts(populatedIntake()))
    }

    // MARK: - The save itself

    func testSavingAnEmptyFormOverAPopulatedRecordWritesNothing() {
        let rec = record(populatedIntake())
        let book = [rec]
        let session = IntakeEditSession.open(rec.id, in: book)

        let result = IntakeCommit.apply(session, intake: IntakeModel(), practice: PracticeMetadata(),
                                        to: book, newRecordPlanAsOf: "2026-11-06")

        XCTAssertEqual(result.outcome, .refusedWouldBlankRecord)
        XCTAssertEqual(result.book, book, "the book must come back untouched — not one field, not updatedAt")
        XCTAssertEqual(result.book.first?.intake, rec.intake)
        XCTAssertEqual(result.book.count, 1, "a refused edit must not append a second record either")
    }

    func testARealEditIsWrittenToTheSameRecord() {
        let rec = record(populatedIntake())
        var edited = populatedIntake()
        edited.taxableUsd = 999_000
        let when = Date(timeIntervalSinceReferenceDate: 760_000_000)

        let result = IntakeCommit.apply(IntakeEditSession.open(rec.id, in: [rec]),
                                        intake: edited, practice: rec.practice,
                                        to: [rec], newRecordPlanAsOf: "2026-11-06", now: when)

        XCTAssertEqual(result.outcome, .updated(rec.id))
        XCTAssertEqual(result.book.count, 1, "editing must update in place, not append a duplicate")
        XCTAssertEqual(result.book[0].id, rec.id)
        XCTAssertEqual(result.book[0].intake.taxableUsd, 999_000)
        XCTAssertEqual(result.book[0].updatedAt, when)
        XCTAssertEqual(result.book[0].planAsOf, rec.planAsOf, "editing answers does not re-date the plan")
    }

    func testANewClientIsAppendedEvenWhenBlank() {
        // A new client legitimately starts with nothing answered — the refusal is about
        // replacing answers, not about creating a record.
        let result = IntakeCommit.apply(.newClient(), intake: IntakeModel(), practice: PracticeMetadata(),
                                        to: [], newRecordPlanAsOf: "2026-11-06")
        guard case .appended(let id) = result.outcome else {
            return XCTFail("a new client must be appended, got \(result.outcome)")
        }
        XCTAssertEqual(result.book.count, 1)
        XCTAssertEqual(result.book[0].id, id)
        XCTAssertEqual(result.book[0].planAsOf, "2026-11-06", "a new record is dated when it is created")
    }

    func testAnEditOfARecordDeletedMeanwhileBecomesANewRecord() {
        let rec = record(populatedIntake())
        let session = IntakeEditSession.open(rec.id, in: [rec])
        // The record is deleted on the roster while the form is open.
        let result = IntakeCommit.apply(session, intake: populatedIntake(), practice: rec.practice,
                                        to: [], newRecordPlanAsOf: "2026-11-06")
        guard case .appended = result.outcome else {
            return XCTFail("answers typed into an open form must not be dropped, got \(result.outcome)")
        }
        XCTAssertEqual(result.book.count, 1)
    }
}
