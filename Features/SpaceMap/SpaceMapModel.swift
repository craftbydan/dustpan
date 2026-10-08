import AppKit
import Foundation
import Observation
import os

/// State for the Space map: which place to map, the walked `SizeTree`, the folder being shown,
/// and Move to Trash / Ignore through the Cleaner and the ignore list.
@Observable
@MainActor
final class SpaceMapModel {
    enum Scope: Hashable, Sendable {
        case home
        case disk
        case folder(URL)

        var title: String {
            switch self {
            case .home: "Home"
            case .disk: "Macintosh HD"
            case .folder(let url): url.lastPathComponent
            }
        }
    }

    /// One block on the map: a node, or everything too small to draw, grouped.
    struct Entry: Identifiable, Equatable {
        enum Content: Equatable {
            case node(UInt32)
            /// The rest of the folder, `count` items.
            case others(count: Int)
        }
        let content: Content
        let name: String
        let size: Int64
        let fileKind: FileKind
        let nodeKind: SizeTree.Kind
        let canDrill: Bool

        var id: String {
            switch content {
            case .node(let index): "n\(index)"
            case .others: "others"
            }
        }
        var node: UInt32? {
            if case .node(let index) = content { return index }
            return nil
        }
    }

    /// What a Move to Trash request found before the confirmation: the items that may go, and the
    /// ones the Cleaner would refuse (with its reason, and the open app for a running app bundle).
    struct PendingTrash: Equatable {
        struct Refusal: Equatable {
            let index: UInt32
            let url: URL
            let reason: SkipReason
            let app: BlockingApp?
        }
        let allowed: [UInt32]
        let refused: [Refusal]
        let allowedBytes: Int64
        var blockingApps: [BlockingApp] {
            var seen = Set<String>()
            return refused.compactMap(\.app).filter { seen.insert($0.bundleID).inserted }
        }
    }

    /// The last Move to Trash, undoable for `undoWindow` seconds.
    struct LastMove: Equatable {
        /// The item's name, or "N items".
        let name: String
        var count = 1
        let bytes: Int64
        let logIDs: [Int64]
        let folderPath: String
        let deadline: Date
    }

    static let maxBlocks = 240
    static let topCount = 50
    static let undoWindow: TimeInterval = 30

    var scope: Scope = .home
    private(set) var tree: SizeTree?
    private(set) var current: UInt32 = SizeTree.root
    private(set) var entries: [Entry] = []
    private(set) var topItems: [UInt32] = []
    private(set) var isWalking = false
    private(set) var progress = WalkProgress()
    /// Bytes the walk is expected to reach (the volume's used space), for the progress blob.
    private(set) var expectedBytes: Int64 = 1
    private(set) var walkSeconds: TimeInterval?
    /// Folders not opened because Full Disk Access is off, shown as `~/…`.
    private(set) var needsAccessPaths: [String] = []
    private(set) var protectedBytes: Int64 = 0
    /// Picked blocks / rows, all in the current folder. Cleared on drill, go up and after a move.
    private(set) var selection: Set<UInt32> = []
    /// The block the keyboard is on (and the last one clicked).
    private(set) var focused: UInt32?
    /// The open confirmation, after the pre-check.
    private(set) var pendingTrash: PendingTrash?
    private(set) var isChecking = false
    private(set) var isMoving = false
    /// The "Click a block to select it…" hint was used once; after that it's a "?" button.
    private(set) var hintSeen = false
    private(set) var lastMove: LastMove?
    private(set) var issue: DustpanError?
    private(set) var ignore = IgnoreList()

    private let walker: DiskWalker
    private let cleaner: Cleaner
    let runningApps: RunningApps
    private let settings: SettingsStore?
    /// Reports moves and put-backs to `AppState` (disk bar, Junk's Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }
    private let store: CleanupStore
    let home: URL
    private var walkTask: Task<Void, Never>?
    private var walkGeneration = 0
    private let logger = Logger(subsystem: "app.dustpan", category: "spacemap")

    init(
        walker: DiskWalker, cleaner: Cleaner, store: CleanupStore, home: URL, runningApps: RunningApps = .idle(),
        settings: SettingsStore? = nil
    ) {
        self.walker = walker
        self.cleaner = cleaner
        self.runningApps = runningApps
        self.settings = settings
        self.store = store
        self.home = URL(fileURLWithPath: PathTools.canonical(home.path) ?? home.path, isDirectory: true)
    }

    var hasMap: Bool { tree != nil }

