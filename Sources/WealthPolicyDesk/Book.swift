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

    public init(id: UUID = UUID(), intake: IntakeModel, practice: PracticeMetadata, updatedAt: Date = Date(), archived: Bool = false) {
        self.id = id; self.intake = intake; self.practice = practice; self.updatedAt = updatedAt; self.archived = archived
    }

    /// Forward-compatible decode: a missing/renamed field never drops the record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil) ?? UUID()
        intake = ((try? c.decodeIfPresent(IntakeModel.self, forKey: .intake)) ?? nil) ?? IntakeModel()
        practice = ((try? c.decodeIfPresent(PracticeMetadata.self, forKey: .practice)) ?? nil) ?? PracticeMetadata()
        updatedAt = ((try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? nil) ?? Date()
        archived = ((try? c.decodeIfPresent(Bool.self, forKey: .archived)) ?? nil) ?? false
        if intake.adults.isEmpty { intake.adults = [IntakeAdult()] }   // invariant: ≥1 adult
    }

    public mutating func touch() { updatedAt = Date() }

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
        rec.practice.exportRecord(intake: rec.intake, evaluation: Engine.evaluate(rec.intake.buildHousehold()))
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
