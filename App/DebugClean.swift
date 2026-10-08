#if DEBUG
    import AppKit
    import Foundation

    /// DEBUG only: a real-path self-test of the Cleaner that can only ever touch Dustpan's own
    /// throwaway folder `~/Library/Caches/app.dustpan.selftest`.
    ///
    /// - `-debugCleanPath <path> -debugOutput <file>`: scans the `~/Library/Caches` rules (and the
    ///   Trash rule, to measure it), finds that one item and cleans just it through the Junk model
    ///   (real Trash, real history database), so the space-changed signal runs as in the app.
    /// - `-debugUndoLog <id> -debugOutput <file>`: puts that log row back through History (only if
    ///   it belongs to the self-test folder).
    /// Both report the Trash tile and free space before and after (the Trash is only read, never
    /// emptied).
    /// Writes a JSON report to `<file>` and quits. Any other path is refused.
    @MainActor
    enum DebugClean {
        enum Request: Sendable {
            case clean(path: String, output: URL)
            case undo(logID: Int64, output: URL)
        }

        static let selfTestName = "app.dustpan.selftest"

        static var request: Request? {
            let defaults = UserDefaults.standard
            guard let output = defaults.string(forKey: "debugOutput").map({ URL(fileURLWithPath: $0) }) else {
                return nil
            }
            if let path = defaults.string(forKey: "debugCleanPath") { return .clean(path: path, output: output) }
            if let raw = defaults.string(forKey: "debugUndoLog"), let id = Int64(raw) {
                return .undo(logID: id, output: output)
            }
            return nil
        }

        struct Report: Encodable {
            var action: String
            var refused: String?
            var found = false
            var moved: [[String: String]] = []
            var skipped: [String] = []
            var restored: [Int64] = []
            var undoFailures: [String] = []
            var trashBytesBefore: Int64?
            var trashBytesAfter: Int64?
            var freeBytesBefore: Int64?
            var freeBytesAfter: Int64?
            var spaceChanges = 0
        }

        static func run(_ request: Request, appState: AppState) async {
            let selfTest =
                "\(PathTools.canonical(appState.home.path) ?? appState.home.path)/Library/Caches/\(selfTestName)"
            var report: Report
            let output: URL
            switch request {
            case .clean(let path, let out):
                output = out
                report = Report(action: "clean")
                guard PathTools.canonical(path)?.lowercased() == selfTest.lowercased() else {
                    report.refused = "Only \(selfTestName) may be cleaned by this test."
                    break
                }
                let access = await Task.detached { [permissions = appState.permissions] in
                    permissions.hasFullDiskAccess()
                }.value
                await appState.junk.scan(hasFullDiskAccess: access) {
                    $0.paths.contains("~/Library/Caches") || $0.category == .trash
                }
                guard
                    let item = appState.junk.allItems.first(where: { $0.url.path.lowercased() == selfTest.lowercased() }
                    )
                else { break }
                report.found = true
                await measure(appState, into: &report, before: true)
                appState.junk.debugSelectOnly([item.id])
                await appState.junk.confirmClean()
                await appState.spaceRefresh?.value
                await measure(appState, into: &report, before: false)
                guard let result = appState.junk.lastReport else { break }
                report.moved = result.moved.map {
                    [
                        "original": $0.original.path, "trashed": $0.trashed.path, "bytes": "\($0.bytes)",
                        "logID": $0.logID.map { "\($0)" } ?? "none",
                    ]
                }
                report.skipped = result.skipped.map { "\($0.url.lastPathComponent): \($0.reason.explanation)" }
            case .undo(let id, let out):
                output = out
                report = Report(action: "undo")
                let rows = (try? await appState.cleanupStore.logs(ids: [id])) ?? []
                guard let row = rows.first, row.originalPath.lowercased() == selfTest.lowercased() else {
                    report.refused = "Log \(id) is not the self-test folder."
                    break
                }
                let access = await Task.detached { [permissions = appState.permissions] in
                    permissions.hasFullDiskAccess()
                }.value
                await appState.junk.scan(hasFullDiskAccess: access) { $0.category == .trash }
                await measure(appState, into: &report, before: true)
                let history = appState.history
                await history.load()
                guard let entry = history.days.flatMap(\.entries).first(where: { $0.log.id == id }) else { break }
                await history.putBack(entry)
                await appState.spaceRefresh?.value
                await measure(appState, into: &report, before: false)
                await history.load()
                let after = history.days.flatMap(\.entries).first { $0.log.id == id }
                if case .restored = after?.status { report.restored = [id] }
                report.undoFailures = history.failures.map { "\($0.key): \($0.value.explanation)" }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: output)
            NSApp.terminate(nil)
        }

        /// The Junk Trash tile's bytes (nil without Full Disk Access) and free space right now.
        private static func measure(_ appState: AppState, into report: inout Report, before: Bool) async {
            if before { await appState.disk.refresh() }
            let trash = appState.junk.result(for: .trash)?.totalBytes
            let free = appState.disk.space?.availableBytes
            if before {
                report.trashBytesBefore = trash
                report.freeBytesBefore = free
            } else {
                report.trashBytesAfter = trash
                report.freeBytesAfter = free
                report.spaceChanges = appState.spaceChanges
            }
        }
    }
#endif
