#if DEBUG
    import AppKit
    import Foundation

    /// DEBUG only. `-debugUpdatesAndExit <file>`: runs the real update checker over the installed
    /// apps (read-only; network: App Store lookups, apps' HTTPS feeds, Homebrew's cask list) and
    /// writes a JSON report, then quits. `-debugUpdatesFreshCasks YES` downloads the cask list into
    /// a temporary folder instead of the cache, to measure the download and decode.
    @MainActor
    enum DebugUpdates {
        static var outputURL: URL? {
            UserDefaults.standard.string(forKey: "debugUpdatesAndExit").map { URL(fileURLWithPath: $0) }
        }

        struct Row: Encodable {
            let name: String
            let bundleID: String
            let installed: String
            let available: String?
            let status: String
            let source: String?
            let brewToken: String?
            let open: String?
        }

        struct Report: Encodable {
            var appCount = 0
            var outdatedCount = 0
            var perSource: [String: [String: Int]] = [:]
            var cantCheckReasons: [String: Int] = [:]
            var outdated: [Row] = []
            var all: [Row] = []
            var offline = false
            var caskListDate: Date?
            var caskListStale = false
            var caskCount = 0
            var caskSeconds: Double?
            var caskFootprintBeforeMB: Double?
            var caskFootprintAfterMB: Double?
            var caskPeakFootprintMB: Double?
            var caskCacheBytes: Int?
            /// `-debugCaskFile <path>`: decoding a local copy of cask.json on its own.
            var localParseSeconds: Double?
            var localParseFootprintBeforeMB: Double?
            var localParseFootprintAfterMB: Double?
            var localParsePeakMB: Double?
            var seconds: [String: Double] = [:]
        }

        static func run(writingTo output: URL, appState: AppState) async {
            let clock = ContinuousClock()
            var report = Report()
            let scanner = AppScanner(roots: AppScanner.defaultRoots(home: appState.home))
            var start = clock.now
            let identities = await scanner.identities()
            report.seconds["listApps"] = (clock.now - start).seconds
            let candidates = identities.map { UpdateCandidate(name: $0.name, bundleID: $0.bundleID, url: $0.url) }
            report.appCount = candidates.count

            let fresh = UserDefaults.standard.bool(forKey: "debugUpdatesFreshCasks")
            let cacheDirectory =
                fresh
                ? FileManager.default.temporaryDirectory.appendingPathComponent("DustpanCasks-\(UUID().uuidString)")
                : UpdateChecker.defaultCacheDirectory
            let checker = UpdateChecker(cacheDirectory: cacheDirectory)

            if let path = UserDefaults.standard.string(forKey: "debugCaskFile"),
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            {
                let before = DebugWalk.memory()
                let start = clock.now
                let index = await Task.detached { try? CaskIndex.fromAPI(data, fetchedAt: Date()) }.value
                report.localParseSeconds = (clock.now - start).seconds
                let after = DebugWalk.memory()
                report.localParseFootprintBeforeMB = Double(before.current) / 1_048_576
                report.localParseFootprintAfterMB = Double(after.current) / 1_048_576
                report.localParsePeakMB = Double(after.peak) / 1_048_576
                _ = index?.casks.count
            }

            // The cask list on its own first, for time and memory.
            let before = DebugWalk.memory()
            start = clock.now
            let (index, _) = await checker.loadCaskIndex()
            report.caskSeconds = (clock.now - start).seconds
            let after = DebugWalk.memory()
            report.caskFootprintBeforeMB = Double(before.current) / 1_048_576
            report.caskFootprintAfterMB = Double(after.current) / 1_048_576
            report.caskPeakFootprintMB = Double(after.peak) / 1_048_576
            report.caskCount = index?.casks.count ?? 0
            report.caskCacheBytes = (try? checker.caskCacheFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize

            start = clock.now
            let result = await checker.check(candidates)
            report.seconds["check"] = (clock.now - start).seconds
            report.offline = result.offline
            report.caskListDate = result.caskListDate
            report.caskListStale = result.caskListStale
            for update in result.updates {
                let row = Row(
                    name: update.app.name, bundleID: update.app.bundleID, installed: update.installedVersion,
                    available: update.availableVersion, status: describe(update.status),
                    source: update.source?.rawValue, brewToken: update.brewToken, open: describe(update.open))
                report.all.append(row)
                if update.isOutdated { report.outdated.append(row) }
                let source = update.source?.rawValue ?? "none"
                let status: String
                switch update.status {
                case .available: status = "outdated"
                case .upToDate: status = "upToDate"
                case .cantCheck(let reason):
                    status = "cantCheck"
                    report.cantCheckReasons[reason.rawValue, default: 0] += 1
                }
                report.perSource[source, default: [:]][status, default: 0] += 1
            }
            report.outdatedCount = report.outdated.count
            if fresh { try? FileManager.default.removeItem(at: cacheDirectory) }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(report).write(to: output)
            NSApp.terminate(nil)
        }

        private static func describe(_ status: UpdateStatus) -> String {
            switch status {
            case .available(let version): "available \(version)"
            case .upToDate: "upToDate"
            case .cantCheck(let reason): "cantCheck \(reason.rawValue)"
            }
        }

        private static func describe(_ target: UpdateOpenTarget?) -> String? {
            switch target {
            case .appStore(let url): "appStore \(url.absoluteString)"
            case .web(let url): "web \(url.absoluteString)"
            case .app(let url): "app \(url.lastPathComponent)"
            case nil: nil
            }
        }

        /// Made-up results for the demo apps (`-junkDemo YES`), for screenshots. No network.
        static func demoReport(apps: [AppRecord], offline: Bool = false) -> UpdateReport {
            func update(
                _ name: String, _ status: UpdateStatus, _ source: UpdateSource?, brew: String? = nil,
                open: (URL) -> UpdateOpenTarget?
            ) -> AppUpdate? {
                guard let app = apps.first(where: { $0.name == name }) else { return nil }
                return AppUpdate(
                    app: UpdateCandidate(name: app.name, bundleID: app.bundleID, url: app.url),
                    installedVersion: app.version, status: status, source: source, open: open(app.url),
                    brewToken: brew)
            }
            let store = URL(literal: "macappstore://apps.apple.com/app/id100000001")
            let site = URL(literal: "https://example.com/quarry")
            let updates: [AppUpdate?] = [
                update("Inkwell", .available("4.3"), .sparkle) { .app($0) },
                update("Quarry", .available("1.0.2"), .homebrew, brew: "quarry") { _ in .web(site) },
                update("Orbit Notes", .available("11.4"), .appStore) { _ in .appStore(store) },
                update("Tidepool", .upToDate, .appStore) { _ in .appStore(store) },
                update("Lumen", offline ? .cantCheck(.offline) : .cantCheck(.noSource), nil) { .app($0) },
                update("Paperboat", .cantCheck(.insecureFeed), .sparkle) { .app($0) },
            ]
            return UpdateReport(
                updates: updates.compactMap { $0 }, offline: offline, caskListDate: Date(), caskListStale: false,
                checkedAt: Date().addingTimeInterval(-120))
        }
    }

    extension Duration {
        fileprivate var seconds: Double {
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
    }
#endif
