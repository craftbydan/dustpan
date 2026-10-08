#if DEBUG
    import AppKit
    import Foundation

    /// DEBUG only. With `-debugScanAndExit <file>`, the app runs the junk scanner on this Mac,
    /// writes a JSON report (per-category totals and every item) to `<file>`, then quits.
    /// Read-only: nothing is moved or deleted. Without Full Disk Access the scanner skips rules
    /// that need it (Trash, Downloads, Desktop, other apps' containers), so the run never stops
    /// at a permission dialog; the report lists them under `skippedForAccess`.
    @MainActor
    enum DebugScan {
        static var outputURL: URL? {
            UserDefaults.standard.string(forKey: "debugScanAndExit").map { URL(fileURLWithPath: $0) }
        }

        static func run(writingTo output: URL, model: JunkModel, hasFullDiskAccess: Bool) async {
            let started = Date()
            await model.scan(hasFullDiskAccess: hasFullDiskAccess)
            let skipped = model.skipped
            let skippedCategories = model.skippedCategories.map(\.rawValue)
            let protectedList = ProtectedList()
            let results = model.results
            let report = await Task.detached {
                let items = results.flatMap(\.items)
                let protectedHits = items.filter { protectedList.isProtected($0.url) }.map(\.url.path)
                return Report(
                    seconds: Date().timeIntervalSince(started),
                    issue: nil,
                    fullDiskAccess: hasFullDiskAccess,
                    skippedForAccess: skipped.map {
                        .init(ruleID: $0.ruleID, title: $0.title, category: $0.category.rawValue)
                    },
                    skippedCategories: skippedCategories,
                    totals: results.map {
                        .init(category: $0.category.rawValue, items: $0.items.count, bytes: $0.totalBytes)
                    },
                    protectedHits: protectedHits,
                    items: items.map {
                        .init(
                            path: $0.url.path, bytes: $0.allocatedSize, ruleID: $0.ruleID, risk: $0.risk.rawValue,
                            selected: $0.isSelected, excluded: $0.excludedURLs.map(\.path))
                    })
            }.value
            var final = report
            final.issue = model.issue?.localizedDescription
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(final).write(to: output)
            NSApp.terminate(nil)
        }

        struct Report: Encodable, Sendable {
            struct Total: Encodable, Sendable {
                let category: String
                let items: Int
                let bytes: Int64
            }
            struct Item: Encodable, Sendable {
                let path: String
                let bytes: Int64
                let ruleID: String
                let risk: String
                let selected: Bool
                let excluded: [String]
            }
            struct Skipped: Encodable, Sendable {
                let ruleID: String
                let title: String
                let category: String
            }
            let seconds: TimeInterval
            var issue: String?
            let fullDiskAccess: Bool
            /// Rules not run because Full Disk Access is off.
            let skippedForAccess: [Skipped]
            let skippedCategories: [String]
            let totals: [Total]
            /// Items the full `ProtectedList.isProtected` check flags. Must be empty.
            let protectedHits: [String]
            let items: [Item]
        }
    }
#endif
