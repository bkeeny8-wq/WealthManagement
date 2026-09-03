//  Book.swift
//  WealthPolicyDesk
//
//  The book of business — the practice's roster of clients. Each ClientRecord
//  bundles a plan (IntakeModel) with its practice envelope (PracticeMetadata).
//  The book is the CRM "database of sorts": a local, on-device store that a real
//  CRM would one day ingest. Everything here stays on device — no network, no
//  account numbers, no credentials. The export records are the only thing meant
//  to leave, and the advisor moves those by hand.

import Foundation

// MARK: - One client in the book

public struct ClientRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var intake: IntakeModel
    public var practice: PracticeMetadata
    public var updatedAt: Date
    public var archived: Bool
    /// The plan of record's committed moves (sell/rotate), layered on the
    /// synthesized household in order. Staged (uncommitted) moves never land here.
    public var actions: [PlannedAction]
    /// The plan of record's committed tactical tilts (sentiment-sourced sleeve
    /// deviations). Staged (uncommitted) tilts never land here.
    public var tilts: [TacticalTiltAction] = []
    /// Foundational assumptions the advisor edited straight from the Policy Statement,
    /// layered on top of the intake-derived household (the standardized answer is kept).
    public var driverOverrides: HouseholdOverrides = HouseholdOverrides()
    /// Dated IPS snapshots — the year-over-year review history.
    public var reviews: [IPSReview] = []

    public init(id: UUID = UUID(), intake: IntakeModel, practice: PracticeMetadata, updatedAt: Date = Date(), archived: Bool = false, actions: [PlannedAction] = [], tilts: [TacticalTiltAction] = [], driverOverrides: HouseholdOverrides = HouseholdOverrides(), reviews: [IPSReview] = []) {
        self.id = id; self.intake = intake; self.practice = practice; self.updatedAt = updatedAt; self.archived = archived; self.actions = actions; self.tilts = tilts; self.driverOverrides = driverOverrides; self.reviews = reviews
    }

    /// Forward-compatible decode: a missing/renamed field never drops the record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        intake = ((try? c.decodeIfPresent(IntakeModel.self, forKey: .intake)) ?? nil) ?? IntakeModel()
        practice = ((try? c.decodeIfPresent(PracticeMetadata.self, forKey: .practice)) ?? nil) ?? PracticeMetadata()
        updatedAt = ((try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil) ?? Date()
        archived = ((try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? nil) ?? false
        actions = ((try? c.decodeIfPresent([PlannedAction].self, forKey: .actions)) ?? nil) ?? []
        tilts = ((try? c.decodeIfPresent([TacticalTiltAction].self, forKey: .tilts)) ?? nil) ?? []
        driverOverrides = ((try? c.decodeIfPresent(HouseholdOverrides.self, forKey: .driverOverrides)) ?? nil) ?? HouseholdOverrides()
        reviews = ((try? c.decodeIfPresent([IPSReview].self, forKey: .reviews)) ?? nil) ?? []
        if intake.adults.isEmpty { intake.adults = [IntakeAdult()] }   // invariant: ≥1 adult
    }

    public mutating func touch() { updatedAt = Date() }

    /// The committed moves only (the plan of record).
    public var committedActions: [PlannedAction] { actions.filter { $0.status == .committed } }
    /// The committed tactical tilts only.
    public var committedTilts: [TacticalTiltAction] { tilts.filter { $0.status == .committed } }

    /// The household of record: the synthesized household with every committed move
    /// applied in order, carrying the committed tactical tilts so the engine can
    /// deviate the tactical allocation. This is what the desk and exports evaluate.
    /// The plan of record: the intake-built household with the equity STYLE applied first,
    /// then committed moves replayed, then the remaining driver overrides.
    ///
    /// Ordering matters. The style re-flavors synthesized proxies (VOO becomes VUG when
    /// large cap is set to growth), and a committed move is matched by (account, ticker).
    /// Replaying moves BEFORE the re-flavor meant every trade staged against the styled
    /// ticker silently found nothing to sell and vanished. Applying the style up front
    /// means moves are replayed against the tickers the advisor actually saw.
    public func household() -> Household {
        var h = intake.buildHousehold().withEquityStyle(driverOverrides.usEquityStyle ?? USEquityStyleTilt())
        h = h.applying(committedActions)
        h.tacticalTilts = committedTilts
        return h.withDriverOverrides(driverOverrides)
    }

    /// Per-move replay status against the freshly synthesized household — flags a
    /// committed move an intake edit has since orphaned (sold holding gone) or
    /// clamped (sold holding shrank below the recorded amount).
    /// Replay must see the same tickers `household()` does, or a move against a styled
    /// proxy is reported as orphaned when it is actually fine.
    public func committedStatuses() -> [CommittedMoveStatus] {
        intake.buildHousehold()
            .withEquityStyle(driverOverrides.usEquityStyle ?? USEquityStyleTilt())
            .replayStatuses(committedActions)
    }

    /// Best available display name: the CRM name, else the primary adult, else a placeholder.
    public var displayName: String {
        if !practice.clientName.isEmpty { return practice.clientName }
        let n = intake.adults.first?.name ?? ""
        return n.isEmpty ? "New client" : n
    }
}

