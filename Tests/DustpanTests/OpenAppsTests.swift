import Foundation
import Testing
import os

@testable import Dustpan

/// Pretend open apps that tests open and close. "Quitting" only flips the pretend state (or
/// refuses); no real app is ever asked to quit.
final class MutableRunningApps: RunningAppsChecking, AppQuitting, Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (open: [String: String](), refuses: Set<String>(), asked: [String]()))

    init(open: [String: String] = [:]) { state.withLock { $0.open = open } }

    func runningAppName(bundleID: String) -> String? { state.withLock { $0.open[bundleID] } }
    func setOpen(_ bundleID: String, _ name: String?) { state.withLock { $0.open[bundleID] = name } }
    func refuseQuit(_ bundleID: String) { _ = state.withLock { $0.refuses.insert(bundleID) } }
    var asked: [String] { state.withLock { $0.asked } }

    @MainActor func quit(bundleID: String) async -> Bool {
        state.withLock { s in
            s.asked.append(bundleID)
            if s.refuses.contains(bundleID) { return false }
            s.open[bundleID] = nil
            return true
        }
    }
}

/// The Junk list's risk filter and select-all, and the open-app warnings on the Junk and Sweep
/// screens. Synthetic scan results or a fixture home; a temp Trash; pretend running apps.
@Suite("Risk filter and open apps")
@MainActor
struct OpenAppsTests {
    nonisolated static let chrome = "com.google.Chrome"
    nonisolated static let chromeApp = BlockingApp(bundleID: chrome, name: "Google Chrome")

    /// A Junk model on synthetic results: no file is ever read or moved.
    struct Synthetic {
        let model: JunkModel
        let running: MutableRunningApps
        let apps: RunningApps
        let a, young, review, detection, chromeCache, log: ScanItem