    var scopeURL: URL {
        switch scope {
        case .home: home
        case .disk: URL(fileURLWithPath: "/", isDirectory: true)
        case .folder(let url): url
        }
    }

    // MARK: - Walking

    /// Maps `scope` (cancelling a walk in progress).
    func start(_ scope: Scope? = nil) {
        if let scope { self.scope = scope }
        walkTask?.cancel()
        walkGeneration += 1
        let generation = walkGeneration
        walkTask = Task { await walk(generation: generation) }
    }

    func cancelWalk() {
        walkTask?.cancel()
    }

    /// Waits for the current walk (DEBUG flows).
    func waitForWalk() async {
        await walkTask?.value
    }

    private func walk(generation: Int) async {
        isWalking = true
        progress = WalkProgress()
        issue = nil
        let url = scopeURL
        if let space = try? await DiskSpace.read(for: url) { expectedBytes = max(space.usedBytes, 1) }
        ignore = await store.ignoreList()
        let started = Date()
        do {
            let tree = try await walker.walk(url) { [weak self] progress in
                Task { @MainActor in self?.progress = progress }
            }
            if !Task.isCancelled, generation == walkGeneration {
                show(tree)
                walkSeconds = Date().timeIntervalSince(started)
            }
        } catch {
            // Cancelled: keep whatever map was there.
        }
        if generation == walkGeneration { isWalking = false }
    }

    private func show(_ tree: SizeTree) {
        self.tree = tree
        current = SizeTree.root
        clearSelection()
        let homePath = home.path
        needsAccessPaths = tree.nodes(ofKind: .needsAccess).map { Self.display(tree.path($0), home: homePath) }.sorted()
        protectedBytes = tree.nodes(ofKind: .protected).reduce(0) { $0 + tree.size($1) }
        refreshCurrent()
    }

    // MARK: - Navigation

    var breadcrumb: [UInt32] { tree?.ancestry(of: current) ?? [] }

    func title(of index: UInt32) -> String {
        guard let tree else { return "" }
        return index == SizeTree.root ? scope.title : tree.name(index)
    }

    /// Opens a folder (double-click, Return, →). A file just gets selected.
    func drill(into index: UInt32) {
        guard let tree, tree.isBrowsable(index) else {
            click(index)
            return
        }
        current = index
        clearSelection()
        refreshCurrent()
    }

    func go(to index: UInt32) {
        guard tree != nil else { return }
        current = index
        clearSelection()
        refreshCurrent()
    }

    /// One folder up (←, ⌘↑). False at the top.
    @discardableResult
    func goUp() -> Bool {
        guard let parent = tree?.parent(of: current) else { return false }
        go(to: parent)
        return true
    }

    // MARK: - Selection

    var selectedItems: [UInt32] {
        guard let tree else { return [] }
        return selection.sorted { tree.size($0) != tree.size($1) ? tree.size($0) > tree.size($1) : $0 < $1 }
    }
    var selectedBytes: Int64 { selection.reduce(0) { $0 + size($1) } }
    func isSelected(_ index: UInt32) -> Bool { selection.contains(index) }

    /// A click: selects only this block, or with ⌘/Shift (`toggle`) adds or removes it.
    func click(_ index: UInt32, toggle: Bool = false) {
        guard isSelectable(index) else { return }
        if toggle {
            setSelected(index, !selection.contains(index))
        } else {
            selection = [index]
        }
        focused = index
        markHintSeen()
    }

    /// Checkbox / ⌘-click: adds or removes one item, keeping the rest.
    func setSelected(_ index: UInt32, _ isOn: Bool) {
        guard isSelectable(index) else { return }
        if isOn { selection.insert(index) } else { selection.remove(index) }
        focused = index
        markHintSeen()
    }

    func clearSelection() {
        selection = []
        focused = nil
    }

    /// Keyboard focus moved to a block (arrows); doesn't change the selection.
    func focus(_ index: UInt32?) { focused = index }

    /// Only direct children of the current folder, and real items (not the "smaller items" group).
    private func isSelectable(_ index: UInt32) -> Bool {
        guard let tree, index != current, index < UInt32(tree.count) else { return false }
        return tree.parent(of: index) == current
    }

    func loadHint() async {
        guard let settings else { return }
        hintSeen = await settings.bool(.spaceMapHintSeen)
    }

    private func markHintSeen() {
        guard !hintSeen else { return }
        hintSeen = true
        if let settings { Task { await settings.set(true, for: .spaceMapHintSeen) } }
    }

