import Foundation
import GRDB
import os

/// Reads and writes the cleanup log and the ignore list (`cleanupLog`, `ignoreEntry`).
///
/// Only the `Cleaner` writes log rows (one transaction per clean). Without a database file the
/// store runs on an in-memory database, so a session's cleanups can still be put back.
actor CleanupStore {
    private let database: AppDatabase?
    private let logger = Logger(subsystem: "app.dustpan", category: "history")

    init(database: AppDatabase?) {
        self.database = database ?? (try? AppDatabase.inMemory())
    }

    // MARK: - Cleanup log

    /// Inserts every row in one transaction and returns them with their new IDs.
    func insert(_ rows: [CleanupLog]) throws -> [CleanupLog] {
        guard !rows.isEmpty else { return [] }
        let database = try require()
        return try database.dbQueue.write { db in
            try rows.map { row in
                var row = row
                try row.insert(db)
                return row
            }
        }
    }

    /// Every log row, newest first.
    func logs() throws -> [CleanupLog] {
        try require().dbQueue.read { db in
            try CleanupLog.order(Column("date").desc, Column("id").desc).fetchAll(db)
        }
    }

    func logs(ids: [Int64]) throws -> [CleanupLog] {
        try require().dbQueue.read { db in try CleanupLog.fetchAll(db, keys: ids) }
    }

    /// Marks rows as put back, in one transaction.
    func markRestored(_ ids: [Int64], at date: Date) throws {
        guard !ids.isEmpty else { return }
        try require().dbQueue.write { db in
            _ = try CleanupLog.filter(keys: ids).updateAll(db, Column("restoredAt").set(to: date))
        }
    }

    // MARK: - Ignore list

    func ignoreEntries() throws -> [IgnoreEntry] {
        try require().dbQueue.read { db in
            try IgnoreEntry.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    /// Stops suggesting one path (and everything inside it).
    @discardableResult
    func ignore(path: String, at date: Date = Date()) throws -> IgnoreEntry {
        try insertIgnore(IgnoreEntry(id: nil, path: path, ruleID: nil, createdAt: date))
    }

    /// Stops suggesting anything a rule finds.
    @discardableResult
    func ignore(ruleID: String, at date: Date = Date()) throws -> IgnoreEntry {
        try insertIgnore(IgnoreEntry(id: nil, path: nil, ruleID: ruleID, createdAt: date))
    }

    private func insertIgnore(_ entry: IgnoreEntry) throws -> IgnoreEntry {
        var entry = entry
        try require().dbQueue.write { db in try entry.insert(db) }
        return entry
    }

    func removeIgnore(id: Int64) throws {
        _ = try require().dbQueue.write { db in try IgnoreEntry.deleteOne(db, key: id) }
    }

    /// The ignore list in the form the junk scanner takes.
    func ignoreList() -> IgnoreList {
        do {
            return IgnoreList(try ignoreEntries())
        } catch {
            logger.error("Ignore list unreadable: \(error.localizedDescription, privacy: .private)")
            return IgnoreList()
        }
    }

    private func require() throws -> AppDatabase {
        guard let database else { throw DustpanError.databaseUnavailable }
        return database
    }
}

/// Paths and rules the user asked Dustpan to stop suggesting. Paths match case-insensitively
/// and cover everything inside them.
struct IgnoreList: Sendable, Equatable {
    private(set) var paths: [String] = []
    private(set) var ruleIDs: Set<String> = []

    init(paths: [String] = [], ruleIDs: Set<String> = []) {
        self.paths = paths.map { $0.lowercased() }
        self.ruleIDs = ruleIDs
    }

    init(_ entries: [IgnoreEntry]) {
        self.init(paths: entries.compactMap(\.path), ruleIDs: Set(entries.compactMap(\.ruleID)))
    }

    var isEmpty: Bool { paths.isEmpty && ruleIDs.isEmpty }

    func ignores(path: String, ruleID: String) -> Bool {
        if ruleIDs.contains(ruleID) { return true }
        return paths.contains { PathTools.isInside(path, root: $0) }
    }
}
