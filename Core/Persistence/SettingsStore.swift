import Foundation
import GRDB
import os

/// Small app settings, kept in the `setting` table (migration v2).
///
/// Without a database (it failed to open, or the app is hosted by tests) values live in
/// memory for the session, so the app still works; they are just not remembered.
actor SettingsStore {
    enum Key: String, CaseIterable, Sendable {
        /// The user finished the first-run steps (either way).
        case onboardingCompleted = "onboarding.completed"
        /// The user chose "Continue with limited scan" — don't show the steps again at launch.
        case limitedScanChosen = "onboarding.limitedScanChosen"
        /// When the last Sweep finished or cleaned (seconds since 1970, as text).
        case lastSwept = "sweep.lastSwept"
        /// Menu-bar item and its extras (Prompt 13). All off by default.
        case menuBarEnabled = "menuBar.enabled"
        case launchAtLogin = "menuBar.launchAtLogin"
        case reminderEnabled = "reminder.enabled"
        /// `Calendar` weekday, 1 = Sunday … 7 = Saturday.
        case reminderWeekday = "reminder.weekday"
        case reminderHour = "reminder.hour"
        case reminderMinute = "reminder.minute"
        case lowDiskEnabled = "lowDisk.enabled"
        /// Whole gigabytes (1 GB = 10⁹ bytes, as `ByteCountFormatter(.file)` shows them).
        case lowDiskThresholdGB = "lowDisk.thresholdGB"
        /// When the last low-disk notification went out (rate limit).
        case lowDiskLastAlert = "lowDisk.lastAlert"
        /// The Space map's "Click a block to select it" hint was used once; show it as a "?" since.
        case spaceMapHintSeen = "spaceMap.hintSeen"
    }

    func int(_ key: Key) -> Int? {
        string(key).flatMap { Int($0) }
    }

    func set(_ value: Int, for key: Key) {
        set(String(value), for: key)
    }

    func date(_ key: Key) -> Date? {
        string(key).flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
    }

    func set(_ date: Date, for key: Key) {
        set(String(date.timeIntervalSince1970), for: key)
    }

    private let database: AppDatabase?
    private var memory: [String: String] = [:]
    private let logger = Logger(subsystem: "app.dustpan", category: "settings")

    init(database: AppDatabase?) {
        self.database = database
    }

    func bool(_ key: Key) -> Bool {
        string(key) == "1"
    }

    func set(_ value: Bool, for key: Key) {
        set(value ? "1" : "0", for: key)
    }

    func string(_ key: Key) -> String? {
        if let cached = memory[key.rawValue] { return cached }
        guard let database else { return nil }
        do {
            let value = try database.dbQueue.read { db in
                try SettingRecord.fetchOne(db, key: key.rawValue)?.value
            }
            if let value { memory[key.rawValue] = value }
            return value
        } catch {
            logger.error("Setting read failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func set(_ value: String, for key: Key) {
        memory[key.rawValue] = value
        guard let database else { return }
        do {
            try database.dbQueue.write { db in
                try SettingRecord(key: key.rawValue, value: value).save(db)
            }
        } catch {
            logger.error("Setting write failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func remove(_ key: Key) {
        memory[key.rawValue] = nil
        guard let database else { return }
        do {
            _ = try database.dbQueue.write { db in
                try SettingRecord.deleteOne(db, key: key.rawValue)
            }
        } catch {
            logger.error("Setting delete failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
