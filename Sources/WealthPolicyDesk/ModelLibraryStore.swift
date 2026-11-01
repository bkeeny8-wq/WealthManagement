//  ModelLibraryStore.swift
//  WealthPolicyDesk
//
//  On-device persistence for the advisor's OWN model portfolios, in their own file
//  (wealth-policy-models.json) beside the book. A separate file because the book file's
//  top level is `[ClientRecord]` — a bare JSON array — so there is nowhere to add a
//  sibling key without breaking every book already on a device.
//
//  Nothing in the engine's evaluation path reads this. An assignment FREEZES the model's
//  weights onto the ClientRecord, so `ClientRecord.household()` stays IO-free and a
//  delivered plan reproduces whether or not this file still exists. This store exists only
//  so the advisor's picking surface survives a relaunch.
//
//  The corrupt-file discipline is BookStore's, deliberately duplicated rather than
//  factored out: a shared helper would put the client book's recovery path one edit away
//  from a change made for the model library.

import Foundation

public enum ModelLibraryStore {
    /// Tests point this at a temp directory so they never touch the device Documents folder.
    public static var directoryOverride: URL? = nil
    /// Set when `load()` moved a corrupt library aside, so the view layer can say so.
    public private(set) static var lastCorruptBackupFilename: String? = nil

    private static var dir: URL? {
        if let directoryOverride { return directoryOverride }
        return try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
    private static var url: URL? { dir?.appendingPathComponent("wealth-policy-models.json") }
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// Load the advisor's custom models. A present-but-undecodable file is CORRUPT, not
    /// empty: it is moved aside so a later save cannot destroy recoverable work. Missing
    /// file or corrupt file both yield an empty custom set, whose `.all` is the built-ins.
    public static func load() -> ModelLibrary {
        lastCorruptBackupFilename = nil
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return ModelLibrary() }
        if let data = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(ModelLibrary.self, from: data) {
            return lib
        }
        backupCorruptFile(url)
        return ModelLibrary()
    }

    /// Atomic write (temp file + rename) so a crash cannot truncate the library.
    @discardableResult
    public static func save(_ lib: ModelLibrary) -> Bool {
        guard let url, let data = try? encoder.encode(lib) else { return false }
        do { try data.write(to: url, options: atomicWriteOptions); return true } catch { return false }
    }

    private static var atomicWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtectionUnlessOpen]
        #else
        .atomic
        #endif
    }

    static func corruptBackupFilename(at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "wealth-policy-models.corrupt-\(f.string(from: date)).json"
    }

    private static func backupCorruptFile(_ url: URL) {
        guard let dir else { return }
        var name = corruptBackupFilename(at: Date())
        var backup = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            name = corruptBackupFilename(at: Date()).replacingOccurrences(of: ".json", with: "-\(n).json")
            backup = dir.appendingPathComponent(name)
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            lastCorruptBackupFilename = name
        } catch {
            try? FileManager.default.copyItem(at: url, to: backup)
            try? FileManager.default.removeItem(at: url)
            if FileManager.default.fileExists(atPath: backup.path) { lastCorruptBackupFilename = name }
        }
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }

    public static func clearAll() { if let url { try? FileManager.default.removeItem(at: url) } }
}