    private func refreshCurrent() {
        guard let tree else {
            entries = []
            topItems = []
            return
        }
        let children = tree.topChildren(of: current, limit: Self.maxBlocks + 1) { tree.size($0) > 0 }
        var entries: [Entry] = children.prefix(Self.maxBlocks).map { entry(for: $0, in: tree) }
        if children.count > Self.maxBlocks {
            let shown = Set(children.prefix(Self.maxBlocks))
            var rest: Int64 = 0
            var count = 0
            for child in tree.children(of: current) where !shown.contains(child) && tree.size(child) > 0 {
                rest += tree.size(child)
                count += 1
            }
            entries.append(
                Entry(
                    content: .others(count: count), name: "\(count.formatted()) smaller items", size: rest,
                    fileKind: .other, nodeKind: .other, canDrill: false))
        }
        self.entries = entries
        topItems = tree.topChildren(of: current, limit: Self.topCount) { [ignore] child in
            tree.size(child) > 0 && !ignore.ignores(path: tree.path(child), ruleID: "")
        }
    }

    private func entry(for index: UInt32, in tree: SizeTree) -> Entry {
        Entry(
            content: .node(index), name: tree.name(index), size: tree.size(index), fileKind: tree.fileKind(index),
            nodeKind: tree.kind(index), canDrill: tree.isBrowsable(index))
    }

    // MARK: - Facts for the views

    func name(_ index: UInt32) -> String { tree?.name(index) ?? "" }
    func size(_ index: UInt32) -> Int64 { tree?.size(index) ?? 0 }
    func kind(_ index: UInt32) -> SizeTree.Kind { tree?.kind(index) ?? .other }
    func fileKind(_ index: UInt32) -> FileKind { tree?.fileKind(index) ?? .other }
    func canDrill(_ index: UInt32) -> Bool { tree?.isBrowsable(index) ?? false }
    func path(_ index: UInt32) -> String { tree?.path(index) ?? "" }
    func displayPath(_ index: UInt32) -> String { Self.display(path(index), home: home.path) }
    var currentSize: Int64 { size(current) }

    func isIgnored(_ index: UInt32) -> Bool { ignore.ignores(path: path(index), ruleID: "") }

    /// Whether Move to Trash is offered at all (the Cleaner re-checks everything anyway).
    func canTrash(_ index: UInt32) -> Bool {
        guard let tree, index != SizeTree.root else { return false }
        switch tree.kind(index) {
        case .file, .directory, .link: break
        default: return false
        }
        return PathTools.isStrictlyInside(tree.path(index), root: home.path)
    }

    static func display(_ path: String, home: String) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Actions

