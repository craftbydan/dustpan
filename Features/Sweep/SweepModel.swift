import Foundation
import Observation
import os

/// State for the Sweep screen: one scan of everything, five tiles, and "Clean recommended".
///
/// Scanning runs in `ScanCoordinator` and cleaning in `Cleaner` (both actors, off the main actor).
/// "Clean recommended" only ever hands the Cleaner junk items that are `.safe` and pre-selected:
/// apps, leftovers, duplicates, large files and `.review` items are never part of it. Items whose
/// app is open (`requiresQuit`) are left out up front and named on screen, with a way to quit it.
@Observable
@MainActor
final class SweepModel {
    enum Phase: Equatable, Sendable {
        case idle, scanning, results
    }

    /// What the Sweep hands the feature screens when it finishes, so they don't look again.
    struct Handoff {
        var finished: (SweepOutcome, _ hasFullDiskAccess: Bool) async -> Void = { _, _ in }
        /// Junk items the Sweep moved to the Trash.
        var cleaned: (Set<UUID>) -> Void = { _ in }
    }

    static let undoWindow: TimeInterval = 30

    private(set) var phase: Phase = .idle
    private(set) var states: [SweepModule: SweepModuleState] = [:]
    private(set) var findings: [SweepModule: SweepFinding] = [:]
    private(set) var seconds: [SweepModule: TimeInterval] = [:]
    /// The last Sweep was stopped (shown once on the idle screen).
    private(set) var wasCancelled = false
    private(set) var lastSwept: Date?
    /// A non-fatal problem, shown as a quiet banner.
    private(set) var issue: DustpanError?

    /// The "Clean recommended" confirmation is showing.
    var isConfirming = false
    private(set) var isCleaning = false
    /// The celebration after "Clean recommended" (nil = tiles).
    private(set) var lastReport: CleanReport?
    private(set) var undoDeadline: Date?
    /// "Quit Chrome?" is showing (from the "left out" line).
    var quitPrompt: BlockingApp?

    private let coordinator: ScanCoordinator
    private let cleaner: Cleaner
    private let settings: SettingsStore
    private let hasFullDiskAccess: () -> Bool
    private let now: () -> Date
    /// Which apps junk waits on are open (shared with the Junk screen through `AppState`).
    let runningApps: RunningApps
    var handoff = Handoff()
    /// Reports moves and put-backs to `AppState` (disk bar, Junk's Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }
    private var sweepTask: Task<Void, Never>?
    /// Bumped by every `start()`, so a Junk-only re-scan (after Undo) can tell it's been overtaken.
    private var sweepGeneration = 0
    private var lastAccess = true
    private let logger = Logger(subsystem: "app.dustpan", category: "sweep")

    init(
        coordinator: ScanCoordinator, cleaner: Cleaner, settings: SettingsStore,
        hasFullDiskAccess: @escaping () -> Bool, now: @escaping () -> Date = { Date() },
        runningApps: RunningApps = .idle()
    ) {
        self.runningApps = runningApps
        self.coordinator = coordinator
        self.cleaner = cleaner
        self.settings = settings
        self.hasFullDiskAccess = hasFullDiskAccess
        self.now = now
    }

    // MARK: - Derived

    var modules: [SweepModule] { SweepModule.allCases }
    var isScanning: Bool { phase == .scanning }

    func state(_ module: SweepModule) -> SweepModuleState { states[module] ?? .waiting }

    /// The tile's figure: the same computation its feature screen uses.
    func bytes(_ module: SweepModule) -> Int64 { findings[module]?.bytes(now: now()) ?? 0 }

    func count(_ module: SweepModule) -> Int { findings[module]?.count(now: now()) ?? 0 }

    /// 0…1 for the progress blob: finished modules plus the running ones' own progress.
    var overallProgress: Double {
        let parts = modules.map { module -> Double in
            switch state(module) {
            case .waiting: 0
            case .running(let fraction): min(max(fraction ?? 0, 0), 0.95)
            case .finished, .needsAccess, .failed, .cancelled: 1
            }
        }
        return parts.reduce(0, +) / Double(max(parts.count, 1))
    }

    var junk: JunkScanOutput? {
        if case .junk(let output) = findings[.junk] { return output }
        return nil
    }

    /// Everything "Clean recommended" may move: junk only, `.safe`, pre-selected, not
    /// detection-only (`JunkScanOutput.recommendedItems`), and not waiting on an open app.
    var recommendedItems: [ScanItem] {
        guard let junk else { return [] }
        return junk.recommendedItems.filter { runningApps.blocker(for: $0, rules: junk.rulesByID) == nil }
    }

