#if DEBUG
    import AppKit
    import Foundation

    /// DEBUG only. `-debugClutterAndExit <file> -debugClutterRoots <path>[,<path>…]` runs the real
    /// DuplicateFinder and LargeOldFinder (Spotlight + walker) on those folders only, with the real
    /// Full Disk Access state, writes a JSON report and quits. `-debugLargeMinMB <n>` lowers the
    /// Large & old size floor (default 100). Read-only: nothing is moved or deleted.
    @MainActor
    enum DebugClutter {
        struct Request {
            let output: URL
            let roots: [URL]
            let largeMinimumBytes: Int64
        }

        static var request: Request? {
            let defaults = UserDefaults.standard
            guard let output = defaults.string(forKey: "debugClutterAndExit"),
                let roots = defaults.string(forKey: "debugClutterRoots")
            else { return nil }
            let minMB = defaults.integer(forKey: "debugLargeMinMB")
            return Request(
                output: URL(fileURLWithPath: output),
                roots: roots.split(separator: ",").map {
                    URL(fileURLWithPath: NSString(string: String($0)).expandingTildeInPath, isDirectory: true)
                },
                largeMinimumBytes: Int64(minMB > 0 ? minMB : 100) * 1_048_576)
        }

        struct Report: Encodable {
            struct Group: Encodable {
                let size: Int64
                let copies: [String]
                let keeper: String
                let reclaimableBytes: Int64
            }
            struct Big: Encodable {
                let path: String
                let bytes: Int64
                let lastUsed: Date?
                let modified: Date
                let kind: String
            }
            var roots: [String]
            var fullDiskAccess: Bool
            var duplicateSeconds: Double = 0
            var filesSeen = 0
            var groupCount = 0
            var reclaimableBytes: Int64 = 0
            var needsAccess: [String] = []
            var topGroups: [Group] = []
            var largeSeconds: Double = 0
            var largeMinimumBytes: Int64
            var largeCount = 0
            var largeNeedsAccess = 0
            var largeTop: [Big] = []
            var peakPhysFootprintMB: Double = 0
            var error: String?
        }

        static func run(_ request: Request, appState: AppState) async {
            let permissions = appState.permissions
            let access = await Task.detached { permissions.hasFullDiskAccess() }.value
            var report = Report(
                roots: request.roots.map(\.path), fullDiskAccess: access,
                largeMinimumBytes: request.largeMinimumBytes)
            do {
                let duplicates = DuplicateFinder(home: appState.home, hasFullDiskAccess: { access })
                let scan = try await duplicates.find(request.roots)
                report.duplicateSeconds = scan.seconds
                report.filesSeen = scan.filesSeen
                report.groupCount = scan.groups.count
                report.reclaimableBytes = scan.reclaimableBytes
                report.needsAccess = scan.needsAccess.map(\.path)
                report.topGroups = scan.groups.prefix(15).map {
                    .init(
                        size: $0.size, copies: $0.urls.map(\.path), keeper: $0.keeper.path,
                        reclaimableBytes: $0.reclaimableBytes)
                }
                let large = LargeOldFinder(home: appState.home, hasFullDiskAccess: { access })
                let found = try await large.find(scopes: request.roots, minimumBytes: request.largeMinimumBytes)
                report.largeSeconds = found.seconds
                report.largeCount = found.files.count
                report.largeNeedsAccess = found.needsAccessCount
                report.largeTop = found.files.prefix(15).map {
                    .init(
                        path: $0.url.path, bytes: $0.allocatedSize, lastUsed: $0.lastUsed, modified: $0.modified,
                        kind: $0.kind.rawValue)
                }
            } catch {
                report.error = "\(error)"
            }
            report.peakPhysFootprintMB = Double(DebugWalk.memory().peak) / 1_048_576
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(report).write(to: request.output)
            NSApp.terminate(nil)
        }
    }
#endif
