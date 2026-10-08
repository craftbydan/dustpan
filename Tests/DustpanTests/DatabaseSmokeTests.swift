import Foundation
import GRDB
import Testing

@testable import Dustpan

@Suite("Database smoke")
struct DatabaseSmokeTests {
    @Test("Migration v1 creates cleanupLog and ignoreEntry with the CLAUDE.md columns")
    func tablesExist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DustpanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try AppDatabase(directory: dir)
        #expect(database.fileURL.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: database.fileURL.path))

        try database.dbQueue.read { db in
            #expect(try db.tableExists("cleanupLog"))
            #expect(try db.tableExists("ignoreEntry"))

            let logColumns = Set(try db.columns(in: "cleanupLog").map(\.name))
            #expect(logColumns == ["id", "date", "originalPath", "trashPath", "bytes", "ruleID", "restoredAt"])

            let ignoreColumns = Set(try db.columns(in: "ignoreEntry").map(\.name))
            #expect(ignoreColumns == ["id", "path", "ruleID", "createdAt"])
        }
    }

    @Test("Vendored xxHash links and matches the reference value for empty input")
    func xxHashLinks() {
        let hash = [UInt8]().withUnsafeBytes { XXHash.hash64($0) }
        #expect(hash == 0x2D06_8005_38D3_94C2)
    }

    @Test("Records round-trip through both tables")
    func recordsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DustpanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try AppDatabase(directory: dir)
        try database.dbQueue.write { db in
            var log = CleanupLog(
                id: nil, date: Date(), originalPath: "/tmp/a", trashPath: "/tmp/.Trash/a",
                bytes: 4096, ruleID: "test", restoredAt: nil)
            try log.insert(db)
            #expect(log.id != nil)

            var entry = IgnoreEntry(id: nil, path: "/tmp/b", ruleID: nil, createdAt: Date())
            try entry.insert(db)
            #expect(entry.id != nil)
        }
        let counts = try database.dbQueue.read { db in
            (try CleanupLog.fetchCount(db), try IgnoreEntry.fetchCount(db))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 1)
    }

    @Test("rules.json ships in the app bundle")
    func resourcesLoad() {
        #expect(Bundle.main.url(forResource: "rules", withExtension: "json") != nil)
    }
}