    func reveal(_ index: UInt32) {
        guard tree != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path(index))])
    }

    func revealSelection() {
        let urls = selectedItems.map { URL(fileURLWithPath: path($0)) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Move to Trash on one block (context menu, hover button, list row): the whole selection when
    /// that block is part of it, else just the block.
    func requestTrash(_ index: UInt32) async {
        let items = selection.contains(index) && selection.count > 1 ? selectedItems : [index]
        await requestTrash(items)
    }

    /// The selection bar's Move to Trash and ⌘⌫.
    func requestTrashSelection() async {
        await requestTrash(selectedItems)
    }

    /// Pre-checks `items` with the Cleaner's own checks (nothing moves), then opens the
    /// confirmation listing what may go and what stays, with plain reasons.
    func requestTrash(_ items: [UInt32]) async {
        guard let tree, !isMoving, !isChecking else { return }
        let offered = items.filter(canTrash)
        guard !offered.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        let urls = offered.map { URL(fileURLWithPath: tree.path($0)) }
        let verdicts = await cleaner.precheckUserChosen(urls)
        var allowed: [UInt32] = []
        var refused: [PendingTrash.Refusal] = []
        for (index, verdict) in zip(offered, verdicts) {
            if let reason = verdict.reason {
                refused.append(.init(index: index, url: verdict.url, reason: reason, app: verdict.blockingApp))
            } else {
                allowed.append(index)
            }
        }
        if !refused.compactMap(\.app).isEmpty { runningApps.watch(Set(refused.compactMap(\.app?.bundleID))) }
        pendingTrash = PendingTrash(
            allowed: allowed, refused: refused, allowedBytes: allowed.reduce(0) { $0 + tree.size($1) })
    }

    func cancelTrash() { pendingTrash = nil }

    /// Quits the open apps the confirmation lists (politely), then checks the items again.
    func quitBlockingApps() async {
        guard let pending = pendingTrash else { return }
        for app in pending.blockingApps { await runningApps.quit(app) }
        await requestTrash(pending.allowed + pending.refused.map(\.index))
    }

    /// Moves the confirmed items that passed the pre-check, one by one through
    /// `Cleaner.trashUserChosen` (which checks everything again), then re-walks only the current
    /// folder. Clears the selection.
    func confirmTrash() async {
        guard let pending = pendingTrash, let tree else { return }
        pendingTrash = nil
        guard !pending.allowed.isEmpty else { return }
        isMoving = true
        defer { isMoving = false }
        let folder = tree.parent(of: pending.allowed[0]) ?? SizeTree.root
        var moved = UninstallReport()
        for index in pending.allowed {
            let report = await cleaner.trashUserChosen(
                URL(fileURLWithPath: tree.path(index)), knownBytes: tree.size(index))
            moved.moved += report.moved
            moved.skipped += report.skipped
            moved.logFailed = moved.logFailed || report.logFailed
        }
        clearSelection()
        if let skipped = moved.skipped.first {
            issue = .notMoved(skipped.reason.explanation)
        } else if moved.logFailed {
            issue = .cleanupNotLogged
        }
        let folderPath = tree.path(folder)
        if !moved.moved.isEmpty {
            spaceChanged(.movedToTrash)
            let name =
                moved.moved.count == 1
                ? moved.moved[0].original.lastPathComponent : "\(moved.moved.count) items"
            lastMove = LastMove(
                name: name, count: moved.moved.count, bytes: moved.freedBytes, logIDs: moved.logIDs,
                folderPath: folderPath, deadline: Date().addingTimeInterval(Self.undoWindow))
        }
        await refresh(folderPath: folderPath)
        guard !moved.moved.isEmpty else { return }
        let deadline = lastMove?.deadline
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            if self?.lastMove?.deadline == deadline { self?.lastMove = nil }
        }
    }

    func undoLastMove() async {
        guard let move = lastMove else { return }
        lastMove = nil
        clearSelection()
        let report = await cleaner.undo(move.logIDs)
        if !report.failed.isEmpty { issue = .putBackFailed(report.failed.count) }
        if !report.restored.isEmpty { spaceChanged(.putBack) }
        await refresh(folderPath: move.folderPath)
    }

    /// Re-walks one folder and puts the result into the tree (sizes of its parents follow).
    func refresh(folderPath: String) async {
        guard let tree, let index = tree.index(ofPath: folderPath) else { return }
        do {
            let fresh = try await walker.walk(URL(fileURLWithPath: folderPath))
            guard var updated = self.tree, updated.index(ofPath: folderPath) == index else { return }
            updated.graft(fresh, at: index)
            self.tree = updated
            // Stay in the deepest folder that still exists.
            if current >= UInt32(updated.count) || !isReachable(current, in: updated) { current = index }
            selection = selection.filter { isReachable($0, in: updated) }
            if let focused, !isReachable(focused, in: updated) { self.focused = nil }
            refreshCurrent()
        } catch {
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func isReachable(_ index: UInt32, in tree: SizeTree) -> Bool {
        guard index < UInt32(tree.count) else { return false }
        var node = index
        while let parent = tree.parent(of: node) {
            guard tree.children(of: parent).contains(node) else { return false }
            node = parent
        }
        return node == SizeTree.root
    }

    func ignore(_ index: UInt32) async {
        guard tree != nil, index != SizeTree.root else { return }
        do {
            try await store.ignore(path: path(index))
            ignore = await store.ignoreList()
            selection.remove(index)
            refreshCurrent()
        } catch {
            issue = .ignoreNotSaved
        }
    }

    func dismissIssue() { issue = nil }

    #if DEBUG
        /// Screenshot flows: draw this block as if the pointer were on it (hover card, trash button).
        var debugHover: UInt32?

        /// Screenshot flows: select these children of the current folder by name.
        func debugSelect(_ names: [String]) {
            guard let tree else { return }
            for name in names {
                if let child = tree.children(of: current).first(where: { tree.name($0) == name }) {
                    setSelected(child, true)
                }
            }
        }

        /// Screenshot flows: forget that the hint was used (in memory only).
        func debugResetHint() { hintSeen = false }

        /// Screenshot flows: drill along `names` from the root.
        func debugDrill(_ names: [String]) {
            guard let tree else { return }
            for name in names {
                guard let child = tree.children(of: current).first(where: { tree.name($0) == name }) else { return }
                drill(into: child)
            }
        }
    #endif
}
