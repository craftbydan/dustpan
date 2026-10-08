import Foundation
import Observation

/// State for the History screen: past cleanups from the `cleanupLog` table, grouped by day,
/// with "Put back" through the Cleaner.
@Observable
@MainActor
final class HistoryModel {
    struct Day: Identifiable, Equatable {
        let date: Date
        let entries: [HistoryEntry]
        var id: Date { date }
        /// Bytes still sitting in the Trash from this day.
        var bytesInTrash: Int64 { entries.filter { $0.status == .inTrash }.reduce(0) { $0 + $1.log.bytes } }
        var totalBytes: Int64 { entries.reduce(0) { $0 + $1.log.bytes } }
    }

    private(set) var days: [Day] = []
    private(set) var isLoaded = false
    private(set) var issue: DustpanError?
    /// Why the last "Put back" of a row failed, by log ID.
    private(set) var failures: [Int64: UndoFailure] = [:]
    private(set) var working: Set<Int64> = []

    private let cleaner: Cleaner
    /// Reports moves and put-backs to `AppState` (disk bar, Junk's Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }
    private let calendar: Calendar
    private let home: String

    init(
        cleaner: Cleaner, home: URL = FileManager.default.homeDirectoryForCurrentUser, calendar: Calendar = .current
    ) {
        self.cleaner = cleaner
        self.calendar = calendar
        self.home = home.path
    }

    /// The folder an item came from, with the home folder shown as `~`.
    func folder(of entry: HistoryEntry) -> String {
        let parent = URL(fileURLWithPath: entry.log.originalPath).deletingLastPathComponent().path
        return parent.hasPrefix(home + "/") || parent == home ? "~" + parent.dropFirst(home.count) : parent
    }

    var isEmpty: Bool { days.isEmpty }

    func load() async {
        do {
            let entries = try await cleaner.history()
            days = Self.group(entries, calendar: calendar)
            issue = nil
        } catch {
            issue = error as? DustpanError ?? .databaseUnavailable
        }
        isLoaded = true
    }

    /// Moves one logged item back to where it was.
    func putBack(_ entry: HistoryEntry) async {
        await putBack([entry])
    }

    /// Moves every item of a day that is still in the Trash back.
    func putBackAll(in day: Day) async {
        await putBack(day.entries.filter { $0.status == .inTrash })
    }

    private func putBack(_ entries: [HistoryEntry]) async {
        let ids = entries.compactMap(\.log.id)
        guard !ids.isEmpty else { return }
        working.formUnion(ids)
        defer { working.subtract(ids) }
        let report = await cleaner.undo(ids)
        for id in report.restored { failures[id] = nil }
        failures.merge(report.failed) { _, new in new }
        issue = report.failed.isEmpty ? nil : .putBackFailed(report.failed.count)
        if !report.restored.isEmpty { spaceChanged(.putBack) }
        await load()
    }

    func dismissIssue() { issue = nil }

    static func group(_ entries: [HistoryEntry], calendar: Calendar) -> [Day] {
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.log.date) }
        return byDay.keys.sorted(by: >).map { day in
            Day(date: day, entries: (byDay[day] ?? []).sorted { $0.log.date > $1.log.date })
        }
    }
}
