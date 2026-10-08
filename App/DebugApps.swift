#if DEBUG
    import AppKit
    import Foundation

    /// DEBUG only. Real-machine checks for the Apps feature; each writes JSON and quits.
    ///
    /// - `-debugAppsAndExit <file>` (optional `-debugApps id1,id2,id3`): read-only. Lists installed
    ///   apps, leftovers for three apps (the three largest unless named) and the orphans.
    /// - `-debugUninstallBundleID app.dustpan.selftestapp -debugOutput <file>`: uninstalls the
    ///   self-test app with the real Cleaner, real Trash and real history. Any other ID is refused.
    /// - `-debugUndoLogs <id,id,…> -debugOutput <file>`: puts those rows back, only if every one is
    ///   an `app:app.dustpan.selftestapp` row.
    @MainActor
    enum DebugApps {
        enum Request: Sendable {
            case list(output: URL, bundleIDs: [String])
            case uninstall(bundleID: String, output: URL)
            case undo(ids: [Int64], output: URL)
        }

        static let selfTestBundleID = "app.dustpan.selftestapp"

        static var request: Request? {
            let defaults = UserDefaults.standard
            if let path = defaults.string(forKey: "debugAppsAndExit") {
                let ids = (defaults.string(forKey: "debugApps") ?? "").split(separator: ",").map(String.init)
                return .list(output: URL(fileURLWithPath: path), bundleIDs: ids)
            }
            guard let output = defaults.string(forKey: "debugOutput").map({ URL(fileURLWithPath: $0) }) else {
                return nil
            }
            if let id = defaults.string(forKey: "debugUninstallBundleID") {
                return .uninstall(bundleID: id, output: output)
            }
            if let raw = defaults.string(forKey: "debugUndoLogs") {
                return .undo(ids: raw.split(separator: ",").compactMap { Int64($0) }, output: output)
            }
            return nil
        }

        struct MatchReport: Encodable {
            let path: String
            let folder: String
            let reason: String
            let confidence: String
            let explanation: String
            let bytes: Int64
            let status: String
            let selectedByDefault: Bool
            let pathProtected: Bool
        }

        struct AppReport: Encodable {
            let name: String
            let bundleID: String
            let teamID: String?
            let version: String
            let path: String
            let bytes: Int64
            let lastUsed: Date?
            let unused6Months: Bool
        }

        struct LeftoverReport: Encodable {
            let bundleID: String
            let skippedFolders: [String]
            let matches: [MatchReport]
        }

        struct ListReport: Encodable {
            var fullDiskAccess = false
            var appCount = 0
            var appleBundleIDsListed: [String] = []
            var apps: [AppReport] = []
            var leftovers: [LeftoverReport] = []
            var orphanCount = 0
            var orphanBytes: Int64 = 0
            var orphanSkippedFolders: [String] = []
            var orphanProtectedPaths = 0
            var orphanSample: [MatchReport] = []
            var seconds: [String: Double] = [:]
        }

        struct ActionReport: Encodable {
            var action: String
            var refused: String?
            var moved: [[String: String]] = []
            var skipped: [String] = []
            var restored: [Int64] = []
            var undoFailures: [String] = []
        }

        static func run(_ request: Request, appState: AppState) async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let access = await Task.detached { [permissions = appState.permissions] in
                permissions.hasFullDiskAccess()
            }.value
            switch request {
            case .list(let output, let ids):
                let report = await list(appState: appState, access: access, bundleIDs: ids)
                try? encoder.encode(report).write(to: output)
            case .uninstall(let bundleID, let output):
                let report = await uninstall(bundleID: bundleID, appState: appState, access: access)
                try? encoder.encode(report).write(to: output)
            case .undo(let ids, let output):
                let report = await undo(ids: ids, appState: appState)
                try? encoder.encode(report).write(to: output)
            }
            NSApp.terminate(nil)
        }

        private static func matchReport(_ match: LeftoverMatch, protectedList: ProtectedList) -> MatchReport {
            MatchReport(
                path: match.url.path, folder: match.folderTitle, reason: match.reason.rawValue,
                confidence: "\(match.confidence)", explanation: match.explanation, bytes: match.size,
                status: match.status.rawValue, selectedByDefault: match.isSelectedByDefault,
                pathProtected: protectedList.isProtectedPath(match.url.path))
        }

        private static func list(appState: AppState, access: Bool, bundleIDs: [String]) async -> ListReport {
            var report = ListReport()
            report.fullDiskAccess = access
            let clock = ContinuousClock()
            let home = appState.home
            let scanner = AppScanner(roots: AppScanner.defaultRoots(home: home))
            var start = clock.now
            let apps = await scanner.installedApps()
            report.seconds["installedApps"] = (clock.now - start).seconds
            report.appCount = apps.count
            report.appleBundleIDsListed = apps.map(\.bundleID).filter(AppScanner.isAppleBundleID)
            report.apps = apps.map {
                AppReport(
                    name: $0.name, bundleID: $0.bundleID, teamID: $0.teamID, version: $0.version, path: $0.url.path,
                    bytes: $0.size, lastUsed: $0.lastUsed, unused6Months: $0.isUnused())
            }
            let matcher = LeftoverMatcher(home: home, hasFullDiskAccess: access)
            let protectedList = ProtectedList(home: home)
            let chosen =
                bundleIDs.isEmpty
                ? Array(apps.sorted { $0.size > $1.size }.prefix(3))
                : apps.filter { bundleIDs.contains($0.bundleID) }
            let installed = apps.map(\.identity)
            start = clock.now
            for app in chosen {
                let identity = app.identity
                let scan = await Task.detached { matcher.leftovers(for: identity, installed: installed) }.value
                report.leftovers.append(
                    LeftoverReport(
                        bundleID: app.bundleID, skippedFolders: scan.skippedFolders,
                        matches: scan.matches.map { matchReport($0, protectedList: protectedList) }))
            }
            report.seconds["leftovers3"] = (clock.now - start).seconds
            start = clock.now
            let identities = await scanner.identities()
            let orphans = await Task.detached {
                matcher.orphans(installed: identities, isKnownApp: { LaunchServicesApps.isKnown($0) })
            }.value
            report.seconds["orphans"] = (clock.now - start).seconds
            report.orphanCount = orphans.matches.count
            report.orphanBytes = orphans.matches.reduce(0) { $0 + $1.size }
            report.orphanSkippedFolders = orphans.skippedFolders
            report.orphanProtectedPaths = orphans.matches.filter { protectedList.isProtectedPath($0.url.path) }.count
            report.orphanSample = orphans.matches.prefix(25).map { matchReport($0, protectedList: protectedList) }
            return report
        }

        private static func uninstall(bundleID: String, appState: AppState, access: Bool) async -> ActionReport {
            var report = ActionReport(action: "uninstall")
            guard bundleID == selfTestBundleID else {
                report.refused = "Only \(selfTestBundleID) may be uninstalled by this test."
                return report
            }
            let home = appState.home
            let scanner = AppScanner(roots: AppScanner.defaultRoots(home: home))
            let apps = await scanner.installedApps()
            guard let app = apps.first(where: { $0.bundleID == selfTestBundleID }) else {
                report.refused = "\(selfTestBundleID) is not installed."
                return report
            }
            let matcher = LeftoverMatcher(home: home, hasFullDiskAccess: access)
            let installed = apps.map(\.identity)
            let scan = await Task.detached { matcher.leftovers(for: app.identity, installed: installed) }.value
            // Double restriction: only entries literally named after the self-test ID.
            let leftovers = scan.matches.filter {
                $0.isRemovable && $0.url.lastPathComponent.lowercased().hasPrefix(selfTestBundleID)
            }
            let result = await appState.cleaner.uninstall(app: app, leftovers: leftovers)
            report.moved = result.moved.map {
                [
                    "original": $0.original.path, "trashed": $0.trashed.path, "bytes": "\($0.bytes)",
                    "isApp": "\($0.isApp)", "logID": $0.logID.map { "\($0)" } ?? "none",
                ]
            }
            report.skipped = result.skipped.map { "\($0.url.path): \($0.reason.explanation)" }
            return report
        }

        private static func undo(ids: [Int64], appState: AppState) async -> ActionReport {
            var report = ActionReport(action: "undo")
            let rows = (try? await appState.cleanupStore.logs(ids: ids)) ?? []
            guard !ids.isEmpty, rows.count == ids.count,
                rows.allSatisfy({ $0.ruleID == "app:\(selfTestBundleID)" })
            else {
                report.refused = "Every row must be an app:\(selfTestBundleID) row."
                return report
            }
            let undo = await appState.cleaner.undo(ids)
            report.restored = undo.restored
            report.undoFailures = undo.failed.map { "\($0.key): \($0.value.explanation)" }
            return report
        }
    }

    extension Duration {
        fileprivate var seconds: Double {
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
#endif
