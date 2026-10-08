import Foundation
import Observation
import os

/// State for the Junk screen: scan, review, select, clean, undo.
///
/// Scanning runs in `JunkScanner` and cleaning in `Cleaner` (both actors, off the main actor);
/// this model only mirrors their results. It never touches the file system itself.
@Observable
@MainActor
final class JunkModel {
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case size, date
        var id: String { rawValue }
        var title: String { self == .size ? "Size" : "Date" }
    }

    /// The list's risk filter (All / Safe / Review). Kept for the session only.
    enum RiskFilter: String, CaseIterable, Identifiable, Sendable {
        case all, safe, review
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .safe: "Safe"
            case .review: "Review"
            }
        }
        /// The select-all label follows the filter.
        var selectAllTitle: String {
            switch self {
            case .all: "Select all"
            case .safe: "Select all safe"
            case .review: "Select all to review"
            }
        }
        func includes(_ risk: Risk) -> Bool {
            switch self {
            case .all: true
            case .safe: risk == .safe
            case .review: risk == .review
            }
        }
    }

    /// Where the last select-all acted (its "N skipped" note shows there).
    enum SelectAllScope: Sendable {
        case list, everywhere
    }

    /// One line of the confirmation sheet.
    struct CategorySummary: Identifiable, Equatable {
        let category: JunkCategory
        let count: Int
        let bytes: Int64
        var id: JunkCategory { category }
    }

    /// How long "Undo" stays on the result view.
    static let undoWindow: TimeInterval = 30

    private(set) var results: [ScanResult] = []
    private(set) var progress: ScanProgress?
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var isCleaning = false
    /// A non-fatal problem, shown as a quiet banner.
    private(set) var issue: DustpanError?
    /// Rules the last scan didn't run (e.g. they need Full Disk Access).
    private(set) var skipped: [SkippedRule] = []
    private(set) var rulesByID: [String: Rule] = [:]
    private(set) var ignored: [IgnoreEntry] = []

    /// IDs of ticked items.
    private(set) var selection: Set<UUID> = []
    /// The category shown in the list.
    var focusedCategory: JunkCategory?
    var searchText = ""
    var sort: Sort = .size
    var riskFilter: RiskFilter = .all
    /// Items the last select-all left out because their apps are open, and where it ran.
    private(set) var skippedForOpenApps = 0
    private(set) var skippedScope: SelectAllScope = .list
    /// Ticked items that were unticked because their app opened (a quiet banner).
    private(set) var unticked: String?
    /// "Quit Chrome?" is showing (from a row's Quit button).
    var quitPrompt: BlockingApp?
    /// Apps that didn't quit when the confirmation's "Quit them for me" asked (shown in the sheet).
    private(set) var stillOpen: [String] = []

    /// The "Move … to Trash" confirmation is showing.
    var isConfirming = false
    /// The result view after a clean (nil = list).
    private(set) var lastReport: CleanReport?
    private(set) var undoDeadline: Date?
    /// The Empty Trash confirmation, with what's in the Trash right now.
    var trashToEmpty: TrashSummary?
    /// Bytes freed by the last Empty Trash, for a quiet note.
    private(set) var emptiedBytes: Int64?
    /// The last Empty Trash, while it left something in the Trash (a calm note, not an error).
    private(set) var trashLeft: EmptyTrashReport?
    /// Bytes in the Trash only Finder can delete (the Trash tile's note); 0 when unknown.
    private(set) var trashKeptBytes: Int64 = 0
    /// Opens the Trash in Finder (set by `AppState`; tests record it).
    var openTrashInFinder: () -> Void = {}
    /// Something was moved to the Trash since it was last emptied: the bottom bar says the space
    /// comes back with Empty Trash (moving to the Trash frees nothing on its own).
    private(set) var showsTrashNote = false
    /// Reports moves, put-backs and Empty Trash to `AppState` (disk bar, Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }

    private let catalog: RuleCatalog
    private let cleaner: Cleaner
    private let store: CleanupStore
    private let home: URL
    /// Which apps junk waits on are open (shared with the Sweep through `AppState`).
    let runningApps: RunningApps
    private var lastAccess = true
    private let logger = Logger(subsystem: "app.dustpan", category: "junk")

    init(
        catalog: RuleCatalog, cleaner: Cleaner, store: CleanupStore, home: URL,
        runningApps: RunningApps = .idle()
    ) {
        self.catalog = catalog
        self.cleaner = cleaner
        self.store = store
        self.home = home
        self.runningApps = runningApps
        runningApps.observe { [weak self] _ in self?.runningAppsChanged() }
    }

    // MARK: - Derived

    /// Categories with at least one skipped rule, for "3 categories need Full Disk Access".
    var skippedCategories: [JunkCategory] { Set(skipped.map(\.category)).sorted() }
    var totalBytes: Int64 { results.reduce(0) { $0 + $1.totalBytes } }
    var allItems: [ScanItem] { results.flatMap(\.items) }
    var selectedItems: [ScanItem] { allItems.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.allocatedSize } }

    func result(for category: JunkCategory) -> ScanResult? { results.first { $0.category == category } }

    func selectedBytes(in category: JunkCategory) -> Int64 {
        (result(for: category)?.items ?? []).filter { selection.contains($0.id) }.reduce(0) { $0 + $1.allocatedSize }
    }

    func selectedCount(in category: JunkCategory) -> Int {
        (result(for: category)?.items ?? []).filter { selection.contains($0.id) }.count
    }

    /// The focused category's items, filtered by risk and the search text, and sorted.
    var visibleItems: [ScanItem] {
        guard let category = focusedCategory, let result = result(for: category) else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = result.items.filter { item in
            riskFilter.includes(item.risk)
                && (query.isEmpty
                    || item.url.path.lowercased().contains(query)
                    || (rulesByID[item.ruleID]?.title.lowercased().contains(query) ?? false))
        }
        switch sort {
        case .size: return filtered.sorted { $0.allocatedSize > $1.allocatedSize }
        case .date: return filtered.sorted { $0.modified < $1.modified }
        }
    }

    /// Items the user can tick: not detection-only (shown, never cleaned), and not waiting on an
    /// open app (safety rule 5, shown up front).
    func isSelectable(_ item: ScanItem) -> Bool { !item.detectionOnly && blocker(for: item) == nil }

    /// The open app `item` waits on, if any.
    func blocker(for item: ScanItem) -> BlockingApp? { runningApps.blocker(for: item, rules: rulesByID) }

    /// How many items in a category wait on an open app (tile subtitle).
    func blockedCount(in category: JunkCategory) -> Int {
        (result(for: category)?.items ?? []).filter { !$0.detectionOnly && blocker(for: $0) != nil }.count
    }

    /// Ticked items whose app is open (listed at the top of the confirmation).
    var blockedSelection: [ScanItem] { selectedItems.filter { blocker(for: $0) != nil } }

    /// Ticked items that can move now: what the confirmation's button moves.
    var movableSelection: [ScanItem] { selectedItems.filter { blocker(for: $0) == nil } }
    var movableBytes: Int64 { movableSelection.reduce(0) { $0 + $1.allocatedSize } }

    /// One line per open app among the ticked items, for the confirmation.
    var blockedGroups: [BlockedGroup] { BlockedGroup.groups(blockedSelection, blocker: blocker(for:)) }

    /// Safe items that "Select all safe" would add (not detection-only, not waiting on an app).
    var canSelectAllSafe: Bool {
        allItems.contains { $0.risk == .safe && isSelectable($0) && !selection.contains($0.id) }
    }

    /// Every visible, selectable item is ticked.
    var allVisibleSelected: Bool {
        let selectable = visibleItems.filter(isSelectable)
        return !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) }
    }

    /// The confirmation's lines: only what can move now.
    var summary: [CategorySummary] { Self.summary(of: movableSelection) }

    /// One line per category for a confirmation (also used by the Sweep's "Clean recommended").
    static func summary(of items: [ScanItem]) -> [CategorySummary] {
        Dictionary(grouping: items, by: \.category).keys.sorted().map { category in
            let inCategory = items.filter { $0.category == category }
            return CategorySummary(
                category: category, count: inCategory.count, bytes: inCategory.reduce(0) { $0 + $1.allocatedSize })
        }
    }

    func rule(for item: ScanItem) -> Rule? { rulesByID[item.ruleID] }

    /// Display name: the folder or file name.
    static func name(of item: ScanItem) -> String { item.url.lastPathComponent }

    /// The path with the home folder shown as `~`.
    func displayPath(_ url: URL) -> String {
        let homePath = home.path
        let path = url.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    // MARK: - Selection

    func isSelected(_ item: ScanItem) -> Bool { selection.contains(item.id) }

    // MARK: Keyboard

    /// The row the keyboard is on: ↑/↓ move it, space ticks it, ⌘I shows its details.
    var focusedItemID: UUID?

    var focusedItem: ScanItem? { focusedItemID.flatMap { id in visibleItems.first { $0.id == id } } }

    func moveFocus(by offset: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }
        let current =
            focusedItemID.flatMap { id in visible.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : visible.count)
        focusedItemID = visible[min(max(current + offset, 0), visible.count - 1)].id
    }

    /// Space bar: ticks or unticks the focused row (the first row if none is focused yet).
    func toggleFocused() {
        if focusedItem == nil { moveFocus(by: 1) }
        guard let item = focusedItem, isSelectable(item) else { return }
        setSelected(item, !isSelected(item))
    }

    func setSelected(_ item: ScanItem, _ on: Bool) {
        if on {
            guard isSelectable(item) else { return }
            selection.insert(item.id)
        } else {
            selection.remove(item.id)
        }
    }

    /// Ticks or unticks every visible item (filtered and searched) in the focused category.
    /// Ticking skips detection-only items and items whose app is open, and counts the latter.
    /// Young `.safe` items are included: select-all is the user's own choice (safety rule 3 is
    /// about what Dustpan pre-selects).
    func setAllVisibleSelected(_ on: Bool) {
        if on {
            select(visibleItems, scope: .list)
        } else {
            selection.subtract(visibleItems.map(\.id))
            skippedForOpenApps = 0
        }
    }

    /// "Select all safe" across every category: `.safe`, not detection-only, not waiting on an
    /// open app. Never `.review` items. Young items are included (the user's explicit choice).
    func selectAllSafe() {
        select(allItems.filter { $0.risk == .safe }, scope: .everywhere)
    }

    private func select(_ items: [ScanItem], scope: SelectAllScope) {
        var skipped = 0
        for item in items where !item.detectionOnly {
            if blocker(for: item) != nil {
                skipped += 1
            } else {
                selection.insert(item.id)
            }
        }
        skippedForOpenApps = skipped
        skippedScope = scope
    }

    /// "2 skipped — their apps are open".
    var skippedNote: String? {
        switch skippedForOpenApps {
        case 0: nil
        case 1: "1 skipped — its app is open"
        default: "\(skippedForOpenApps) skipped — their apps are open"
        }
    }

    // MARK: - Open apps

    /// An app opened or quit. Ticked items whose app is now open are unticked with a quiet note,
    /// except while the confirmation shows: it lists them with "Quit them for me" / "Leave them".
    private func runningAppsChanged() {
        if skippedForOpenApps > 0 { skippedForOpenApps = 0 }
        guard !isConfirming else { return }
        let blocked = blockedSelection
        guard !blocked.isEmpty else { return }
        selection.subtract(blocked.map(\.id))
        let names = Set(blocked.compactMap { blocker(for: $0)?.name }).sorted()
        let items = blocked.count == 1 ? "1 item was" : "\(blocked.count) items were"
        unticked =
            "\(ListFormatter.localizedString(byJoining: names)) opened, so \(items) unticked. Quit \(names.count == 1 ? "it" : "them") first to clean \(blocked.count == 1 ? "it" : "them")."
    }

    func dismissUnticked() { unticked = nil }

    /// A row's "Quit Chrome": asks once before quitting.
    func requestQuit(_ app: BlockingApp) {
        guard !app.bundleID.isEmpty else { return }
        quitPrompt = app
    }

    /// After "Quit Chrome?": asks the app politely (never forced). The rows unblock by themselves
    /// when it closes; nothing gets ticked for the user.
    func confirmQuit() async {
        guard let app = quitPrompt else { return }
        quitPrompt = nil
        if await !runningApps.quit(app) { issue = .appDidNotQuit(app.name) }
    }

    /// The confirmation's "Quit them for me": asks each open app to quit. What closes stays ticked.
    func quitBlockedApps() async {
        stillOpen = []
        for app in Set(blockedSelection.compactMap(blocker(for:))).sorted(by: { $0.name < $1.name }) {
            if await !runningApps.quit(app) { stillOpen.append(app.name) }
        }
    }

    /// The confirmation's "Leave them": unticks what waits on an open app.
    func leaveBlocked() {
        selection.subtract(blockedSelection.map(\.id))
        stillOpen = []
        if selection.isEmpty { isConfirming = false }
    }

    // MARK: - Scan

    /// Scans the home folder with the catalogue's rules (optionally narrowed by `include`),
    /// leaving out ignored paths and rules. Without Full Disk Access, rules that need it are
    /// skipped and listed in `skipped`.
    func scan(hasFullDiskAccess: Bool, include: (@Sendable (Rule) -> Bool)? = nil) async {
        guard !isScanning else { return }
        isScanning = true
        issue = nil
        lastAccess = hasFullDiskAccess
        defer { isScanning = false }
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self, bufferingPolicy: .bufferingNewest(1))
        async let scanned = JunkScanRun.run(
            catalog: catalog, store: store, home: home, hasFullDiskAccess: hasFullDiskAccess, include: include,
            progress: continuation)
        for await update in stream { progress = update }
        do {
            adopt(try await scanned)
            await refreshTrashKept()
        } catch {
            issue = error as? DustpanError ?? .rulesInvalid("\(error)")
            logger.error("Junk scan could not start: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Whether the screen is free to take results it didn't scan itself (a Sweep's).
    var canAdopt: Bool {
        !isScanning && !isCleaning && !isConfirming && lastReport == nil && trashToEmpty == nil && quitPrompt == nil
    }

    /// Shows a scan's results (its own, or a Sweep's, so the screen doesn't look again).
    func adopt(_ output: JunkScanOutput, hasFullDiskAccess: Bool? = nil) {
        if let hasFullDiskAccess { lastAccess = hasFullDiskAccess }
        rulesByID = output.rulesByID
        ignored = output.ignored
        skipped = output.skipped
        apply(output.results)
        hasScanned = true
    }

    /// Drops items someone else (the Sweep) moved to the Trash.
    func forget(_ ids: Set<UUID>) { remove(ids) }

    private func apply(_ newResults: [ScanResult]) {
        results = newResults
        let items = newResults.flatMap(\.items)
        runningApps.watch(RunningApps.bundleIDs(of: items, rules: rulesByID))
        // Pre-selection leaves out items whose app is open; their rows say why.
        selection = Set(items.filter { $0.isSelected && isSelectable($0) }.map(\.id))
        skippedForOpenApps = 0
        if focusedCategory.flatMap(result(for:)) == nil {
            focusedCategory = newResults.max { $0.totalBytes < $1.totalBytes }?.category
        }
    }

    /// Drops items from the results (after cleaning or ignoring) without rescanning.
    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        results = results.compactMap { result in
            let items = result.items.filter { !ids.contains($0.id) }
            guard !items.isEmpty else { return nil }
            return ScanResult(
                category: result.category, items: items, totalBytes: items.reduce(0) { $0 + $1.allocatedSize },
                duration: result.duration)
        }
        selection.subtract(ids)
        if let focused = focusedCategory, result(for: focused) == nil {
            focusedCategory = results.max { $0.totalBytes < $1.totalBytes }?.category
        }
    }

    // MARK: - Clean

    func requestClean() {
        guard !selection.isEmpty, !isCleaning else { return }
        stillOpen = []
        isConfirming = true
        // A launch notification may not have arrived yet: anything ticked whose app is open now is
        // listed at the top of the confirmation, never silently left for the Cleaner to skip.
        runningApps.refresh()
    }

    func cancelClean() {
        isConfirming = false
        stillOpen = []
        // Anything still waiting on an open app is unticked now, as it would have been on the list.
        runningAppsChanged()
    }

    /// Runs after the user confirmed: moves what can move now to the Trash and shows the result.
    /// Items waiting on an open app stay ticked and listed (the Cleaner checks again regardless).
    func confirmClean() async {
        isConfirming = false
        stillOpen = []
        // What still waits on an open app was listed in the confirmation; it stays where it is.
        selection.subtract(blockedSelection.map(\.id))
        let items = movableSelection
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
        let report = await cleaner.clean(items)
        if report.logFailed { issue = .cleanupNotLogged }
        remove(report.cleanedItemIDs)
        lastReport = report
        undoDeadline = report.logIDs.isEmpty ? nil : Date().addingTimeInterval(Self.undoWindow)
        if !report.moved.isEmpty { spaceChanged(.movedToTrash) }
    }

    /// Puts back everything the last clean moved, then looks again.
    func undoLastClean() async {
        guard let report = lastReport, !report.logIDs.isEmpty else { return }
        undoDeadline = nil
        let undo = await cleaner.undo(report.logIDs)
        lastReport = nil
        if !undo.failed.isEmpty { issue = .putBackFailed(undo.failed.count) }
        await scan(hasFullDiskAccess: lastAccess)
        if !undo.restored.isEmpty { spaceChanged(.putBack) }
    }

    func dismissResult() {
        lastReport = nil
        undoDeadline = nil
    }

    func dismissIssue() { issue = nil }

    // MARK: - Ignore

    /// Stops suggesting this one item.
    func ignore(_ item: ScanItem) async {
        do {
            try await store.ignore(path: item.url.path)
            remove([item.id])
            ignored = (try? await store.ignoreEntries()) ?? ignored
        } catch {
            issue = .ignoreNotSaved
        }
    }

    /// Stops suggesting anything `item`'s rule finds.
    func ignoreRule(of item: ScanItem) async {
        do {
            try await store.ignore(ruleID: item.ruleID)
            remove(Set(allItems.filter { $0.ruleID == item.ruleID }.map(\.id)))
            ignored = (try? await store.ignoreEntries()) ?? ignored
        } catch {
            issue = .ignoreNotSaved
        }
    }

    /// Takes something off the ignore list; it shows up again on the next scan.
    func stopIgnoring(_ entry: IgnoreEntry) async {
        guard let id = entry.id else { return }
        do {
            try await store.removeIgnore(id: id)
            ignored.removeAll { $0.id == id }
        } catch {
            issue = .ignoreNotSaved
        }
    }

    func ignoreTitle(_ entry: IgnoreEntry) -> String {
        if let path = entry.path { return displayPath(URL(fileURLWithPath: path)) }
        if let ruleID = entry.ruleID { return "Everything in “\(rulesByID[ruleID]?.title ?? ruleID)”" }
        return ""
    }

    // MARK: - Empty Trash

    /// Reads what's in the Trash and opens the confirmation (which lists the size).
    func requestEmptyTrash() async {
        let cleaner = cleaner
        do {
            trashToEmpty = try await cleaner.trashSummary()
        } catch {
            issue = error as? DustpanError ?? .trashUnreadable
        }
    }

    /// The only permanent delete. Runs only from the confirmation's button, and only when the
    /// confirmation offered something Dustpan can delete.
    func confirmEmptyTrash() async {
        guard let summary = trashToEmpty else { return }
        trashToEmpty = nil
        guard summary.hasDeletable else { return }
        do {
            let report = try await cleaner.emptyTrash(summary)
            emptiedBytes = report.freedBytes
            trashLeft = report.left.isEmpty ? nil : report
            trashKeptBytes = report.leftBytes
            if report.left.isEmpty { remove(Set(allItems.filter { $0.category == .trash }.map(\.id))) }
        } catch {
            issue = error as? DustpanError ?? .trashNotEmptied
        }
        // Even a partly failed Empty Trash may have deleted something.
        spaceChanged(.emptiedTrash)
    }

    func dismissEmptiedNote() {
        emptiedBytes = nil
        trashLeft = nil
    }

    /// Opens the Trash in Finder and closes the confirmation (Finder can delete what Dustpan can't).
    func showTrashInFinder() {
        trashToEmpty = nil
        openTrashInFinder()
    }

    /// Re-reads how much of the Trash only Finder can delete (off the main actor).
    func refreshTrashKept() async {
        guard result(for: .trash) != nil else {
            trashKeptBytes = 0
            return
        }
        let cleaner = cleaner
        trashKeptBytes = (try? await cleaner.trashKeptBytes()) ?? 0
    }

    // MARK: - Trash tile

    /// Called by `AppState` for every move, put-back or Empty Trash anywhere in the app.
    func noteSpaceChange(_ change: SpaceChange) {
        switch change {
        case .movedToTrash: showsTrashNote = true
        case .emptiedTrash: showsTrashNote = false
        case .putBack: break
        }
    }

    /// Measures the Trash again with the Trash rule alone (same scanner, ignore list and Full Disk
    /// Access rules as a full scan, off the main actor) and updates the Trash tile in place.
    /// Without Full Disk Access the Trash can't be read, so the tile is left as it is (absent,
    /// with the "needs Full Disk Access" note) rather than showing a made-up number.
    func refreshTrash() async {
        guard hasScanned, lastAccess, !isScanning else { return }
        let output: JunkScanOutput
        do {
            output = try await JunkScanRun.run(
                catalog: catalog, store: store, home: home, hasFullDiskAccess: lastAccess,
                include: { $0.category == .trash })
        } catch {
            logger.error("Trash re-measure failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        // A full scan started meanwhile has the newer figure; a skipped Trash rule means no access.
        guard !isScanning, !output.skipped.contains(where: { $0.category == .trash }) else { return }
        let fresh = output.results.first { $0.category == .trash }
        let old = Set(allItems.filter { $0.category == .trash }.map(\.id))
        results.removeAll { $0.category == .trash }
        if let fresh { results = (results + [fresh]).sorted { $0.category < $1.category } }
        selection.subtract(old)
        if fresh == nil { showsTrashNote = false }
        await refreshTrashKept()
        if let focused = focusedCategory, result(for: focused) == nil {
            focusedCategory = results.max { $0.totalBytes < $1.totalBytes }?.category
        }
    }

    #if DEBUG
        /// Selects exactly one item (DEBUG self-test).
        func debugSelectOnly(_ ids: Set<UUID>) { selection = ids }
    #endif
}

/// Ticked items that wait on one open app: "Google Chrome is open — 2 items, 415 MB".
struct BlockedGroup: Identifiable, Equatable {
    let app: BlockingApp
    let count: Int
    let bytes: Int64
    var id: String { app.id }

    static func groups(_ items: [ScanItem], blocker: (ScanItem) -> BlockingApp?) -> [BlockedGroup] {
        var byApp: [BlockingApp: (count: Int, bytes: Int64)] = [:]
        for item in items {
            guard let app = blocker(item) else { continue }
            byApp[app, default: (0, 0)].count += 1
            byApp[app, default: (0, 0)].bytes += item.allocatedSize
        }
        return byApp.map { BlockedGroup(app: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.bytes == $1.bytes ? $0.app.name < $1.app.name : $0.bytes > $1.bytes }
    }
}
