import Foundation
import GRDB
import Testing

@testable import Dustpan

@Suite("Settings store")
struct SettingsStoreTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DustpanTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Migration v2 adds the setting table and leaves v1 tables alone")
    func migration() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = try AppDatabase(directory: dir)
        try database.dbQueue.read { db in
            #expect(Set(try db.columns(in: "setting").map(\.name)) == ["key", "value"])
            #expect(try db.tableExists("cleanupLog"))
            #expect(try db.tableExists("ignoreEntry"))
            let applied = try AppDatabase.migrator.appliedMigrations(db)
            #expect(applied == ["v1", "v2"])
        }
    }

    @Test("Values round-trip and survive reopening the database")
    func persists() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SettingsStore(database: try AppDatabase(directory: dir))
        #expect(await store.bool(.onboardingCompleted) == false)
        await store.set(true, for: .onboardingCompleted)
        await store.set(true, for: .limitedScanChosen)
        await store.set(false, for: .limitedScanChosen)
        #expect(await store.bool(.onboardingCompleted))

        let reopened = SettingsStore(database: try AppDatabase(directory: dir))
        #expect(await reopened.bool(.onboardingCompleted))
        #expect(await reopened.bool(.limitedScanChosen) == false)

        await reopened.remove(.onboardingCompleted)
        let third = SettingsStore(database: try AppDatabase(directory: dir))
        #expect(await third.bool(.onboardingCompleted) == false)
        let rows = try await AppDatabase(directory: dir).dbQueue.read { try SettingRecord.fetchCount($0) }
        #expect(rows == 1)
    }

    @Test("Without a database, values live in memory")
    func memoryOnly() async {
        let store = SettingsStore(database: nil)
        #expect(await store.bool(.limitedScanChosen) == false)
        await store.set(true, for: .limitedScanChosen)
        #expect(await store.bool(.limitedScanChosen))
    }
}
