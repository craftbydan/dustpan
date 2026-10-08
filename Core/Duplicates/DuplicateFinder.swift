import Darwin
import Foundation
import os

/// One copy in a duplicate group.
struct DuplicateFile: Sendable, Hashable, Identifiable {
    let url: URL
    let facts: FileFacts
    var id: String { url.path }
    var allocatedSize: Int64 { facts.allocated }
    var created: Date { facts.created }
    var modified: Date { facts.modified }

    static func == (a: DuplicateFile, b: DuplicateFile) -> Bool { a.url == b.url && a.facts == b.facts }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Files with exactly the same content (same length, same XXH3 of every byte), each a
/// different file on disk (hard links of one file are never a group).
struct DuplicateGroup: Sendable, Identifiable, Equatable {
    /// XXH3-64 of the whole content.
    let hash: UInt64
    /// Logical length of each copy.
    let size: Int64
    /// Every copy, the suggested keeper first.
    let files: [DuplicateFile]
    /// The copy Dustpan suggests keeping (`DuplicateFinder.suggestKeeper`).
    let keeper: URL

    var id: String { String(hash, radix: 16) + "-" + String(size) }
    var urls: [URL] { files.map(\.url) }
    /// Space the copies other than the keeper take.
    var reclaimableBytes: Int64 {
        files.filter { $0.url != keeper }.reduce(0) { $0 + $1.allocatedSize }
    }
}

struct DuplicateProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case listing, comparing }
    var phase: Phase = .listing
    var filesSeen = 0
    /// Files that share their length with another file (the only ones read).
    var candidates = 0
    var bytesRead: Int64 = 0
    var bytesToRead: Int64 = 0

    var fraction: Double {
        guard phase == .comparing, bytesToRead > 0 else { return 0 }
        return min(Double(bytesRead) / Double(bytesToRead), 1)
    }
}

struct DuplicateScan: Sendable, Equatable {
    var groups: [DuplicateGroup] = []
    /// Chosen folders not looked in because Full Disk Access is off.
    var needsAccess: [URL] = []
    var filesSeen = 0
    var seconds: TimeInterval = 0

    var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
}

