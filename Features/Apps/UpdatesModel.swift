import AppKit
import Foundation
import Observation

/// Opens an update's "Open" target. Injected so tests don't launch anything.
protocol URLOpening: Sendable {
    @MainActor func open(_ url: URL)
}

struct WorkspaceURLOpener: URLOpening {
    @MainActor func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// State for the Apps screen's Updates tab. Checks run only when the tab opens (at most once an
/// hour on their own) or when the user asks again; nothing is downloaded or installed.
@Observable
@MainActor
final class UpdatesModel {
    /// Re-opening the tab within this time shows the last result instead of checking again.
    static let recheckAfter: TimeInterval = 60 * 60

    private(set) var report: UpdateReport?
    private(set) var isChecking = false
    private(set) var done = 0
    private(set) var total = 0
    var showUpToDate = false
    var showCantCheck = false

    private let checker: UpdateChecker
    private let opener: any URLOpening
    private let now: @Sendable () -> Date

    init(
        checker: UpdateChecker, opener: any URLOpening = WorkspaceURLOpener(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.checker = checker
        self.opener = opener
        self.now = now
    }

    // MARK: - Derived

    private func sorted(_ updates: [AppUpdate]) -> [AppUpdate] {
        updates.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    var outdated: [AppUpdate] { sorted(report?.updates.filter(\.isOutdated) ?? []) }

    var upToDate: [AppUpdate] { sorted(report?.updates.filter { $0.status == .upToDate } ?? []) }

    var cantCheck: [AppUpdate] {
        sorted(
            report?.updates.filter {
                if case .cantCheck = $0.status { return true }
                return false
            } ?? [])
    }

    var headline: String {
        guard let report else { return "" }
        let count = report.outdated.count
        if count == 0 { return upToDate.isEmpty ? "No updates found" : "Everything Dustpan can check is up to date" }
        return count == 1 ? "1 update available" : "\(count) updates available"
    }

    var summary: String {
        guard let report else { return "" }
        let checked = report.updates.count - cantCheck.count
        var parts = ["\(checked) of \(report.updates.count) apps checked"]
        if !cantCheck.isEmpty { parts.append("\(cantCheck.count) can't be checked") }
        return parts.joined(separator: " · ")
    }

    /// A quiet note when the check was partial.
    var notice: String? {
        guard let report else { return nil }
        if report.offline {
            return
                "Dustpan couldn't connect to the internet, so some apps weren't checked. Check again when you're online."
        }
        if report.caskListStale, let date = report.caskListDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return
                "Homebrew's app list couldn't be refreshed, so Dustpan used the copy from \(formatter.localizedString(for: date, relativeTo: now()))."
        }
        return nil
    }

    /// The notice's symbol: no connection, or an old Homebrew list.
    var noticeSymbol: String { report?.offline == true ? "wifi.slash" : "clock.arrow.circlepath" }

    // MARK: - Checking

    /// The tab opened: check unless a recent result is showing.
    func tabOpened(apps: [AppRecord]) async {
        if let report, now().timeIntervalSince(report.checkedAt) < Self.recheckAfter { return }
        await check(apps: apps)
    }

    func check(apps: [AppRecord]) async {
        guard !isChecking else { return }
        isChecking = true
        done = 0
        total = apps.count
        defer { isChecking = false }
        let candidates = apps.map { UpdateCandidate(name: $0.name, bundleID: $0.bundleID, url: $0.url) }
        let checker = checker
        report = await Task.detached(priority: .userInitiated) { [weak self] in
            await checker.check(candidates) { done, total in
                Task { @MainActor in
                    guard let self, self.isChecking, done > self.done else { return }
                    self.done = done
                    self.total = total
                }
            }
        }.value
    }

    var progress: Double { total == 0 ? 0 : Double(done) / Double(total) }

    // MARK: - Open

    /// Opens the App Store page, the app itself (its own updater) or the developer's page.
    func open(_ update: AppUpdate) {
        guard let target = update.open else { return }
        switch target {
        case .appStore(let url):
            guard ["macappstore", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            opener.open(url)
        case .web(let url):
            guard url.scheme?.lowercased() == "https" else { return }
            opener.open(url)
        case .app(let url):
            guard url.isFileURL, url.pathExtension.lowercased() == "app" else { return }
            opener.open(url)
        }
    }

    static func openTitle(_ target: UpdateOpenTarget?) -> String {
        switch target {
        case .appStore: "App Store"
        case .web: "Website"
        case .app, nil: "Open app"
        }
    }

    static func openSpoken(_ target: UpdateOpenTarget?, name: String) -> String {
        switch target {
        case .appStore: "Open \(name) in the App Store"
        case .web: "Open \(name)'s website"
        case .app, nil: "Open \(name) to update it"
        }
    }

    #if DEBUG
        /// DEBUG screenshots: show a made-up result without any network.
        func debugShow(_ report: UpdateReport) {
            self.report = report
        }

        /// DEBUG screenshots: the progress view (`total` 0 ends it).
        func debugShowChecking(done: Int, total: Int) {
            isChecking = total > 0
            self.done = done
            self.total = total
        }
    #endif
}
