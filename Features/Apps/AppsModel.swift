import AppKit
import Foundation
import Observation
import os

/// State for the Apps screen: installed apps (with their leftovers and Uninstall) and leftovers
/// of apps that are already gone.
///
/// Listing runs in `AppScanner`, matching in `LeftoverMatcher` (off the main actor), moving in
/// `Cleaner`. The only file-system read here is the app icon (`NSWorkspace.icon(forFile:)`), drawn off
/// the main actor.
@Observable
@MainActor
final class AppsModel {
    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case installed, leftovers, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: "Installed"
            case .leftovers: "Leftovers of deleted apps"
            case .updates: "Updates"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case size, name, lastUsed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .size: "Size"
            case .name: "Name"
            case .lastUsed: "Last used"
            }
        }
    }

    /// What the result view is about.
    enum ResultKind: Equatable {
        case uninstall(String)
        case orphans
        /// Leftovers of an app the user removed in Finder.
        case removedAppLeftovers(String)
    }

    /// "Microsoft Teams is gone. Remove its 14 leftovers?" after the user removed an app that's
    /// installed for all users in Finder.
    struct GonePrompt: Equatable {
        let app: AppRecord
        let scan: LeftoverScan
    }

    static let undoWindow: TimeInterval = 30

    var tab: Tab = .installed
    var sort: Sort = .size
    var searchText = ""

    private(set) var apps: [AppRecord] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var selectedAppID: String?

    /// Leftovers of the selected app.
    private(set) var leftovers: LeftoverScan?
    private(set) var isLoadingLeftovers = false
    private(set) var leftoverSelection: Set<String> = []

    private(set) var orphans: LeftoverScan?
    private(set) var isLoadingOrphans = false
    private(set) var orphanSelection: Set<String> = []

    var isConfirmingUninstall = false
    var isConfirmingOrphans = false
    /// "Quit <name> first?" is showing.
    var quitPromptName: String?
    private(set) var isWorking = false

    /// An app installed for all users that the user is removing in Finder ("Show in Finder"):
    /// watched until its bundle disappears.
    private(set) var finderRemovalApp: AppRecord?
    private(set) var gone: GonePrompt?
    private(set) var goneSelection: Set<String> = []
    /// The app the last uninstall was about (for "Show in Finder" on the result).
    private(set) var lastUninstallApp: AppRecord?

    private(set) var lastReport: UninstallReport?
    private(set) var resultKind: ResultKind?
    private(set) var undoDeadline: Date?
    private(set) var issue: DustpanError?

    private let scanner: AppScanner
    private let cleaner: Cleaner
    /// Reports moves and put-backs to `AppState` (disk bar, Junk's Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }
    private let home: URL
    private let systemLibrary: URL
    private let runningApps: any RunningAppsChecking
    private let quitter: any AppQuitting
    private let isKnownApp: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    /// Shows a file selected in Finder (`NSWorkspace.activateFileViewerSelecting`); tests pass a fake.
    private let reveal: @MainActor (URL) -> Void
    /// The running Dustpan's bundle ID; tests pass their own.
    private let ownBundleID: String?
    private var hasFullDiskAccess = true
    private var leftoverGeneration = 0
    /// App icons, drawn off the main actor (reading one opens the app bundle). Observed, so a
    /// row shows its icon as soon as it's ready.
    private(set) var icons: [String: NSImage] = [:]
    @ObservationIgnored private var iconRequests: Set<String> = []
    private let logger = Logger(subsystem: "app.dustpan", category: "apps")

    init(
        scanner: AppScanner, cleaner: Cleaner, home: URL,
        systemLibrary: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
        runningApps: any RunningAppsChecking = WorkspaceRunningApps(),
        quitter: any AppQuitting = WorkspaceAppQuitter(),
        isKnownApp: @escaping @Sendable (String) -> Bool = { LaunchServicesApps.isKnown($0) },
        now: @escaping @Sendable () -> Date = { Date() },
        reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.reveal = reveal
        self.ownBundleID = ownBundleID
        self.scanner = scanner
        self.cleaner = cleaner
        self.home = home
        self.systemLibrary = systemLibrary
        self.runningApps = runningApps
        self.quitter = quitter
        self.isKnownApp = isKnownApp
        self.now = now
    }

    // MARK: - Derived

    var selectedApp: AppRecord? { apps.first { $0.id == selectedAppID } }

    /// Apps matching the search, sorted.
    var visibleApps: [AppRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered =
            query.isEmpty
            ? apps : apps.filter { $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query) }
        switch sort {
        case .size: return filtered.sorted { $0.size > $1.size }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            // Longest unused first; never-recorded at the end.
            return filtered.sorted { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        }
    }

    var totalAppBytes: Int64 { apps.reduce(0) { $0 + $1.size } }
    var unusedCount: Int { apps.filter { $0.isUnused(now: now()) }.count }
    /// Size of the unused apps; the Sweep's Unused apps tile shows the same figure.
    var unusedBytes: Int64 { AppRecord.unusedBytes(apps, now: now()) }

    func isUnused(_ app: AppRecord) -> Bool { app.isUnused(now: now()) }

    /// Dustpan itself (this copy or another with its ID). It can't remove itself: asking it to quit
    /// first would only close Dustpan. Text only; the Cleaner refuses it too.
    func isDustpan(_ app: AppRecord) -> Bool {
        if let ownBundleID, app.bundleID.caseInsensitiveCompare(ownBundleID) == .orderedSame { return true }
        return app.url.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path
    }

    var selectedLeftovers: [LeftoverMatch] {
        (leftovers?.matches ?? []).filter { leftoverSelection.contains($0.id) && $0.isRemovable }
    }

    var leftoverBytes: Int64 { (leftovers?.matches ?? []).reduce(0) { $0 + $1.size } }

    /// The app plus the ticked leftovers.
    var uninstallBytes: Int64 { (selectedApp?.size ?? 0) + selectedLeftovers.reduce(0) { $0 + $1.size } }

    var selectedOrphans: [LeftoverMatch] {
        (orphans?.matches ?? []).filter { orphanSelection.contains($0.id) && $0.isRemovable }
    }

    var selectedOrphanBytes: Int64 { selectedOrphans.reduce(0) { $0 + $1.size } }

    /// The path with the home folder shown as `~`.
    func displayPath(_ url: URL) -> String {
        let homePath = home.path
        let path = url.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// The app's icon once `loadIcon(for:)` has drawn it; nil until then.
    func icon(for app: AppRecord) -> NSImage? { icons[app.id] }

    /// Fetches the app's icon through `NSWorkspace` and draws it off the main actor, once.
    func loadIcon(for app: AppRecord) async {
        guard icons[app.id] == nil, iconRequests.insert(app.id).inserted else { return }
        let side = Self.iconPixels
        guard let image = await Self.renderIcon(path: app.url.path, pixels: side) else { return }
        icons[app.id] = NSImage(cgImage: image, size: NSSize(width: side / 2, height: side / 2))
    }

    /// Big enough for the detail header at 2×.
    static let iconPixels = 128

    @concurrent
    static func renderIcon(path: String, pixels: Int) async -> CGImage? {
        assertNotMainThread()
        let image = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Loading

    /// Lists installed apps. Keeps the selection if that app is still there.
    func load(hasFullDiskAccess: Bool) async {
        guard !isLoading else { return }
        self.hasFullDiskAccess = hasFullDiskAccess
        isLoading = true
        defer { isLoading = false }
        apps = await scanner.installedApps()
        hasLoaded = true
        if let id = selectedAppID, apps.contains(where: { $0.id == id }) {
            await loadLeftovers()
        } else {
            selectedAppID = nil
            leftovers = nil
        }
    }

    func select(_ app: AppRecord?) async {
        guard app?.id != selectedAppID else { return }
        selectedAppID = app?.id
        leftovers = nil
        leftoverSelection = []
        await loadLeftovers()
    }

    private func makeMatcher() -> LeftoverMatcher {
        LeftoverMatcher(home: home, systemLibrary: systemLibrary, hasFullDiskAccess: hasFullDiskAccess, now: now())
    }

    private func loadLeftovers() async {
        guard let app = selectedApp else { return }
        leftoverGeneration += 1
        let generation = leftoverGeneration
        isLoadingLeftovers = true
        let matcher = makeMatcher()
        let installed = apps.map(\.identity)
        let identity = app.identity
        let scan = await Task.detached(priority: .userInitiated) {
            matcher.leftovers(for: identity, installed: installed)
        }.value
        guard generation == leftoverGeneration else { return }
        isLoadingLeftovers = false
        leftovers = scan
        leftoverSelection = Set(scan.matches.filter(\.isSelectedByDefault).map(\.id))
    }

    /// Looks for leftovers of apps that are gone.
    func loadOrphans(hasFullDiskAccess: Bool) async {
        guard !isLoadingOrphans else { return }
        self.hasFullDiskAccess = hasFullDiskAccess
        isLoadingOrphans = true
        defer { isLoadingOrphans = false }
        let scan = await LeftoverMatcher.findOrphans(
            scanner: scanner, matcher: makeMatcher(), isKnownApp: isKnownApp)
        showOrphans(scan)
    }

    private func showOrphans(_ scan: LeftoverScan) {
        orphans = scan
        // Orphans are guesses: none starts ticked.
        orphanSelection = []
    }

    /// Whether the screen is free to take a Sweep's results.
    var canAdopt: Bool {
        !isLoading && !isLoadingOrphans && !isWorking && lastReport == nil && !isConfirmingUninstall
            && !isConfirmingOrphans && quitPromptName == nil && gone == nil
    }

    /// Shows the apps a Sweep listed, so the screen doesn't look again.
    func adopt(apps records: [AppRecord], hasFullDiskAccess: Bool) async {
        self.hasFullDiskAccess = hasFullDiskAccess
        apps = records
        hasLoaded = true
        if let id = selectedAppID, apps.contains(where: { $0.id == id }) {
            await loadLeftovers()
        } else {
            selectedAppID = nil
            leftovers = nil
        }
    }

    /// Shows the leftovers of deleted apps a Sweep found.
    func adopt(orphans scan: LeftoverScan, hasFullDiskAccess: Bool) {
        self.hasFullDiskAccess = hasFullDiskAccess
        showOrphans(scan)
    }

    // MARK: - Selection

    func isLeftoverSelected(_ match: LeftoverMatch) -> Bool { leftoverSelection.contains(match.id) }

    func setLeftover(_ match: LeftoverMatch, selected: Bool) {
        guard match.isRemovable else { return }
        if selected { leftoverSelection.insert(match.id) } else { leftoverSelection.remove(match.id) }
    }

    func isOrphanSelected(_ match: LeftoverMatch) -> Bool { orphanSelection.contains(match.id) }

    func setOrphan(_ match: LeftoverMatch, selected: Bool) {
        guard match.isRemovable else { return }
        if selected { orphanSelection.insert(match.id) } else { orphanSelection.remove(match.id) }
    }

    // MARK: - Uninstall

    /// Asks to quit the app first if it's open; otherwise shows the confirmation. Apps installed for
    /// all users are removed in Finder instead (`showInFinder`).
    func requestUninstall() {
        guard let app = selectedApp, !isWorking, !app.needsAdminToRemove, !isDustpan(app) else { return }
        if let name = runningApps.runningAppName(bundleID: app.bundleID) {
            quitPromptName = name
        } else {
            isConfirmingUninstall = true
        }
    }

    /// The user agreed to quit the app: ask it politely, then confirm the uninstall.
    func confirmQuit() async {
        guard let name = quitPromptName, let app = selectedApp else { return }
        quitPromptName = nil
        if await quitter.quit(bundleID: app.bundleID) {
            isConfirmingUninstall = true
        } else {
            issue = .appDidNotQuit(name)
        }
    }

    func confirmUninstall() async {
        isConfirmingUninstall = false
        guard let app = selectedApp, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let report = await cleaner.uninstall(app: app, leftovers: selectedLeftovers)
        if report.logFailed { issue = .cleanupNotLogged }
        if report.appRemoved {
            apps.removeAll { $0.id == app.id }
            selectedAppID = nil
            leftovers = nil
            leftoverSelection = []
        }
        lastUninstallApp = app
        show(report, kind: .uninstall(app.name))
        if !report.moved.isEmpty { spaceChanged(.movedToTrash) }
    }

    // MARK: - Apps installed for all users

    /// Shows the app in Finder so the user can drag it to the Trash (Finder asks for the
    /// password), and starts watching for it to disappear. No admin prompt or helper here.
    func showInFinder(_ app: AppRecord) {
        finderRemovalApp = app
        reveal(app.url)
    }

    /// Cheap re-check (one `lstat` per app, off the main actor) for apps that disappeared: the
    /// one being removed in Finder, and the selected one. Called when Dustpan becomes active,
    /// when an app quits, and when the detail shows. Never on a timer.
    func checkForRemovedApps() async {
        let watched = finderRemovalApp
        let selected = selectedApp
        let paths = [watched?.url.path, selected?.url.path].compactMap { $0 }
        guard !paths.isEmpty, !isWorking, !isLoading else { return }
        let missing = await Task.detached(priority: .utility) {
            Set(paths.filter { Cleaner.linkState($0) == .missing })
        }.value
        guard !missing.isEmpty else { return }
        await load(hasFullDiskAccess: hasFullDiskAccess)
        guard let app = watched, missing.contains(app.url.path) else { return }
        finderRemovalApp = nil
        let matcher = makeMatcher()
        let installed = apps.map(\.identity)
        let identity = app.identity
        let scan = await Task.detached(priority: .userInitiated) {
            matcher.leftovers(for: identity, installed: installed)
        }.value
        gone = GonePrompt(app: app, scan: scan)
        goneSelection = Set(scan.matches.filter(\.isSelectedByDefault).map(\.id))
    }

    var selectedGoneLeftovers: [LeftoverMatch] {
        (gone?.scan.matches ?? []).filter { goneSelection.contains($0.id) && $0.isRemovable }
    }

    func isGoneSelected(_ match: LeftoverMatch) -> Bool { goneSelection.contains(match.id) }

    func setGone(_ match: LeftoverMatch, selected: Bool) {
        guard match.isRemovable else { return }
        if selected { goneSelection.insert(match.id) } else { goneSelection.remove(match.id) }
    }

    func dismissGone() {
        gone = nil
        goneSelection = []
    }

    /// Moves the ticked leftovers of the removed app through the Cleaner's strict path.
    func confirmGoneLeftovers() async {
        guard let prompt = gone, !isWorking else { return }
        let chosen = selectedGoneLeftovers
        dismissGone()
        guard !chosen.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        let report = await cleaner.removeLeftovers(ofRemovedApp: prompt.app.identity, leftovers: chosen)
        if report.logFailed { issue = .cleanupNotLogged }
        orphans = nil
        lastUninstallApp = nil
        show(report, kind: .removedAppLeftovers(prompt.app.name))
        if !report.moved.isEmpty { spaceChanged(.movedToTrash) }
    }

    // MARK: - Orphans

    func requestRemoveOrphans() {
        guard !selectedOrphans.isEmpty, !isWorking else { return }
        isConfirmingOrphans = true
    }

    func confirmRemoveOrphans() async {
        isConfirmingOrphans = false
        let chosen = selectedOrphans
        guard !chosen.isEmpty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let report = await cleaner.removeOrphans(chosen)
        if report.logFailed { issue = .cleanupNotLogged }
        let moved = Set(report.moved.map { $0.original.path })
        orphans?.matches.removeAll { moved.contains($0.url.path) }
        orphanSelection.subtract(moved)
        show(report, kind: .orphans)
        if !report.moved.isEmpty { spaceChanged(.movedToTrash) }
    }

    // MARK: - Result & undo

    private func show(_ report: UninstallReport, kind: ResultKind) {
        lastReport = report
        resultKind = kind
        undoDeadline = report.logIDs.isEmpty ? nil : Date().addingTimeInterval(Self.undoWindow)
    }

    /// Puts back everything the last uninstall moved, then looks again.
    func undoLast() async {
        guard let report = lastReport, !report.logIDs.isEmpty else { return }
        let kind = resultKind
        undoDeadline = nil
        let undo = await cleaner.undo(report.logIDs)
        lastReport = nil
        resultKind = nil
        if !undo.failed.isEmpty { issue = .putBackFailed(undo.failed.count) }
        if !undo.restored.isEmpty { spaceChanged(.putBack) }
        if case .uninstall? = kind {
            await load(hasFullDiskAccess: hasFullDiskAccess)
        } else {
            await loadOrphans(hasFullDiskAccess: hasFullDiskAccess)
        }
    }

    func dismissResult() {
        lastReport = nil
        resultKind = nil
        undoDeadline = nil
    }

    func dismissIssue() { issue = nil }

    #if DEBUG
        /// DEBUG screenshots: select an app by bundle ID.
        func debugSelect(bundleID: String) async {
            await select(apps.first { $0.bundleID == bundleID })
        }

        /// DEBUG screenshots: an uninstall attempt even for an app installed for all users, to show
        /// the grouped result (the Cleaner refuses the move and keeps the leftovers).
        func debugForceUninstall() async {
            guard let app = selectedApp else { return }
            isWorking = true
            let report = await cleaner.uninstall(app: app, leftovers: selectedLeftovers)
            isWorking = false
            lastUninstallApp = app
            show(report, kind: .uninstall(app.name))
        }

        /// DEBUG screenshots: watch an app as if "Show in Finder" was clicked, without opening Finder.
        func debugWatchForRemoval(_ app: AppRecord) { finderRemovalApp = app }

        /// DEBUG screenshots: tick one orphan, so the bottom bar shows a size.
        func debugSelectFirstOrphan() {
            if let first = orphans?.matches.first(where: \.isRemovable) { setOrphan(first, selected: true) }
        }
    #endif
}