    /// Recommended items left out because their app is open, one line per app.
    var leftOut: [BlockedGroup] {
        guard let junk else { return [] }
        return BlockedGroup.groups(junk.recommendedItems) { runningApps.blocker(for: $0, rules: junk.rulesByID) }
    }
    var recommendedBytes: Int64 { recommendedItems.reduce(0) { $0 + $1.allocatedSize } }
    var recommendedSummary: [JunkModel.CategorySummary] { JunkModel.summary(of: recommendedItems) }

    /// What the results headline says. Safety rule 3 means caches used in the last 7 days are never
    /// picked for the user, so right after a clean "nothing recommended" is normal; the copy says so
    /// instead of claiming there is nothing to clean.
    enum Headline: Equatable {
        /// "2.4 GB ready to go".
        case ready(Int64)
        /// Nothing recommended, but there are safe junk items the user can still choose (`recentSafe`
        /// of them were used in the last week).
        case nothingAutomatic(safe: Int, recentSafe: Int)
        /// Nothing recommended and no safe junk, but some tile has something to review.
        case reviewOnly
        /// Every module finished and found nothing.
        case allEmpty
    }

    /// Safe, cleanable junk (recommended or not).
    var safeJunkItems: [ScanItem] {
        (junk?.results.flatMap(\.items) ?? []).filter { $0.risk == .safe && !$0.detectionOnly }
    }

    var headline: Headline {
        if recommendedBytes > 0 { return .ready(recommendedBytes) }
        let safe = safeJunkItems
        if !safe.isEmpty {
            return .nothingAutomatic(safe: safe.count, recentSafe: safe.filter { !$0.isSelected }.count)
        }
        let empty = modules.allSatisfy { state($0) == .finished && count($0) == 0 }
        return empty ? .allEmpty : .reviewOnly
    }

    /// The Junk tile's line: "17 of 23 recommended", "126 safe, none recommended", "4 items to review".
    var junkTileDetail: String {
        let recommended = recommendedItems.count
        let safe = safeJunkItems.count
        let count = count(.junk)
        let base: String
        if recommended > 0 {
            base = "\(recommended) of \(count) recommended"
        } else if safe > 0 {
            base = "\(safe) safe, none recommended"
        } else {
            base = count == 1 ? "1 item to review" : "\(count) items to review"
        }
        return "\(base) · Review →"
    }

    /// Junk categories partly skipped for Full Disk Access.
    var junkSkippedCategories: Int { Set(junk?.skipped.map(\.category) ?? []).count }

    // MARK: - Sweeping

    func load() async {
        lastSwept = await settings.date(.lastSwept)
    }

    /// Starts a Sweep (⌘R). Does nothing while one runs or while cleaning.
    func start() {
        guard phase != .scanning, !isCleaning else { return }
        let access = hasFullDiskAccess()
        lastAccess = access
        sweepGeneration += 1
        phase = .scanning
        wasCancelled = false
        issue = nil
        lastReport = nil
        undoDeadline = nil
        findings = [:]
        states = Dictionary(uniqueKeysWithValues: modules.map { ($0, .waiting) })
        sweepTask = Task { await runSweep(hasFullDiskAccess: access) }
    }

    /// Starts and waits until the Sweep ends (tests, DEBUG runs).
    func sweep() async {
        start()
        await sweepTask?.value
    }

    /// Stops every module (Esc). The screen goes back to the start; nothing was changed.
    func cancel() {
        guard phase == .scanning else { return }
        sweepTask?.cancel()
    }

    /// Waits for the running Sweep (if any) to end.
    func waitForSweep() async { await sweepTask?.value }

    private func runSweep(hasFullDiskAccess: Bool) async {
        let coordinator = coordinator
        let (stream, continuation) = AsyncStream.makeStream(of: SweepEvent.self)
        let sweep = Task.detached {
            await coordinator.sweep(hasFullDiskAccess: hasFullDiskAccess, events: continuation)
        }
        // Cancelling this task cancels the detached Sweep too.
        let outcome = await withTaskCancellationHandler {
            for await event in stream { states[event.module] = event.state }
            return await sweep.value
        } onCancel: {
            sweep.cancel()
        }
        sweepTask = nil
        states = outcome.states
        seconds = outcome.seconds
        if outcome.wasCancelled || Task.isCancelled {
            // Back to the start; the stopped modules' states stay readable (DEBUG report).
            phase = .idle
            wasCancelled = true
            findings = [:]
            return
        }
        findings = outcome.findings
        watchJunkApps()
        phase = .results
        let failed = modules.filter {
            if case .failed = outcome.states[$0] { return true }
            return false
        }
        if !failed.isEmpty { issue = .sweepPartly(failed.map(\.title)) }
        await markSwept()
        await handoff.finished(outcome, hasFullDiskAccess)
    }

