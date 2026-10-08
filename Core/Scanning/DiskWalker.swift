import CDiskWalk
import Darwin
import Foundation
import os

/// How far a walk has got. Sent a few times a second.
struct WalkProgress: Sendable, Equatable {
    var files = 0
    var directories = 0
    var bytes: Int64 = 0
    var elapsed: TimeInterval = 0

    var filesPerSecond: Double { elapsed > 0 ? Double(files) / elapsed : 0 }
}

/// Fast, read-only size walk of a folder (or the whole startup disk) into a `SizeTree`.
///
/// Technique (after healeycodes.com's write-up on fast disk usage on macOS; no code taken):
/// - one `getattrlistbulk` call per ~128 KB of entries (name, type, device, file ID, link count,
///   allocated size), done by the small C helper `CDiskWalk`;
/// - directories listed in parallel by a `TaskGroup` with at most `activeProcessorCount × 2`
///   listings in flight; the tree is built by the single loop that collects the results;
/// - files with more than one hard link are counted once (inode set split into 64 locked shards);
/// - directories are opened `O_NOFOLLOW`, links are never followed, other volumes (mount points,
///   another `st_dev`) are not entered, and when walking `/` the firmlinked
///   `/System/Volumes/Data` copy and `/Volumes` are skipped;
/// - **ProtectedList places** become one `.protected` node: their size is measured by the same
///   parallel walk but no child nodes are kept (they can't be cleaned anyway);
/// - **without Full Disk Access**, folders macOS guards (`FullDiskAccessPaths.walkerRoots`) are
///   never opened (no privacy prompt) and become `.needsAccess` nodes of unknown size.
actor DiskWalker {
    private let home: String
    private let protectedList: ProtectedList
    private let hasFullDiskAccess: @Sendable () -> Bool
    let maxConcurrency: Int
    private let logger = Logger(subsystem: "app.dustpan", category: "spacemap")

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        protectedList: ProtectedList? = nil,
        hasFullDiskAccess: @escaping @Sendable () -> Bool,
        maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount * 2
    ) {
        self.home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.protectedList = protectedList ?? ProtectedList(home: home)
        self.hasFullDiskAccess = hasFullDiskAccess
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Walks `root` (links in its own path are resolved first). Throws `CancellationError` when
    /// the task is cancelled.
    func walk(_ root: URL, progress: (@Sendable (WalkProgress) -> Void)? = nil) async throws -> SizeTree {
        assertNotMainThread()
        let rootPath = PathTools.canonical(root.path) ?? root.standardizedFileURL.path
        let context = WalkContext(
            rootPath: rootPath, home: home, protectedList: protectedList, hasFullDiskAccess: hasFullDiskAccess())
        let started = Date()

        if context.isGuarded(rootPath) {
            return SizeTree(rootPath: rootPath, rootKind: .needsAccess)
        }
        let aggregateRoot = context.isProtected(rootPath)
        var tree = SizeTree(rootPath: rootPath, rootKind: aggregateRoot ? .protected : .directory, capacity: 1 << 14)
        var counters = WalkProgress()
        var lastReport = Date()
        var pending: [WorkItem] = [WorkItem(path: rootPath, node: SizeTree.root, aggregate: aggregateRoot)]
        let limit = maxConcurrency

        try await withThrowingTaskGroup(of: DirResult.self) { group in
            var running = 0
            while running < limit, let item = pending.popLast() {
                group.addTask { Self.list(item, context: context) }
                running += 1
            }
            while let result = try await group.next() {
                running -= 1
                try Task.checkCancellation()
                Self.collect(result, into: &tree, pending: &pending, counters: &counters)
                while running < limit, let item = pending.popLast() {
                    group.addTask { Self.list(item, context: context) }
                    running += 1
                }
                if let progress, counters.directories % 64 == 0 {
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.1 {
                        lastReport = now
                        counters.elapsed = now.timeIntervalSince(started)
                        progress(counters)
                    }
                }
            }
        }
        try Task.checkCancellation()
        tree.finalize()
        tree.fileCount = counters.files
        tree.directoryCount = counters.directories
        counters.elapsed = Date().timeIntervalSince(started)
        progress?(counters)
        logger.info(
            """
            Walk: \(counters.files, privacy: .public) files, \(counters.directories, privacy: .public) folders, \
            \(tree.totalSize, privacy: .public) bytes in \(counters.elapsed, privacy: .public) s
            """)
        return tree
    }

    // MARK: - Collecting (one at a time, on the actor)

    private static func collect(
        _ result: DirResult, into tree: inout SizeTree, pending: inout [WorkItem], counters: inout WalkProgress
    ) {
        let item = result.item
        counters.directories += 1
        switch result.status {
        case .ok: break
        case .partial:
            // Listed only partly (an error midway): keep what was read, but say so.
            if !item.aggregate { tree.setKind(.partial, at: item.node) }
        case .unreadable:
            if !item.aggregate { tree.setKind(.unreadable, at: item.node) }
            return
        case .otherVolume:
            if !item.aggregate { tree.setKind(.otherVolume, at: item.node) }
            return
        case .cancelled: return
        }
        counters.files += result.fileCount
        counters.bytes += result.bytes
        if item.aggregate {
            tree.addSize(result.bytes, to: item.node)
            for name in result.childNames(where: { $0.kind == .directory || $0.kind == .protected }) {
                pending.append(WorkItem(path: join(item.path, name), node: item.node, aggregate: true))
            }
            return
        }
        result.names.withUnsafeBufferPointer { names in
            for child in result.children {
                let bytes = names[Int(child.nameStart)..<Int(child.nameStart + child.nameLength)]
                let kind = child.kind
                var fileKind: FileKind? = child.fileKind
                var name: String?
                if kind == .directory || kind == .protected {
                    let text = String(decoding: bytes, as: UTF8.self)
                    name = text
                    fileKind = FileKind.forDirectory(name: text)
                }
                let index = tree.append(
                    name: bytes, parent: item.node, kind: kind, size: child.size, fileKind: fileKind)
                if let name, kind == .directory || kind == .protected {
                    pending.append(WorkItem(path: join(item.path, name), node: index, aggregate: kind == .protected))
                }
            }
        }
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    // MARK: - Listing (in parallel, off the actor)

    struct WorkItem: Sendable {
        let path: String
        let node: UInt32
        /// Inside a protected place: add sizes to `node`, keep no child nodes.
        let aggregate: Bool
    }

    struct ChildEntry: Sendable {
        var nameStart: UInt32
        var nameLength: UInt32
        var size: Int64
        var kind: SizeTree.Kind
        var fileKind: FileKind
    }

    struct DirResult: Sendable {
        enum Status: Sendable { case ok, partial, unreadable, otherVolume, cancelled }
        let item: WorkItem
        var status: Status = .ok
        var names: [UInt8] = []
        var children: [ChildEntry] = []
        /// Allocated bytes of the files directly inside (hard links counted once).
        var bytes: Int64 = 0
        var fileCount = 0

        func childNames(where include: (ChildEntry) -> Bool) -> [String] {
            names.withUnsafeBufferPointer { names in
                children.filter(include).map {
                    String(decoding: names[Int($0.nameStart)..<Int($0.nameStart + $0.nameLength)], as: UTF8.self)
                }
            }
        }
    }

    /// Lists one directory with `getattrlistbulk` and decides what each child is.
    static func list(_ item: WorkItem, context: WalkContext) -> DirResult {
        var result = DirResult(item: item)
        if Task.isCancelled {
            result.status = .cancelled
            return result
        }
        var listing = dw_listing()
        defer { dw_listing_free(&listing) }
        var device: Int32 = 0
        let error = item.path.withCString { dw_list_directory($0, &listing, &device) }
        if error != 0 && listing.count == 0 {
            result.status = .unreadable
            return result
        }
        guard context.allowedDevices.contains(device) else {
            result.status = .otherVolume
            return result
        }
        let count = Int(listing.count)
        guard count > 0, let entries = listing.entries, let rawNames = listing.names else { return result }

        result.names = Array(
            UnsafeRawBufferPointer(start: UnsafeRawPointer(rawNames), count: Int(listing.names_length)))
        result.children.reserveCapacity(count)
        let lowerPath = item.path.lowercased()
        let watched = context.watchParents.contains(lowerPath)
        let inLibrary = context.guardsLibrary && PathTools.isInside(lowerPath, root: context.libraryPath)

        for i in 0..<count {
            let entry = entries[i]
            var kind: SizeTree.Kind
            var size = entry.alloc_size
            var fileKind = FileKind.other
            switch Int(entry.type) {
            case Int(DW_FILE):
                kind = .file
                result.fileCount += 1
                if entry.link_count > 1, !context.inodes.insert(device: entry.device, fileID: entry.file_id) {
                    size = 0
                }
                fileKind = Self.fileKind(
                    names: result.names, start: Int(entry.name_offset), length: Int(entry.name_length))
            case Int(DW_DIR):
                kind = .directory
                if entry.flags & UInt8(DW_FLAG_MOUNTPOINT) != 0 || !context.allowedDevices.contains(entry.device) {
                    kind = .otherVolume
                    size = 0
                }
            case Int(DW_LINK):
                kind = .link
                result.fileCount += 1
            default:
                kind = .other
            }
            if entry.flags & UInt8(DW_FLAG_ERROR) != 0 { size = 0 }

            if watched || inLibrary, kind == .directory {
                let name = String(
                    decoding: result.names[Int(entry.name_offset)..<Int(entry.name_offset + entry.name_length)],
                    as: UTF8.self)
                let path = item.path == "/" ? "/" + name : item.path + "/" + name
                if context.isSkipped(path) { continue }
                if context.isGuarded(path) || (inLibrary && context.isGuardedInLibrary(name: name, parent: lowerPath)) {
                    if item.aggregate { continue }
                    kind = .needsAccess
                    size = 0
                } else if context.isProtected(path) {
                    kind = .protected
                }
            }

            if kind == .file || kind == .link || kind == .other {
                result.bytes += size
            }
            if item.aggregate {
                // Only folders matter: their contents are added to the same node.
                if kind == .directory || kind == .protected {
                    result.children.append(
                        ChildEntry(
                            nameStart: entry.name_offset, nameLength: entry.name_length, size: 0, kind: kind,
                            fileKind: .other))
                }
                continue
            }
            result.children.append(
                ChildEntry(
                    nameStart: entry.name_offset, nameLength: entry.name_length,
                    size: (kind == .directory || kind == .protected) ? 0 : size, kind: kind, fileKind: fileKind))
        }
        if error != 0 { result.status = .partial }
        return result
    }

    /// File kind from the name's extension (ASCII, up to 12 characters).
    private static func fileKind(names: [UInt8], start: Int, length: Int) -> FileKind {
        let end = start + length
        var dot = end - 1
        let lowest = max(start + 1, end - 13)
        while dot >= lowest, names[dot] != UInt8(ascii: ".") { dot -= 1 }
        guard dot >= lowest, dot < end - 1 else { return .other }
        var ext = ""
        for byte in names[(dot + 1)..<end] {
            guard byte < 0x80 else { return .other }
            ext.unicodeScalars.append(Unicode.Scalar(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte))
        }
        return FileKind.forExtension(ext)
    }
}

/// Everything a listing task needs, shared read-only (plus the locked inode set).
final class WalkContext: Sendable {
    let rootPath: String
    let protectedList: ProtectedList
    let access: Bool
    /// Volumes the walk stays on.
    let allowedDevices: Set<Int32>
    /// Lowercased folders whose children need the guarded / protected / skip checks.
    let watchParents: Set<String>
    let home: String
    /// Lowercased `/var/folders` roots not opened without Full Disk Access.
    let tempRoots: [String]
    /// Lowercased absolute paths never entered (firmlink copies, other volumes).
    let skipPaths: Set<String>
    /// Lowercased `~/Library`. Without access the walker is stricter inside it (see
    /// `isGuardedInLibrary`).
    let libraryPath: String
    var guardsLibrary: Bool { !access }

    let inodes = ShardedInodeSet()

    init(rootPath: String, home: String, protectedList: ProtectedList, hasFullDiskAccess: Bool) {
        self.rootPath = rootPath
        self.protectedList = protectedList
        self.access = hasFullDiskAccess
        self.home = home
        let guarded =
            hasFullDiskAccess
            ? [] : FullDiskAccessPaths.walkerRoots.map { PathTools.expandTilde($0, home: home).lowercased() }
        let root = rootPath.lowercased()
        // Other apps' per-user temp and cache folders (`/var/folders/…`), unless the walk starts
        // inside them (a folder picked there, or a test fixture).
        let temps = ["/private/var/folders", "/var/folders"].filter { !PathTools.isInside(root, root: $0) }
        tempRoots = hasFullDiskAccess ? [] : temps
        libraryPath = (home + "/Library").lowercased()
        var skip: Set<String> = []
        var devices: Set<Int32> = []
        if let device = Self.device(of: rootPath) { devices.insert(device) }
        if rootPath == "/" {
            // The Data volume is reached through its firmlinks (/Users, /Applications, …); its
            // mount point would list everything a second time.
            if let data = Self.device(of: "/System/Volumes/Data") { devices.insert(data) }
            skip.insert("/system/volumes/data")
        }
        if !PathTools.isInside(root, root: "/volumes") { skip.insert("/volumes") }
        if !PathTools.isInside(root, root: "/system/volumes/data") { skip.insert("/system/volumes/data") }
        skipPaths = skip
        allowedDevices = devices

        var parents: Set<String> = []
        func addParents(of pattern: String) {
            var components = PathTools.components(pattern.lowercased())
            if let wildcard = components.firstIndex(where: PathTools.hasWildcard) {
                components = Array(components.prefix(wildcard + 1))
            }
            guard !components.isEmpty else { return }
            components.removeLast()
            parents.insert("/" + components.joined(separator: "/"))
        }
        for path in guarded + (hasFullDiskAccess ? [] : temps) { addParents(of: path) }
        for path in skip { addParents(of: path) }
        for path in protectedList.roots { addParents(of: path) }
        watchParents = parents
    }

    /// A folder not opened without Full Disk Access (`FullDiskAccessPaths.isGuardedWithoutAccess`,
    /// plus other apps' temp folders).
    func isGuarded(_ path: String) -> Bool {
        guard !access else { return false }
        let lower = path.lowercased()
        if tempRoots.contains(where: { PathTools.isInside(lower, root: $0) }) { return true }
        return FullDiskAccessPaths.isGuardedWithoutAccess(path, home: home)
    }

    /// The `~/Library` part of `isGuarded` for one child folder. `parent` is lowercased.
    func isGuardedInLibrary(name: String, parent: String) -> Bool {
        guard !access else { return false }
        return FullDiskAccessPaths.isGuardedInLibrary(name: name, parent: parent, library: libraryPath)
    }

    func isProtected(_ path: String) -> Bool { protectedList.isInsideProtectedRoot(path) }

    func isSkipped(_ path: String) -> Bool { skipPaths.contains(path.lowercased()) }

    static func device(of path: String) -> Int32? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info.st_dev
    }
}

/// Inodes of multiply-linked files already counted, split into 64 shards so parallel listings
/// rarely wait on each other.
final class ShardedInodeSet: Sendable {
    private struct Key: Hashable {
        let device: Int32
        let fileID: UInt64
    }

    private let shards: [OSAllocatedUnfairLock<Set<Key>>] = (0..<64).map { _ in OSAllocatedUnfairLock(initialState: [])
    }

    /// True when this is the first time the inode is seen.
    func insert(device: Int32, fileID: UInt64) -> Bool {
        let key = Key(device: device, fileID: fileID)
        let shard = Int((fileID ^ (fileID >> 17)) & 63)
        return shards[shard].withLock { $0.insert(key).inserted }
    }
}
