import AppKit
import Foundation
import Observation
import os

/// Large & old: big files in the home folder not opened in months. Nothing is ticked until the
/// user ticks it; removal goes through `Cleaner.trashLargeFiles`, with Undo.
@Observable
@MainActor
final class LargeOldModel {
    /// The last move, undoable for `undoWindow` seconds.
    struct LastMove: Equatable {
        let count: Int
        let bytes: Int64
        let logIDs: [Int64]
        let deadline: Date
        /// What was moved, so Undo can list it again without looking again.
        let files: [LargeFile]
    }

    static let undoWindow: TimeInterval = 30

    private(set) var files: [LargeFile] = []
    private(set) var hasScanned = false
    private(set) var isScanning = false
    private(set) var isMoving = false
    private(set) var needsAccessCount = 0
    private(set) var seconds: TimeInterval?
    var filter = LargeOldFilter() {
        didSet { pruneSelection() }
    }
    private(set) var selection = Set<String>()
    /// The row the keyboard is on (space bar = Quick Look).
    var focusedID: String?
    var isConfirming = false
    private(set) var lastMove: LastMove?
    private(set) var issue: DustpanError?

    private let finder: LargeOldFinder
    private let cleaner: Cleaner
    /// Reports moves and put-backs to `AppState` (disk bar, Junk's Trash tile).
    var spaceChanged: (SpaceChange) -> Void = { _ in }
    let home: URL
    private let now: () -> Date
    private var scanTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.dustpan", category: "largeold")

    init(finder: LargeOldFinder, cleaner: Cleaner, home: URL, now: @escaping () -> Date = { Date() }) {
        self.finder = finder
        self.cleaner = cleaner
        self.home = URL(fileURLWithPath: PathTools.canonical(home.path) ?? home.path, isDirectory: true)
        self.now = now
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
        defer { isScanning = false }
        do {
            let result = try await finder.find()
            guard !Task.isCancelled else { return }
            files = result.files
            needsAccessCount = result.needsAccessCount
            seconds = result.seconds
            hasScanned = true
            pruneSelection()
        } catch {
            // Cancelled: keep the previous list.
        }
    }

    // MARK: - List

    /// Files matching the filters, biggest first.
    var visibleFiles: [LargeFile] { filter.matching(files, now: now()) }

    var visibleBytes: Int64 { LargeOldFilter.bytes(visibleFiles) }

    /// Whether the screen is free to take a Sweep's results.
    var canAdopt: Bool { !isScanning && !isMoving && !isConfirming }

    /// Shows a Sweep's results, so the screen doesn't look again.
    func adopt(_ scan: LargeOldScan) {
        files = scan.files
        needsAccessCount = scan.needsAccessCount
        seconds = scan.seconds
        hasScanned = true
        pruneSelection()
    }

    func isSelected(_ file: LargeFile) -> Bool { selection.contains(file.id) }

    func setSelected(_ file: LargeFile, _ selected: Bool) {
        guard visibleFiles.contains(where: { $0.id == file.id }) else { return }
        if selected { selection.insert(file.id) } else { selection.remove(file.id) }
    }

    var selectedFiles: [LargeFile] { visibleFiles.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.allocatedSize } }

    var allVisibleSelected: Bool {
        let visible = visibleFiles
        return !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
    }

    func setAllVisibleSelected(_ selected: Bool) {
        for file in visibleFiles {
            if selected { selection.insert(file.id) } else { selection.remove(file.id) }
        }
    }

    /// A filter never hides something that would still be moved.
    private func pruneSelection() {
        let visible = Set(visibleFiles.map(\.id))
        selection.formIntersection(visible)
        if let focusedID, !visible.contains(focusedID) { self.focusedID = nil }
    }

    func displayFolder(_ file: LargeFile) -> String {
        let folder = file.url.deletingLastPathComponent().path
        let home = home.path
        return folder == home || folder.hasPrefix(home + "/") ? "~" + folder.dropFirst(home.count) : folder
    }

    /// "Opened 8 months ago" / "Changed 2 years ago" / "Never opened".
    func ageText(_ file: LargeFile) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if let used = file.lastUsed, used >= file.modified {
            return "Opened " + formatter.localizedString(for: used, relativeTo: now())
        }
        return "Changed " + formatter.localizedString(for: file.modified, relativeTo: now())
    }

    func moveFocus(by offset: Int) {
        let visible = visibleFiles
        guard !visible.isEmpty else { return }
        let current =
            focusedID.flatMap { id in visible.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : visible.count)
        focusedID = visible[min(max(current + offset, 0), visible.count - 1)].id
    }

    var focusedFile: LargeFile? { focusedID.flatMap { id in visibleFiles.first { $0.id == id } } }

    func reveal(_ file: LargeFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    // MARK: - Moving

    func requestMove() {
        guard !selectedFiles.isEmpty, !isMoving else { return }
        isConfirming = true
    }

    func confirmMove() async {
        isConfirming = false
        let chosen = selectedFiles
        guard !chosen.isEmpty else { return }
        isMoving = true
        defer { isMoving = false }
        let report = await cleaner.trashLargeFiles(chosen.map(\.url))
        let moved = Set(report.moved.map(\.original.path))
        let movedFiles = files.filter { moved.contains($0.url.path) }
        files.removeAll { moved.contains($0.url.path) }
        selection.subtract(chosen.map(\.id))
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
            files: movedFiles)
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
        // List again what is back in its place.
        let back = await Self.present(move.files)
        files = (files + back).sorted { $0.allocatedSize > $1.allocatedSize }
    }

    /// The files that are back in place, checked off the main actor.
    @concurrent
    private static func present(_ files: [LargeFile]) async -> [LargeFile] {
        files.filter { FileFacts.read($0.url.path)?.isRegularFile == true }
    }

    func dismissIssue() { issue = nil }
}
