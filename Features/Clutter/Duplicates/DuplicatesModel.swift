import AppKit
import Foundation
import Observation
import os

/// Duplicates: identical files in Downloads, Documents, Desktop and Pictures (plus folders the
/// user adds). Each group keeps one copy: nothing is ticked until "Select duplicates, keep
/// one", the keeper can never be ticked, and the Cleaner refuses to move a whole group anyway.
@Observable
@MainActor
final class DuplicatesModel {
    /// One folder to look in.
    struct Root: Identifiable, Equatable {
        let url: URL
        /// One of the four default folders (can't be removed, only skipped).
        let isDefault: Bool
        var id: String { url.path }
    }

    struct LastMove: Equatable {
        let count: Int
        let bytes: Int64
        let logIDs: [Int64]
        let deadline: Date
        /// The groups as they were, so Undo can show them again.
        let groups: [DuplicateGroup]
        let keepers: [String: URL]
    }

    static let undoWindow: TimeInterval = 30

    private(set) var roots: [Root]
    private(set) var groups: [DuplicateGroup] = []
    private(set) var hasScanned = false
    private(set) var isScanning = false
    private(set) var isMoving = false
    private(set) var progress = DuplicateProgress()
    private(set) var needsAccess: [URL] = []
    private(set) var seconds: TimeInterval?
    private(set) var filesSeen = 0
    /// Set while the list is a Sweep's, which looked in this one folder only.
    private(set) var sweptFolder: URL?
    /// Ticked copies (paths).
    private(set) var selection = Set<String>()
    /// The copy kept per group (group id → url); starts as the finder's suggestion.
    private(set) var keepers: [String: URL] = [:]
    var isConfirming = false
    private(set) var lastMove: LastMove?
    private(set) var issue: DustpanError?

    private let finder: DuplicateFinder
    private let cleaner: Cleaner
    /// Reports moves and put-backs to `AppState` (disk bar, Junk's Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }
    let home: URL
    private var scanTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.dustpan", category: "duplicates")

    init(finder: DuplicateFinder, cleaner: Cleaner, home: URL) {
        self.finder = finder
        self.cleaner = cleaner
        let canonical = URL(fileURLWithPath: PathTools.canonical(home.path) ?? home.path, isDirectory: true)
        self.home = canonical
        roots = DuplicateFinder.defaultRoots(home: canonical).map { Root(url: $0, isDefault: true) }
    }

    // MARK: - Folders

    /// Whether a folder may be added: inside the home folder, not in `~/Library` or the Trash
    /// (the Cleaner refuses files there, so nothing there should be listed).
    func isAllowedRoot(_ path: String) -> Bool {
        let home = home.path
        return PathTools.isStrictlyInside(path, root: home) && !PathTools.isInside(path, root: home + "/Library")
            && !PathTools.isInside(path, root: home + "/.Trash")
    }

    /// Adds a folder the user picked; refuses (with a quiet note) one that isn't allowed.
    func addRoot(_ url: URL) {
        let raw = url.standardizedFileURL.path
        let path = PathTools.canonical(raw) ?? raw
        guard isAllowedRoot(path) else {
            issue = .folderNotAllowed
            return
        }
        guard !roots.contains(where: { $0.url.path.lowercased() == path.lowercased() }) else { return }
        roots.append(Root(url: URL(fileURLWithPath: path, isDirectory: true), isDefault: false))
    }

    func removeRoot(_ root: Root) {
        guard !root.isDefault else { return }
        roots.removeAll { $0 == root }
    }

    /// Whether `root` is skipped because Full Disk Access is off (text check only).
    func rootNeedsAccess(_ root: Root, hasFullDiskAccess: Bool) -> Bool {
        !hasFullDiskAccess && FullDiskAccessPaths.isGuardedWithoutAccess(root.url.path, home: home.path)
    }