    private func markSwept() async {
        let date = now()
        lastSwept = date
        await settings.set(date, for: .lastSwept)
    }

    // MARK: - Clean recommended

    private func watchJunkApps() {
        guard let junk else { return }
        runningApps.watch(RunningApps.bundleIDs(of: junk.results.flatMap(\.items), rules: junk.rulesByID))
    }

    func requestClean() {
        // A launch notification may not have arrived yet; what's open now drops out of the set.
        runningApps.refresh()
        guard phase == .results, !recommendedItems.isEmpty, !isCleaning else { return }
        isConfirming = true
    }

    /// "Quit Chrome" on the left-out line: asks once before quitting.
    func requestQuit(_ app: BlockingApp) {
        guard !app.bundleID.isEmpty else { return }
        quitPrompt = app
    }

    /// After "Quit Chrome?": asks politely (never forced). Its cache rejoins the recommended set
    /// by itself once the app has closed.
    func confirmQuit() async {
        guard let app = quitPrompt else { return }
        quitPrompt = nil
        if await !runningApps.quit(app) { issue = .appDidNotQuit(app.name) }
    }

    /// After the confirmation: moves the recommended junk to the Trash and celebrates.
    func confirmClean() async {
        isConfirming = false
        // Enforced here as well as in `recommendedItems`: only `.safe`, pre-selected junk.
        let items = JunkScanOutput.recommended(recommendedItems)
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        let report = await cleaner.clean(items)
        if report.logFailed { issue = .cleanupNotLogged }
        removeJunk(report.cleanedItemIDs)
        handoff.cleaned(report.cleanedItemIDs)
        lastReport = report
        undoDeadline = report.logIDs.isEmpty ? nil : now().addingTimeInterval(Self.undoWindow)
        if !report.moved.isEmpty {
            spaceChanged(.movedToTrash)
            await markSwept()
        }
    }

    /// Puts back what "Clean recommended" moved, then looks for junk again.
    func undoLastClean() async {
        guard let report = lastReport, !report.logIDs.isEmpty else { return }
        undoDeadline = nil
        let undo = await cleaner.undo(report.logIDs)
        lastReport = nil
        if !undo.failed.isEmpty { issue = .putBackFailed(undo.failed.count) }
        if !undo.restored.isEmpty { spaceChanged(.putBack) }
        await rescanJunk()
    }

    func dismissResult() {
        lastReport = nil
        undoDeadline = nil
    }

    func dismissIssue() { issue = nil }

    /// Re-runs only the Junk module (after Undo) and hands its results on.
    private func rescanJunk() async {
        let coordinator = coordinator
        let access = lastAccess
        let generation = sweepGeneration
        states[.junk] = .running(nil)
        let outcome = await Task.detached {
            await coordinator.sweep(hasFullDiskAccess: access, only: [.junk])
        }.value
        // A new Sweep started meanwhile (⌘R right after Undo): its own Junk result wins.
        guard generation == sweepGeneration, phase == .results else { return }
        states[.junk] = outcome.states[.junk] ?? .finished
        if let finding = outcome.findings[.junk] { findings[.junk] = finding }
        watchJunkApps()
        await handoff.finished(outcome, access)
    }

    private func removeJunk(_ ids: Set<UUID>) {
        guard !ids.isEmpty, var output = junk else { return }
        output.results = output.results.compactMap { result in
            let items = result.items.filter { !ids.contains($0.id) }
            guard !items.isEmpty else { return nil }
            return ScanResult(
                category: result.category, items: items, totalBytes: items.reduce(0) { $0 + $1.allocatedSize },
                duration: result.duration)
        }
        findings[.junk] = .junk(output)
    }

    #if DEBUG
        /// DEBUG screenshots: shows made-up states without scanning.
        func debugShow(
            phase: Phase, states: [SweepModule: SweepModuleState], findings: [SweepModule: SweepFinding] = [:]
        ) {
            self.phase = phase
            self.states = states
            self.findings = findings
            watchJunkApps()
        }
    #endif
}