        @MainActor
        init(chromeOpen: Bool, chromeSelected: Bool = true) {
            running = MutableRunningApps(open: chromeOpen ? [OpenAppsTests.chrome: "Google Chrome"] : [:])
            apps = RunningApps(checker: running, quitter: running, observeWorkspace: false)
            let home = URL(fileURLWithPath: "/nonexistent-dustpan-test-home", isDirectory: true)
            let cleaner = Cleaner(
                home: home, trashMover: TempTrashMover(trashDirectory: home.appendingPathComponent("trash")),
                runningApps: running, store: CleanupStore(database: nil), rules: { [] })
            model = JunkModel(
                catalog: RuleCatalog(), cleaner: cleaner, store: CleanupStore(database: nil), home: home,
                runningApps: apps)
            func item(
                _ name: String, _ rule: String, _ risk: Risk, selected: Bool, category: JunkCategory = .userCache,
                detection: Bool = false, bytes: Int64 = 1_000
            ) -> ScanItem {
                ScanItem(
                    id: UUID(), url: home.appendingPathComponent("Library/Caches/\(name)"), allocatedSize: bytes,
                    modified: Date().addingTimeInterval(-30 * 86_400), category: category, ruleID: rule, risk: risk,
                    isSelected: selected, detectionOnly: detection)
            }
            a = item("com.example.app", "cache.apps", .safe, selected: true)
            young = item("com.example.young", "cache.apps", .safe, selected: false)
            review = item("zzreview", "cache.xdg", .review, selected: false)
            detection = item("docker", "dev.docker.cache", .safe, selected: false, detection: true)
            chromeCache = item("com.google.Chrome", "cache.chrome", .safe, selected: chromeSelected, bytes: 415_000)
            log = item("sync.log", "logs.user", .safe, selected: false, category: .logs)
            func rule(_ id: String, _ risk: Risk, app: String? = nil, quit: Bool = false) -> Rule {
                Rule(
                    id: id, title: id, category: .userCache, paths: ["~/Library/Caches"], risk: risk, why: "Test.",
                    appBundleID: app, requiresQuit: quit)
            }
            let rules = [
                rule("cache.apps", .safe), rule("cache.xdg", .review), rule("dev.docker.cache", .safe),
                rule("cache.chrome", .safe, app: OpenAppsTests.chrome, quit: true), rule("logs.user", .safe),
            ]
            let caches = [a, young, review, detection, chromeCache]
            model.adopt(
                JunkScanOutput(
                    results: [
                        ScanResult(
                            category: .userCache, items: caches, totalBytes: caches.reduce(0) { $0 + $1.allocatedSize },
                            duration: 0),
                        ScanResult(category: .logs, items: [log], totalBytes: log.allocatedSize, duration: 0),
                    ],
                    rulesByID: Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })))
            model.focusedCategory = .userCache
        }
    }

    @Test("Risk filter narrows the list; select-all acts on the visible rows and follows the filter")
    func filterAndSelectAll() {
        let s = Synthetic(chromeOpen: true)
        let model = s.model
        #expect(model.selection == [s.a.id])  // Chrome's cache isn't pre-selected while Chrome is open

        model.riskFilter = .safe
        #expect(model.riskFilter.selectAllTitle == "Select all safe")
        #expect(Set(model.visibleItems.map(\.id)) == [s.a.id, s.young.id, s.detection.id, s.chromeCache.id])
        model.setAllVisibleSelected(true)
        // Young safe items are included (the user's own choice); detection-only and Chrome aren't.
        #expect(model.selection == [s.a.id, s.young.id])
        #expect(model.skippedForOpenApps == 1)
        #expect(model.skippedNote == "1 skipped — its app is open")
        #expect(!model.selection.contains(s.review.id))

        model.riskFilter = .review
        #expect(model.riskFilter.selectAllTitle == "Select all to review")
        #expect(model.visibleItems.map(\.id) == [s.review.id])
        model.setAllVisibleSelected(true)
        #expect(model.selection == [s.a.id, s.young.id, s.review.id])
        model.setAllVisibleSelected(false)
        #expect(model.selection == [s.a.id, s.young.id])

        model.riskFilter = .all
        model.searchText = "young"
        #expect(model.visibleItems.map(\.id) == [s.young.id])
        // The tile and bottom bar count the real selection, whatever the filter shows.
        #expect(model.selectedCount(in: .userCache) == 2)
        #expect(model.selectedBytes == s.a.allocatedSize + s.young.allocatedSize)
    }

    @Test("Select all safe ticks safe items in every category, skipping detection-only, Review and open apps")
    func selectAllSafeEverywhere() {
        let s = Synthetic(chromeOpen: true)
        let model = s.model
        model.selectAllSafe()
        #expect(model.selection == [s.a.id, s.young.id, s.log.id])
        #expect(model.skippedForOpenApps == 1 && model.skippedScope == .everywhere)
        #expect(!model.canSelectAllSafe)
    }

    @Test("A row whose app is open can't be ticked, by click, keyboard or select-all")
    func blockedRowCantBeSelected() {
        let s = Synthetic(chromeOpen: true)
        let model = s.model
        #expect(model.blocker(for: s.chromeCache) == Self.chromeApp)
        #expect(!model.isSelectable(s.chromeCache))
        #expect(model.blockedCount(in: .userCache) == 1)
        model.setSelected(s.chromeCache, true)
        #expect(!model.isSelected(s.chromeCache))
        model.focusedItemID = s.chromeCache.id
        model.toggleFocused()
        #expect(!model.isSelected(s.chromeCache))
    }

    @Test("An app opening unticks its items and says so quietly")
    func launchingUnticks() {
        let s = Synthetic(chromeOpen: false)
        let model = s.model
        #expect(model.isSelected(s.chromeCache) && model.isSelected(s.a))
        s.running.setOpen(Self.chrome, "Google Chrome")
        s.apps.appChanged(bundleID: Self.chrome)  // what the NSWorkspace launch notification does
        #expect(!model.isSelected(s.chromeCache))
        #expect(model.isSelected(s.a))
        #expect(model.unticked?.contains("Google Chrome") == true)
        model.dismissUnticked()
        #expect(model.unticked == nil)
    }

    @Test("Quitting (pretend) asks once, unblocks the rows and ticks nothing; a refusal is a quiet note")
    func quittingUnblocks() async {
        let s = Synthetic(chromeOpen: true)
        let model = s.model
        model.requestQuit(Self.chromeApp)
        #expect(model.quitPrompt == Self.chromeApp)
        #expect(s.running.asked.isEmpty)  // nothing happens before the confirmation
        await model.confirmQuit()
        #expect(s.running.asked == [Self.chrome])
        #expect(model.isSelectable(s.chromeCache))
        #expect(!model.isSelected(s.chromeCache))
        #expect(model.issue == nil)

        let refused = Synthetic(chromeOpen: true)
        refused.running.refuseQuit(Self.chrome)
        refused.model.requestQuit(Self.chromeApp)
        await refused.model.confirmQuit()
        #expect(refused.model.issue == .appDidNotQuit("Google Chrome"))
        #expect(!refused.model.isSelectable(refused.chromeCache))
    }

    @Test("The confirmation lists ticked items whose app is open, with Quit and Leave")
    func confirmListsBlocked() async {
        let s = Synthetic(chromeOpen: false)
        let model = s.model
        // Chrome opens but the notification hasn't arrived yet.
        s.running.setOpen(Self.chrome, "Google Chrome")
        model.requestClean()
        #expect(model.isConfirming)
        #expect(model.blockedGroups == [BlockedGroup(app: Self.chromeApp, count: 1, bytes: 415_000)])
        #expect(model.isSelected(s.chromeCache))  // listed, not silently unticked
        #expect(model.movableSelection.map(\.id) == [s.a.id])
        #expect(model.movableBytes == s.a.allocatedSize)
        #expect(model.summary.map(\.count) == [1])

        await model.quitBlockedApps()
        #expect(model.blockedGroups.isEmpty)
        #expect(model.isSelected(s.chromeCache))
        #expect(Set(model.movableSelection.map(\.id)) == [s.a.id, s.chromeCache.id])

        let leave = Synthetic(chromeOpen: false)
        leave.running.setOpen(Self.chrome, "Google Chrome")
        leave.model.requestClean()
        leave.model.leaveBlocked()
        #expect(leave.model.isConfirming)
        #expect(leave.model.selection == [leave.a.id])

        let failing = Synthetic(chromeOpen: false)
        failing.running.setOpen(Self.chrome, "Google Chrome")
        failing.running.refuseQuit(Self.chrome)
        failing.model.requestClean()
        await failing.model.quitBlockedApps()
        #expect(failing.model.stillOpen == ["Google Chrome"])
        #expect(failing.model.blockedGroups.count == 1)
    }

    // MARK: - Fixture home

    /// The whole app on a fixture home with pretend open apps.
    static func appState(_ h: SweepHarness, running: MutableRunningApps) async -> AppState {
        let state = AppState(
            database: h.database, permissions: FakePermissions(flag: AccessFlag(granted: true)), home: h.fixture.url,
            trashMover: TempTrashMover(trashDirectory: h.trash), runningApps: running, appRoots: [h.apps],
            systemLibrary: h.systemLibrary, signing: FakeSigning(), lastUsed: FakeLastUsed(), quitter: running)
        await state.onboarding.load(allowPresentation: false)
        return state
    }

    @Test("Sweep: Clean recommended leaves out an open app's cache up front; its tile still equals Junk's")
    func sweepLeavesOutOpenApps() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000)
        let chromeBytes = try h.fixture.file("Library/Caches/com.google.Chrome/Default/Cache/data_0", bytes: 40_000)
        let running = MutableRunningApps(open: [Self.chrome: "Google Chrome"])
        let state = await Self.appState(h, running: running)
        let sweep = state.sweep
        await sweep.sweep()

        #expect(Set(sweep.recommendedItems.map(\.url.lastPathComponent)) == ["com.example.app"])
        let leftOut = try #require(sweep.leftOut.first)
        #expect(sweep.leftOut.count == 1)
        #expect(leftOut.app == Self.chromeApp && leftOut.bytes >= chromeBytes)
        // The tile counts everything found, the same as the Junk screen (Chrome's cache included).
        #expect(sweep.bytes(.junk) == state.junk.totalBytes)
        #expect(state.junk.allItems.contains { $0.url.lastPathComponent == "com.google.Chrome" })
        #expect(state.junk.blockedCount(in: .userCache) == 1)

        // Cleaning now never even tries Chrome's cache: no "stayed where it was" for it.
        sweep.requestClean()
        await sweep.confirmClean()
        let report = try #require(sweep.lastReport)
        #expect(report.moved.map(\.original.lastPathComponent) == ["com.example.app"])
        #expect(report.skipped.isEmpty)
        #expect(h.exists("Library/Caches/com.google.Chrome/Default/Cache/data_0"))
        sweep.dismissResult()

        // Quit Chrome (pretend) from the left-out line: its cache rejoins the recommended set.
        sweep.requestQuit(leftOut.app)
        await sweep.confirmQuit()
        #expect(running.asked == [Self.chrome])
        #expect(sweep.leftOut.isEmpty)
        #expect(sweep.recommendedItems.map(\.url.lastPathComponent) == ["com.google.Chrome"])
        #expect(state.junk.blockedCount(in: .userCache) == 0)
    }

    @Test("Backstop: the Cleaner still refuses a requiresQuit item whose app is open")
    func cleanerBackstop() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.google.Chrome/Default/Cache/data_0", bytes: 20_000)
        let running = MutableRunningApps()
        let state = await Self.appState(h, running: running)
        let junk = state.junk
        await junk.scan(hasFullDiskAccess: true)
        let item = try #require(junk.allItems.first { $0.url.lastPathComponent == "com.google.Chrome" })
        #expect(junk.isSelected(item))

        // Chrome opens and the screen hasn't heard yet (no notification, no refresh).
        running.setOpen(Self.chrome, "Google Chrome")
        await junk.confirmClean()
        let report = try #require(junk.lastReport)
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.appRunning("Google Chrome")])
        #expect(h.exists("Library/Caches/com.google.Chrome/Default/Cache/data_0"))
    }
}
