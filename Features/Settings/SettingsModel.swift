import Foundation
import Observation
import os

/// The Settings screen's state: menu-bar item, launch at login, weekly reminder, low-disk alert.
/// Everything is off by default and saved in the `setting` table.
///
/// Side effects live here: turning the menu-bar item off also turns the login item off;
/// turning a reminder or the low-disk alert on is the only place Dustpan asks for permission
/// to post notifications.
@Observable
@MainActor
final class SettingsModel {
    nonisolated static let defaultWeekday = 2  // Monday
    nonisolated static let defaultHour = 10
    nonisolated static let defaultMinute = 0
    nonisolated static let defaultThresholdGB = 10
    nonisolated static let thresholdRange = 5...200
    nonisolated static let thresholdStep = 5

    private(set) var isLoaded = false
    private(set) var showInMenuBar = false
    private(set) var launchAtLogin = false
    private(set) var reminderOn = false
    private(set) var reminderWeekday = SettingsModel.defaultWeekday
    private(set) var reminderHour = SettingsModel.defaultHour
    private(set) var reminderMinute = SettingsModel.defaultMinute
    private(set) var lowDiskAlertOn = false
    private(set) var lowDiskThresholdGB = SettingsModel.defaultThresholdGB
    /// The user said no to notifications (or turned them off in System Settings).
    private(set) var notificationsBlocked = false

    /// Called after the menu-bar item is turned off (the app may need its Dock icon back).
    var menuBarTurnedOff: () -> Void = {}

    private let store: SettingsStore
    private let loginItem: any LoginItemControlling
    private let notifications: any NotificationScheduling
    /// DEBUG `-forceMenuBar YES`: show the item for this run without saving anything.
    private let forceMenuBar: Bool
    private let logger = Logger(subsystem: "app.dustpan", category: "settings")

    init(
        store: SettingsStore, loginItem: any LoginItemControlling, notifications: any NotificationScheduling,
        forceMenuBar: Bool = false
    ) {
        self.store = store
        self.loginItem = loginItem
        self.notifications = notifications
        self.forceMenuBar = forceMenuBar
    }

    var lowDiskThresholdBytes: Int64 { Self.thresholdBytes(gigabytes: lowDiskThresholdGB) }

    nonisolated static func thresholdBytes(gigabytes: Int?) -> Int64 {
        Int64(gigabytes ?? defaultThresholdGB) * 1_000_000_000
    }

    /// Reads the saved values. Never registers anything or asks for permission.
    func load() async {
        let savedMenuBar = await store.bool(.menuBarEnabled)
        showInMenuBar = forceMenuBar || savedMenuBar
        reminderOn = await store.bool(.reminderEnabled)
        reminderWeekday = Self.clamp(await store.int(.reminderWeekday), 1...7, Self.defaultWeekday)
        reminderHour = Self.clamp(await store.int(.reminderHour), 0...23, Self.defaultHour)
        reminderMinute = Self.clamp(await store.int(.reminderMinute), 0...59, Self.defaultMinute)
        lowDiskAlertOn = await store.bool(.lowDiskEnabled)
        lowDiskThresholdGB = Self.clamp(
            await store.int(.lowDiskThresholdGB), Self.thresholdRange, Self.defaultThresholdGB)

        // The login item's real state wins (it can be removed in System Settings › General › Login Items).
        let saved = await store.bool(.launchAtLogin)
        launchAtLogin = showInMenuBar && saved && loginItem.isEnabled
        if saved != launchAtLogin, !forceMenuBar { await store.set(launchAtLogin, for: .launchAtLogin) }
        // A login item left over while the menu-bar item is off (e.g. the setting changed while the
        // database was unavailable) would open the window at every login: remove it.
        if !showInMenuBar, loginItem.isEnabled { loginItem.setEnabled(false) }

        if reminderOn || lowDiskAlertOn {
            notificationsBlocked = await notifications.permission() == .denied
            await syncReminder()
        }
        isLoaded = true
    }

    // MARK: - Menu bar

    func setShowInMenuBar(_ on: Bool) async {
        guard on != showInMenuBar else { return }
        showInMenuBar = on
        await store.set(on, for: .menuBarEnabled)
        if !on {
            // Acceptance: turning the feature off removes the item *and* the login item.
            if launchAtLogin || loginItem.isEnabled { loginItem.setEnabled(false) }
            launchAtLogin = false
            await store.set(false, for: .launchAtLogin)
            menuBarTurnedOff()
        }
    }

    /// Only offered while the menu-bar item is on (a login item that opens the window every
    /// morning isn't what anyone asked for).
    func setLaunchAtLogin(_ on: Bool) async {
        guard showInMenuBar || !on else { return }
        loginItem.setEnabled(on)
        launchAtLogin = loginItem.isEnabled
        await store.set(launchAtLogin, for: .launchAtLogin)
        if launchAtLogin != on { logger.error("Login item change did not take") }
    }

    // MARK: - Reminders

    func setReminderOn(_ on: Bool) async {
        if on {
            guard await askForNotifications() else { return }
        }
        reminderOn = on
        await store.set(on, for: .reminderEnabled)
        await syncReminder()
    }

    func setReminderWeekday(_ weekday: Int) async {
        reminderWeekday = Self.clamp(weekday, 1...7, Self.defaultWeekday)
        await store.set(reminderWeekday, for: .reminderWeekday)
        await syncReminder()
    }

    func setReminderTime(hour: Int, minute: Int) async {
        reminderHour = Self.clamp(hour, 0...23, Self.defaultHour)
        reminderMinute = Self.clamp(minute, 0...59, Self.defaultMinute)
        await store.set(reminderHour, for: .reminderHour)
        await store.set(reminderMinute, for: .reminderMinute)
        await syncReminder()
    }

    // MARK: - Low disk

    func setLowDiskAlertOn(_ on: Bool) async {
        if on {
            guard await askForNotifications() else { return }
        }
        lowDiskAlertOn = on
        await store.set(on, for: .lowDiskEnabled)
    }

    func setLowDiskThreshold(gigabytes: Int) async {
        lowDiskThresholdGB = Self.clamp(gigabytes, Self.thresholdRange, Self.defaultThresholdGB)
        await store.set(lowDiskThresholdGB, for: .lowDiskThresholdGB)
        // A new threshold deserves a fresh alert.
        await store.remove(.lowDiskLastAlert)
    }

    // MARK: - Helpers

    /// Asks macOS (its prompt shows the first time only). False when notifications are off.
    private func askForNotifications() async -> Bool {
        let granted: Bool
        switch await notifications.permission() {
        case .allowed: granted = true
        case .denied: granted = false
        case .notDetermined: granted = await notifications.requestPermission()
        }
        notificationsBlocked = !granted
        return granted
    }

    /// Schedules (or replaces) the weekly reminder, or removes it. Never asks for permission.
    private func syncReminder() async {
        guard reminderOn else {
            await notifications.removePending([DustpanNotification.weeklyID])
            return
        }
        guard await notifications.permission() == .allowed else { return }
        do {
            try await notifications.add(
                DustpanNotification.weekly(weekday: reminderWeekday, hour: reminderHour, minute: reminderMinute))
        } catch {
            logger.error("Reminder scheduling failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    #if DEBUG
        /// Screenshots only: every switch shown on, in memory. Nothing saved, registered or asked.
        func debugShowAllOn() {
            showInMenuBar = true
            launchAtLogin = true
            reminderOn = true
            lowDiskAlertOn = true
        }
    #endif

    private static func clamp(_ value: Int?, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
        guard let value else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
