#if DEBUG
    import AppKit
    import Darwin
    import Foundation

    /// DEBUG only. `-debugWalkAndExit <path> -debugOutput <file>` walks `<path>` with the real
    /// DiskWalker (read-only, real Full Disk Access state, so guarded folders are skipped without
    /// it), writes a JSON report and quits. `-debugCompare <path>[,<path>…]` adds the walked size
    /// of those folders (for comparing with `du -sk`). Nothing is moved or deleted.
    @MainActor
    enum DebugWalk {
        struct Request {
            let root: URL
            let output: URL
            let compare: [String]
        }

        static var request: Request? {
            let defaults = UserDefaults.standard
            guard let root = defaults.string(forKey: "debugWalkAndExit"),
                let output = defaults.string(forKey: "debugOutput")
            else { return nil }
            let compare = (defaults.string(forKey: "debugCompare") ?? "").split(separator: ",").map(String.init)
            return Request(
                root: URL(fileURLWithPath: root), output: URL(fileURLWithPath: output), compare: compare)
        }

        struct Report: Encodable {
            struct Node: Encodable {
                let path: String
                let bytes: Int64
                let kind: String
            }
            var root: String
            var fullDiskAccess: Bool
            var seconds: Double = 0
            var files = 0
            var directories = 0
            var nodes = 0
            var totalBytes: Int64 = 0
            var filesPerSecond: Double = 0
            var treeEstimatedMB: Double = 0
            var physFootprintMB: Double = 0
            var peakPhysFootprintMB: Double = 0
            var needsAccess: [String] = []
            var protected: [Node] = []
            var otherVolumes: [String] = []
            var unreadable = 0
            var partial = 0
            var top: [Node] = []
            var compare: [Node] = []
            var error: String?
        }

        static func run(_ request: Request, appState: AppState) async {
            let permissions = appState.permissions
            let access = await Task.detached { permissions.hasFullDiskAccess() }.value
            var report = Report(root: request.root.path, fullDiskAccess: access)
            let walker = DiskWalker(home: appState.home, hasFullDiskAccess: { access })
            let started = Date()
            do {
                let tree = try await walker.walk(request.root)
                report.seconds = Date().timeIntervalSince(started)
                report.files = tree.fileCount
                report.directories = tree.directoryCount
                report.nodes = tree.count
                report.totalBytes = tree.totalSize
                report.filesPerSecond = Double(tree.fileCount) / max(report.seconds, 0.001)
                report.treeEstimatedMB = Double(tree.estimatedBytes) / 1_048_576
                report.needsAccess = tree.nodes(ofKind: .needsAccess).map { tree.path($0) }.sorted()
                report.protected = tree.nodes(ofKind: .protected).map {
                    .init(path: tree.path($0), bytes: tree.size($0), kind: "protected")
                }
                report.otherVolumes = tree.nodes(ofKind: .otherVolume).map { tree.path($0) }
                report.unreadable = tree.nodes(ofKind: .unreadable).count
                report.partial = tree.nodes(ofKind: .partial).count
                report.top = tree.topChildren(of: SizeTree.root, limit: 15).map {
                    .init(path: tree.path($0), bytes: tree.size($0), kind: "\(tree.kind($0))")
                }
                report.compare = request.compare.map { path in
                    let canonical = PathTools.canonical(path) ?? path
                    let index = tree.index(ofPath: canonical)
                    return .init(
                        path: canonical, bytes: index.map { tree.size($0) } ?? -1,
                        kind: index.map { "\(tree.kind($0))" } ?? "missing")
                }
            } catch {
                report.error = "\(error)"
            }
            let memory = Self.memory()
            report.physFootprintMB = Double(memory.current) / 1_048_576
            report.peakPhysFootprintMB = Double(memory.peak) / 1_048_576
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: request.output)
            NSApp.terminate(nil)
        }

        /// phys_footprint now and its peak (`task_vm_info`).
        static func memory() -> (current: UInt64, peak: UInt64) {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return (0, 0) }
            return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
        }
    }
#endif