// MARK: - The store (a single JSON file holding the whole book)

public enum BookStore {
    private static var dir: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    private static var url: URL? { dir?.appendingPathComponent("wealth-policy-book.json") }
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Load the book. A present-but-undecodable file is treated as CORRUPT, not
    /// missing: it is moved aside (never silently overwritten) so a later save can't
    /// destroy a recoverable book. Only a genuinely absent file triggers the one-time
    /// migration of a pre-book single-client install into a one-record book — and the
    /// legacy files are retired only after the new book is confirmed written.
    public static func load() -> [ClientRecord] {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let book = try? decoder.decode([ClientRecord].self, from: data) {
                return book
            }
            backupCorruptFile(url)   // preserve it; start clean rather than clobber
            return []
        }
        if let legacyIntake = IntakeStore.load() {
            let rec = ClientRecord(intake: legacyIntake, practice: PracticeStore.load() ?? PracticeMetadata())
            if save([rec]) { IntakeStore.clear(); PracticeStore.clear() }   // retire only after a durable write
            return [rec]
        }
        return []
    }

    /// Atomic write (temp file + rename) so a crash or full disk can't truncate the
    /// book into a corrupt half-file. Returns whether the write durably succeeded.
    @discardableResult
    public static func save(_ book: [ClientRecord]) -> Bool {
        guard let url, let data = try? encoder.encode(book) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    /// Move a corrupt book aside, preserving the first corruption seen.
    private static func backupCorruptFile(_ url: URL) {
        guard let dir else { return }
        let backup = dir.appendingPathComponent("wealth-policy-book.corrupt.json")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.moveItem(at: url, to: backup)
        }
    }

    public static func clearAll() { if let url { try? FileManager.default.removeItem(at: url) } }
}

// MARK: - Book-level CRM export (the sync artifact)

/// The whole book, rendered as the interchange format a CRM would ingest. Active
/// (non-archived) clients only. NDJSON is one CRMExportRecord per line; CSV is a
/// header plus one row per client. Both are computed from a fresh evaluation, so
/// the planning-flag columns reflect the canonical plan, not any live what-ifs.
public enum BookExport {
    private static func record(_ rec: ClientRecord) -> CRMExportRecord {
        rec.practice.exportRecord(intake: rec.intake, evaluation: Engine.evaluate(rec.household()))
    }

    public static func ndjson(_ book: [ClientRecord]) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        return book.filter { !$0.archived }.compactMap { rec in
            (try? enc.encode(record(rec))).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
    }

    public static func csv(_ book: [ClientRecord]) -> String {
        let rows = book.filter { !$0.archived }.map { record($0).csvRow() }
        return ([CRMExportRecord.csvHeader] + rows).joined(separator: "\n")
    }
}
