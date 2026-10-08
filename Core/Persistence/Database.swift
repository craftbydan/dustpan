import Foundation
import GRDB

/// Dustpan's SQLite store: the cleanup log, the ignore list and settings.
/// Scan results never go here; they stay in memory.
struct AppDatabase: Sendable {
    static let fileName = "dustpan.sqlite"

    let dbQueue: DatabaseQueue
    let fileURL: URL

    /// Opens (creating if needed) `dustpan.sqlite` inside `directory` and runs migrations.
    /// Tests pass a temp directory; the app uses `openDefault()`.
    init(directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(Self.fileName, isDirectory: false)
            var configuration = Configuration()
            configuration.label = "Dustpan"
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            try Self.migrator.migrate(queue)
            self.dbQueue = queue
            self.fileURL = url
        } catch {
            throw DustpanError.databaseUnavailable
        }
    }

    /// A database that lives in memory for this session only. Used when the file can't be
    /// opened (so cleanups can still be undone until quit) and by DEBUG demo runs.
    static func inMemory() throws -> AppDatabase {
        do {
            var configuration = Configuration()
            configuration.label = "Dustpan (memory)"
            let queue = try DatabaseQueue(configuration: configuration)
            try migrator.migrate(queue)
            return AppDatabase(dbQueue: queue, fileURL: URL(fileURLWithPath: ":memory:"))
        } catch {
            throw DustpanError.databaseUnavailable
        }
    }

    private init(dbQueue: DatabaseQueue, fileURL: URL) {
        self.dbQueue = dbQueue
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/Dustpan/dustpan.sqlite`
    static func openDefault() throws -> AppDatabase {
        try AppDatabase(directory: defaultDirectory())
    }

    static func defaultDirectory() throws -> URL {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return support.appendingPathComponent("Dustpan", isDirectory: true)
        } catch {
            throw DustpanError.databaseUnavailable
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "cleanupLog") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .datetime).notNull()
                t.column("originalPath", .text).notNull()
                t.column("trashPath", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("ruleID", .text)
                t.column("restoredAt", .datetime)
            }
            try db.create(table: "ignoreEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text)
                t.column("ruleID", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        // v2 (Prompt 4): small key/value settings ("onboarding completed", "limited scan").
        migrator.registerMigration("v2") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return migrator
    }
}
