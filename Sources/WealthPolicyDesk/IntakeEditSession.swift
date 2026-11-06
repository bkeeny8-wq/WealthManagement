//  IntakeEditSession.swift
//  WealthPolicyDesk
//
//  What the intake editor is opened ON, as a single value.
//
//  "Edit client profile" used to work by writing the seed into one piece of view state
//  and raising a separate "show the editor" flag in the same gesture. The editor was
//  then presented from a closure that READ that state back. It read it stale: the
//  presentation machinery holds the content closure from an earlier evaluation, so the
//  seed it saw was the default `IntakeModel()` the flag-and-seed pair had been
//  initialized with, not the record just written into it. The form came up blank on a
//  client with thirty-two holdings — and blank with a "Create my policy statement"
//  button under it, one tap from writing that emptiness back over the plan.
//
//  The seed cannot go stale if it is not read at presentation time. This type IS the
//  presentation: the editor is shown because a session exists, and the session carries
//  the answers it was built from. There is no second place to keep them in step with.

import Foundation

public struct IntakeEditSession: Identifiable, Hashable {
    /// Fresh per open. Presentation identity hangs off it, so each open rebuilds the
    /// editor rather than reviving whatever the last one left behind.
    public let id: UUID
    /// The book record being edited. nil ⇒ a client the book does not hold yet.
    public let editingId: UUID?
    /// The answers the editor opens on — the record's own, for an existing client.
    public let intake: IntakeModel
    public let practice: PracticeMetadata
    /// The record's plan date, so the editor's review card ages against the plan it is
    /// editing rather than against today. nil for a new client.
    public let planAsOf: IsoDate?

    public init(id: UUID = UUID(), editingId: UUID?, intake: IntakeModel,
                practice: PracticeMetadata, planAsOf: IsoDate?) {
        self.id = id; self.editingId = editingId; self.intake = intake
        self.practice = practice; self.planAsOf = planAsOf
    }

    /// A blank page, for a client the book does not hold yet.
    public static func newClient() -> IntakeEditSession {
        IntakeEditSession(editingId: nil, intake: IntakeModel(), practice: PracticeMetadata(), planAsOf: nil)
    }

    /// The editor for a record already in the book, seeded from that record.
    public static func editing(_ rec: ClientRecord) -> IntakeEditSession {
        IntakeEditSession(editingId: rec.id, intake: rec.intake, practice: rec.practice, planAsOf: rec.planAsOf)
    }

    /// The one decision behind "Edit client profile": which answers the form opens on.
    /// An id the book holds opens that record's stored intake — never a fresh model —
    /// and anything else opens a blank new client.
    public static func open(_ id: UUID?, in book: [ClientRecord]) -> IntakeEditSession {
        guard let id, let rec = book.first(where: { $0.id == id }) else { return .newClient() }
        return .editing(rec)
    }
}

// MARK: - "Nothing has been answered"

public extension IntakeModel {
    /// True when this model carries no fact about a client at all: the state the form is
    /// in before anyone types, and the state an editor that failed to load its record
    /// comes up in.
    ///
    /// Compared STRUCTURALLY against a default-constructed model rather than by listing
    /// the fields that count as answers. A hand-written list stops protecting the fields
    /// added after it was written, silently — this one covers every field the model will
    /// ever have. Only the adults' identities are neutralized: a UUID is not an answer.
    var answersNothing: Bool {
        var blank = IntakeModel()
        blank.adults = adults.map { adult in
            var a = IntakeAdult()
            a.id = adult.id
            return a
        }
        return self == blank
    }
}

// MARK: - What a record will accept back from the editor

public extension ClientRecord {
    /// Whether `candidate` may replace this record's stored intake.
    ///
    /// An intake that answers nothing is refused over one that answers something. That
    /// combination is not a client who deleted every answer — the form has no gesture
    /// that would do it, and no reason to offer one — it is an editor that came up empty
    /// over a populated record. The plan is worth more than the keystroke, so the save is
    /// refused and the advisor is told, rather than the record being quietly flattened.
    ///
    /// A record that answers nothing itself accepts anything: there is nothing to lose.
    func accepts(_ candidate: IntakeModel) -> Bool {
        if intake.answersNothing { return true }
        return !candidate.answersNothing
    }
}

// MARK: - Applying the editor's result to the book

/// What happens to the book when the editor is saved. Pure, so the decision — above all
/// the refusal — is reachable by the suite instead of living inside a SwiftUI view where
/// nothing but the running app can exercise it.
public enum IntakeCommit {
    public enum Outcome: Equatable {
        /// The record with this id now holds the edited answers.
        case updated(UUID)
        /// A new record with this id joined the book.
        case appended(UUID)
        /// Nothing was written: the editor held no answers and the record does.
        case refusedWouldBlankRecord
    }

    public static func apply(_ session: IntakeEditSession,
                             intake: IntakeModel,
                             practice: PracticeMetadata,
                             to book: [ClientRecord],
                             newRecordPlanAsOf: IsoDate,
                             now: Date = Date()) -> (book: [ClientRecord], outcome: Outcome) {
        var book = book
        // An editingId the book no longer holds (deleted on another screen while the form
        // was open) falls through to the append branch rather than writing nothing.
        if let editId = session.editingId, let i = book.firstIndex(where: { $0.id == editId }) {
            guard book[i].accepts(intake) else { return (book, .refusedWouldBlankRecord) }
            book[i].intake = intake
            book[i].practice = practice
            book[i].updatedAt = now
            return (book, .updated(editId))
        }
        let rec = ClientRecord(intake: intake, practice: practice, updatedAt: now, planAsOf: newRecordPlanAsOf)
        book.append(rec)
        return (book, .appended(rec.id))
    }
}