    func displayPath(_ url: URL) -> String {
        let path = url.path
        let home = home.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Scanning

    func scan() async {
        scanTask?.cancel()
        let task = Task { await runScan() }
        scanTask = task
        await task.value
    }

    func start() {
        scanTask?.cancel()
        scanTask = Task { await runScan() }
    }

    func cancel() { scanTask?.cancel() }

    private func runScan() async {
        isScanning = true
        issue = nil
        progress = DuplicateProgress()
        defer { isScanning = false }
        do {
            let result = try await finder.find(roots.map(\.url)) { [weak self] progress in
                Task { @MainActor in self?.progress = progress }
            }
            guard !Task.isCancelled else { return }
            show(result.groups)
            sweptFolder = nil
            needsAccess = result.needsAccess
            seconds = result.seconds
            filesSeen = result.filesSeen
            hasScanned = true
        } catch {
            // Cancelled: keep the previous groups.
        }
    }

    /// Whether the screen is free to take a Sweep's results.
    var canAdopt: Bool { !isScanning && !isMoving && !isConfirming && lastMove == nil }

    /// Shows a Sweep's results (one folder only), so the screen doesn't look again. `sweptFolder`
    /// names that folder until the next full look.
    func adopt(_ scan: DuplicateScan, folder: URL) {
        show(scan.groups)
        needsAccess = scan.needsAccess
        seconds = scan.seconds
        filesSeen = scan.filesSeen
        hasScanned = true
        sweptFolder = folder
    }

    private func show(_ groups: [DuplicateGroup]) {
        self.groups = groups
        keepers = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.keeper) })
        selection = []
    }

    // MARK: - Selection (never every copy of a group)

    func keeper(of group: DuplicateGroup) -> URL { keepers[group.id] ?? group.keeper }

    func isKeeper(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool { keeper(of: group) == file.url }

    func isSelected(_ file: DuplicateFile) -> Bool { selection.contains(file.id) }

    /// Ticks or unticks one copy. The keeper can't be ticked, and a tick that would leave no
    /// copy of the group unticked is refused.
    func setSelected(_ file: DuplicateFile, in group: DuplicateGroup, _ selected: Bool) {
        guard selected else {
            selection.remove(file.id)
            return
        }
        guard !isKeeper(file, in: group), group.files.contains(where: { $0.id == file.id }) else { return }
        let others = group.files.filter { $0.id != file.id }
        guard others.contains(where: { !selection.contains($0.id) }) else { return }
        selection.insert(file.id)
    }

    /// Keeps `file` instead of the current keeper (which is then unticked, like every copy).
    func keep(_ file: DuplicateFile, in group: DuplicateGroup) {
        guard group.files.contains(where: { $0.id == file.id }) else { return }
        keepers[group.id] = file.url
        selection.remove(file.id)
    }

    /// "Select duplicates, keep one": ticks every copy except each group's keeper.
    func selectDuplicatesKeepOne() {
        var next = Set<String>()
        for group in groups {
            let keeper = keeper(of: group)
            for file in group.files where file.url != keeper { next.insert(file.id) }
        }
        selection = next
    }

    func clearSelection() { selection = [] }

    /// Space the extra copies take, given the chosen keepers. With the suggested keepers this is
    /// `DuplicateScan.reclaimableBytes`, which the Sweep tile shows.
    var totalReclaimable: Int64 {
        groups.reduce(0) { total, group in
            let keeper = keeper(of: group)
            return total + group.files.filter { $0.url != keeper }.reduce(0) { $0 + $1.allocatedSize }
        }
    }

    var selectedCount: Int { selection.count }

    var selectedBytes: Int64 {
        groups.reduce(0) { total, group in
            total + group.files.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.allocatedSize }
        }
    }

    /// What the Cleaner gets: each ticked copy with its group's keeper.
    var removals: [DuplicateRemoval] {
        groups.flatMap { group in
            let keeper = keeper(of: group)
            return group.files.filter { selection.contains($0.id) && $0.url != keeper }.map {
                DuplicateRemoval(url: $0.url, keeper: keeper, hash: group.hash, size: group.size)
            }
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Moving

    func requestMove() {
        guard !removals.isEmpty, !isMoving else { return }
        isConfirming = true
    }

    func confirmMove() async {
        isConfirming = false
        let removals = removals
        guard !removals.isEmpty else { return }
        isMoving = true
        defer { isMoving = false }
        let before = groups
        let keepersBefore = keepers
        let report = await cleaner.trashDuplicates(removals)
        let moved = Set(report.moved.map(\.original.path))
        selection.subtract(removals.map(\.url.path))
        // Drop moved copies; a group with one copy left is no longer a group.
        groups = groups.compactMap { group in
            let left = group.files.filter { !moved.contains($0.url.path) }
            guard left.count > 1 else { return nil }
            return DuplicateGroup(hash: group.hash, size: group.size, files: left, keeper: keeper(of: group))
        }
        if let skipped = report.skipped.first {
            issue = .notMoved(skipped.reason.explanation)
        } else if report.logFailed {
            issue = .cleanupNotLogged
        }
        guard !report.moved.isEmpty else { return }
        spaceChanged(.movedToTrash)
        let deadline = Date().addingTimeInterval(Self.undoWindow)
        lastMove = LastMove(
            count: report.moved.count, bytes: report.freedBytes, logIDs: report.logIDs, deadline: deadline,
            groups: before, keepers: keepersBefore)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            if self?.lastMove?.deadline == deadline { self?.lastMove = nil }
        }
    }

    func undoLastMove() async {
        guard let move = lastMove else { return }
        lastMove = nil
        let report = await cleaner.undo(move.logIDs)
        if !report.failed.isEmpty { issue = .putBackFailed(report.failed.count) }
        if !report.restored.isEmpty { spaceChanged(.putBack) }
        // Show again the copies that are back in place.
        let current = Set(groups.flatMap(\.files).map(\.id))
        groups = await Self.restoredGroups(move.groups, current: current)
        keepers = move.keepers.filter { id, _ in groups.contains { $0.id == id } }
    }

    /// The groups as they are after Undo: copies still listed, or back unchanged on disk
    /// (checked off the main actor). Groups left with one copy are dropped.
    @concurrent
    private static func restoredGroups(_ groups: [DuplicateGroup], current: Set<String>) async -> [DuplicateGroup] {
        groups.compactMap { group in
            let present = group.files.filter { file in
                current.contains(file.id)
                    || FileFacts.read(file.url.path).map { $0.isSameFile(as: file.facts) } == true
            }
            guard present.count > 1 else { return nil }
            return DuplicateGroup(hash: group.hash, size: group.size, files: present, keeper: group.keeper)
        }
    }

    func dismissIssue() { issue = nil }
}
