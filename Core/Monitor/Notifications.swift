import Foundation
import UserNotifications
import os

/// Whether Dustpan may post notifications. Reading it never shows a prompt.
enum NotificationPermission: Sendable, Equatable {
    case notDetermined, denied, allowed
}

/// The slice of `UNUserNotificationCenter` Dustpan uses, so tests run against a fake (and the
/// test host never asks for permission or schedules anything real).
protocol NotificationScheduling: Sendable {
    func permission() async -> NotificationPermission
    /// Shows macOS's permission prompt the first time. Only called when the user turns a
    /// reminder or the low-disk alert on in Settings.
    func requestPermission() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String]) async
}

struct SystemNotificationCenter: NotificationScheduling {
    func permission() async -> NotificationPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            Logger(subsystem: "app.dustpan", category: "reminders")
                .error("Notification permission failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePending(_ identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// The notifications Dustpan posts. Both open the Sweep when clicked.
enum DustpanNotification {
    static let weeklyID = "app.dustpan.reminder.weekly"
    static let lowDiskID = "app.dustpan.alert.lowDisk"
    static let weeklyBody = "It's been a week. Want to see what's piled up?"

    /// A repeating weekly reminder. `weekday` uses `Calendar`'s numbering (1 = Sunday … 7 = Saturday).
    static func weekly(weekday: Int, hour: Int, minute: Int) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = weeklyBody
        content.sound = nil
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        return UNNotificationRequest(identifier: weeklyID, content: content, trigger: trigger)
    }

    /// Posted straight away when free space drops under the user's threshold.
    static func lowDisk(availableBytes: Int64, thresholdBytes: Int64) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Your startup disk is getting full"
        content.body =
            "\(ByteFormat.string(availableBytes)) left, under the \(ByteFormat.string(thresholdBytes)) you set. "
            + "Dustpan can show you what's taking the space."
        return UNNotificationRequest(identifier: lowDiskID, content: content, trigger: nil)
    }

    /// Where a clicked notification leads. Every Dustpan notification opens the Sweep.
    static func section(for identifier: String) -> AppSection? {
        [weeklyID, lowDiskID].contains(identifier) ? .sweep : nil
    }
}

/// Posts the low-disk notification at most once per `minimumGap`, only when the user turned the
/// alert on and macOS allows Dustpan's notifications (it never asks from here).
actor LowDiskAlert {
    static let minimumGap: TimeInterval = 24 * 60 * 60

    private let settings: SettingsStore
    private let notifications: any NotificationScheduling
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.dustpan", category: "reminders")

    init(
        settings: SettingsStore, notifications: any NotificationScheduling,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.notifications = notifications
        self.now = now
    }

    /// Returns true when it posted.
    @discardableResult
    func check(availableBytes: Int64) async -> Bool {
        guard await settings.bool(.lowDiskEnabled) else { return false }
        let threshold = await SettingsModel.thresholdBytes(gigabytes: settings.int(.lowDiskThresholdGB))
        guard availableBytes < threshold else { return false }
        let current = now()
        if let last = await settings.date(.lowDiskLastAlert), current.timeIntervalSince(last) < Self.minimumGap {
            return false
        }
        guard await notifications.permission() == .allowed else { return false }
        do {
            try await notifications.add(
                DustpanNotification.lowDisk(availableBytes: availableBytes, thresholdBytes: threshold))
            await settings.set(current, for: .lowDiskLastAlert)
            return true
        } catch {
            logger.error("Low-disk alert failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
