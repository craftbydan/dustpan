import Foundation
import GRDB

/// One item Dustpan moved to the Trash. Written by the Cleaner, read by the undo history.
struct CleanupLog: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "cleanupLog"

    var id: Int64?
    var date: Date
    var originalPath: String
    var trashPath: String
    var bytes: Int64
    var ruleID: String?
    var restoredAt: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A path or rule the user asked Dustpan to stop suggesting.
struct IgnoreEntry: Codable, Sendable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "ignoreEntry"

    var id: Int64?
    var path: String?
    var ruleID: String?
    var createdAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One stored setting (key/value text). Read and written through `SettingsStore`.
struct SettingRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"

    var key: String
    var value: String
}