/// Finds files with identical content in the chosen folders.
///
/// Pipeline (the size → partial hash → full hash idea of jdupes, MIT; no code taken):
/// regular files ≥ `minimumSize` → group by length → XXH3 of the first 16 KB → of the last 16 KB
/// → streaming XXH3 of the whole file in 1 MB reads → groups of two or more.
///
/// Never looked at: links (never followed), packages (`.app`, `.photoslibrary`, any folder
/// macOS treats as one item) and tool folders (`node_modules`, `.git`, …), hidden files,
/// ProtectedList places, app database files, cloud placeholders (dataless or not downloaded —
/// checked from `lstat` and resource values, so nothing downloads), and — without Full Disk
/// Access — every folder `FullDiskAccessPaths.isGuardedWithoutAccess` covers (not even listed).
/// Hard links of one file count once. Files are opened with `O_NOFOLLOW_ANY`.
actor DuplicateFinder {
    static let minimumSize: Int64 = 100 * 1_024

    let home: String
    private let protectedList: ProtectedList
    private let hasFullDiskAccess: @Sendable () -> Bool
    private let cloud: any CloudStatusChecking
    private let minimumSize: Int64
    private let logger = Logger(subsystem: "app.dustpan", category: "duplicates")

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        protectedList: ProtectedList? = nil,
        hasFullDiskAccess: @escaping @Sendable () -> Bool,
        cloud: any CloudStatusChecking = SystemCloudStatus(),
        minimumSize: Int64 = DuplicateFinder.minimumSize
    ) {
        self.home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.protectedList = protectedList ?? ProtectedList(home: home)
        self.hasFullDiskAccess = hasFullDiskAccess
        self.cloud = cloud
        self.minimumSize = minimumSize
    }

    /// Downloads, Documents, Desktop and Pictures.
    static func defaultRoots(home: URL) -> [URL] {
        ["Downloads", "Documents", "Desktop", "Pictures"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: - Finding

    func find(
        _ roots: [URL], progress: (@Sendable (DuplicateProgress) -> Void)? = nil
    ) async throws
        -> DuplicateScan
    {
        assertNotMainThread()
        let started = Date()
        let access = hasFullDiskAccess()
        var scan = DuplicateScan()
        var counters = DuplicateProgress()
        var reporter = ProgressReporter(send: progress)

        // 1. List: every regular file big enough, by length.
        var bySize: [Int64: [String]] = [:]
        var visited = Set<String>()
        for root in Self.withoutNested(roots.map { Self.normalized($0.path) }.compactMap { $0 }) {
            if !access && FullDiskAccessPaths.isGuardedWithoutAccess(root, home: home) {
                scan.needsAccess.append(URL(fileURLWithPath: root, isDirectory: true))
                continue
            }
            // A chosen folder with a link anywhere on its path is refused (checked top-down with
            // lstat, so a link is never followed into a guarded folder).
            // Inside-only: a root that merely *holds* a protected place (`~/Pictures` with a
            // Photos library) is still listed; the protected place itself is skipped below.
            guard Self.isLinkFree(root), !protectedList.isInsideProtectedRoot(root) else { continue }
            try list(
                root, access: access, bySize: &bySize, visited: &visited, counters: &counters,
                reporter: &reporter)
        }
        scan.filesSeen = counters.filesSeen

        // 2. Only lengths shared by two or more files; one entry per file on disk.
        var candidates: [[Candidate]] = []
        let databaseFolders = DatabaseFolderCheck(home: home, protectedList: protectedList)
        for (_, paths) in bySize where paths.count > 1 {
            try Task.checkCancellation()
            var seen = Set<FileFacts.FileID>()
            var group: [Candidate] = []
            for path in paths {
                guard let facts = FileFacts.read(path), facts.isRegularFile, facts.size >= minimumSize else { continue }
                guard seen.insert(facts.fileID).inserted else { continue }
                if cloud.isCloudOnly(URL(fileURLWithPath: path), facts: facts) { continue }
                // In a folder holding an app database (safety rule 2): never offered.
                if databaseFolders.isInsideDatabaseFolder(path) { continue }
                group.append(Candidate(path: path, facts: facts))
            }
            if group.count > 1 { candidates.append(group) }
        }
        counters.phase = .comparing
        counters.candidates = candidates.reduce(0) { $0 + $1.count }
        counters.bytesToRead = candidates.reduce(0) { total, group in
            total + group.reduce(0) { $0 + $1.facts.size }
        }
        reporter.report(counters, force: true)

        // 3. First 16 KB, last 16 KB, then everything.
        var groups: [DuplicateGroup] = []
        for group in candidates {
            try Task.checkCancellation()
            let readBefore = counters.bytesRead
            let byFirst = refine(group) { FileContent.sampleHash($0.path, facts: $0.facts, fromEnd: false) }
            for first in byFirst {
                let byLast = refine(first) { FileContent.sampleHash($0.path, facts: $0.facts, fromEnd: true) }
                for last in byLast {
                    var hashes: [UInt64: [Candidate]] = [:]
                    for candidate in last {
                        try Task.checkCancellation()
                        if let hash = try FileContent.fullHash(candidate.path, facts: candidate.facts) {
                            hashes[hash, default: []].append(candidate)
                        }
                        counters.bytesRead += candidate.facts.size
                        reporter.report(counters)
                    }
                    for (hash, same) in hashes where same.count > 1 {
                        groups.append(makeGroup(hash: hash, same))
                    }
                }
            }
            // Files dropped after a sample count as done for the progress bar.
            counters.bytesRead = readBefore + group.reduce(0) { $0 + $1.facts.size }
        }
        counters.bytesRead = counters.bytesToRead
        reporter.report(counters, force: true)

        scan.groups = groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        scan.seconds = Date().timeIntervalSince(started)
        logger.info(
            """
            Duplicates: \(scan.filesSeen, privacy: .public) files, \(counters.candidates, privacy: .public) \
            candidates, \(scan.groups.count, privacy: .public) groups in \(scan.seconds, privacy: .public) s
            """)
        return scan
    }

    struct Candidate: Sendable {
        let path: String
        let facts: FileFacts
    }

    /// Splits `group` by `key`, keeping only sub-groups of two or more. Unreadable files drop out.
    private func refine(_ group: [Candidate], key: (Candidate) -> UInt64?) -> [[Candidate]] {
        var buckets: [UInt64: [Candidate]] = [:]
        for candidate in group {
            if let value = key(candidate) { buckets[value, default: []].append(candidate) }
        }
        return buckets.values.filter { $0.count > 1 }
    }

    private func makeGroup(hash: UInt64, _ same: [Candidate]) -> DuplicateGroup {
        let files = same.map { DuplicateFile(url: URL(fileURLWithPath: $0.path), facts: $0.facts) }
        let keeper = Self.suggestKeeper(files, home: home) ?? files[0]
        let ordered = [keeper] + files.filter { $0.url != keeper.url }.sorted { $0.url.path < $1.url.path }
        return DuplicateGroup(hash: hash, size: same[0].facts.size, files: ordered, keeper: keeper.url)
    }

    /// Lists `root` depth-first without following links. Folders are opened one at a time, and
    /// only after they passed every check.
    private func list(
        _ root: String, access: Bool, bySize: inout [Int64: [String]], visited: inout Set<String>,
        counters: inout DuplicateProgress, reporter: inout ProgressReporter
    ) throws {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey,
        ]
        var stack = [root]
        while let directory = stack.popLast() {
            try Task.checkCancellation()
            guard visited.insert(directory).inserted else { continue }
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: directory, isDirectory: true), includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles])
            } catch {
                continue
            }
            for child in children {
                let name = child.lastPathComponent
                let path = directory == "/" ? "/" + name : directory + "/" + name
                guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true
                else { continue }
                if values.isDirectory == true {
                    if values.isPackage == true || ClutterPaths.isPackageName(name)
                        || ClutterPaths.isToolFolderName(name)
                    {
                        continue
                    }
                    if !access && FullDiskAccessPaths.isGuardedWithoutAccess(path, home: home) { continue }
                    if protectedList.isInsideProtectedRoot(path) { continue }
                    stack.append(path)
                } else if values.isRegularFile == true {
                    counters.filesSeen += 1
                    let size = Int64(values.fileSize ?? 0)
                    guard size >= minimumSize, !ProtectedList.isDatabaseFile(child) else { continue }
                    bySize[size, default: []].append(path)
                }
            }
            reporter.report(counters)
        }
    }

    /// Sends progress at most every 0.1 s.
    struct ProgressReporter {
        let send: (@Sendable (DuplicateProgress) -> Void)?
        private var last = Date.distantPast

        init(send: (@Sendable (DuplicateProgress) -> Void)?) { self.send = send }

        mutating func report(_ progress: DuplicateProgress, force: Bool = false) {
            guard let send else { return }
            let now = Date()
            guard force || now.timeIntervalSince(last) >= 0.1 else { return }
            last = now
            send(progress)
        }
    }

    // MARK: - Keeper

    /// The copy to keep: the one in the most deliberate place — Documents, then Desktop, then any
    /// other folder, then Downloads — and among equals the oldest (created, then modified), then
    /// the shortest path.
    static func suggestKeeper(_ files: [DuplicateFile], home: String) -> DuplicateFile? {
        files.min { a, b in
            let ra = placeRank(a.url.path, home: home)
            let rb = placeRank(b.url.path, home: home)
            if ra != rb { return ra < rb }
            if a.created != b.created { return a.created < b.created }
            if a.modified != b.modified { return a.modified < b.modified }
            if a.url.path.count != b.url.path.count { return a.url.path.count < b.url.path.count }
            return a.url.path < b.url.path
        }
    }

    /// 0 Documents, 1 Desktop, 2 anywhere else, 3 Downloads.
    static func placeRank(_ path: String, home: String) -> Int {
        if PathTools.isInside(path, root: home + "/Documents") { return 0 }
        if PathTools.isInside(path, root: home + "/Desktop") { return 1 }
        if PathTools.isInside(path, root: home + "/Downloads") { return 3 }
        return 2
    }

    // MARK: - Paths

    /// Absolute, no `.`/`..`, no trailing slash; nil for anything else.
    static func normalized(_ path: String) -> String? {
        let components = PathTools.components(path)
        guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else { return nil }
        return "/" + components.joined(separator: "/")
    }

    /// Every component of `path` exists and none is a link (lstat, top-down).
    static func isLinkFree(_ path: String) -> Bool {
        var prefix = ""
        for component in PathTools.components(path) {
            prefix += "/" + component
            if Cleaner.linkState(prefix) != .present { return false }
        }
        return !prefix.isEmpty
    }

    /// Drops roots inside another chosen root (so nothing is listed twice).
    static func withoutNested(_ roots: [String]) -> [String] {
        var result: [String] = []
        for root in roots.sorted(by: { $0.count < $1.count })
        where !result.contains(where: {
            PathTools.isInside(root, root: $0)
        }) {
            result.append(root)
        }
        return result
    }
}
