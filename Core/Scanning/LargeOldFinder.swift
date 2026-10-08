import CoreServices
import Foundation
import UniformTypeIdentifiers
import os

/// What a big file is, for the Large & old kind filter. Decided from the name's extension only.
enum ClutterKind: String, CaseIterable, Sendable {
    case video, image, audio, archive, document, other

    var title: String {
        switch self {
        case .video: "Videos"
        case .image: "Images"
        case .audio: "Audio"
        case .archive: "Archives & disk images"
        case .document: "Documents"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .archive: "archivebox"
        case .document: "doc.text"
        case .other: "doc"
        }
    }

    static func of(_ path: String) -> ClutterKind {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) || ["iso", "img", "pkg", "xip"].contains(ext) {
            return .archive
        }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) || type.conforms(to: .epub)
        {
            return .document
        }
        return .other
    }
}

/// A big file in the home folder.
struct LargeFile: Sendable, Identifiable, Hashable {
    let url: URL
    let allocatedSize: Int64
    /// When Spotlight last saw it opened (`kMDItemLastUsedDate`); nil when unknown or unindexed.
    let lastUsed: Date?
    let modified: Date
    let kind: ClutterKind

    var id: String { url.path }

    /// The later of last opened and last changed: a file changed last week isn't "old".
    var lastTouched: Date { max(lastUsed ?? .distantPast, modified) }
}

/// The Large & old filters.
struct LargeOldFilter: Sendable, Equatable {
    enum MinimumSize: Int64, CaseIterable, Sendable {
        case mb100 = 104_857_600
        case mb500 = 524_288_000
        case gb1 = 1_073_741_824

        var title: String {
            switch self {
            case .mb100: "Over 100 MB"
            case .mb500: "Over 500 MB"
            case .gb1: "Over 1 GB"
            }
        }
    }

    enum Age: Int, CaseIterable, Sendable {
        case months3 = 3
        case months6 = 6
        case months12 = 12

        var title: String {
            switch self {
            case .months3: "3 months"
            case .months6: "6 months"
            case .months12: "A year"
            }
        }
    }

    var minimumSize: MinimumSize = .mb100
    var age: Age = .months6
    /// Nil = every kind.
    var kind: ClutterKind?

    /// What the Sweep counts as large & old: over 1 GB, not opened or changed for a year.
    static let sweep = LargeOldFilter(minimumSize: .gb1, age: .months12, kind: nil)

    /// The files this filter shows. The Large & old list and the Sweep tile both use this.
    func matching(_ files: [LargeFile], now: Date) -> [LargeFile] {
        files.filter { includes($0, now: now) }
    }

    static func bytes(_ files: [LargeFile]) -> Int64 { files.reduce(0) { $0 + $1.allocatedSize } }

    /// Big enough, not opened or changed within `age`, and of the chosen kind.
    func includes(_ file: LargeFile, now: Date, calendar: Calendar = .current) -> Bool {
        guard file.allocatedSize >= minimumSize.rawValue else { return false }
        guard let cutoff = calendar.date(byAdding: .month, value: -age.rawValue, to: now),
            file.lastTouched < cutoff
        else { return false }
        if let kind, file.kind != kind { return false }
        return true
    }
}

/// One big file Spotlight knows about. Values come from the index, not from the file.
struct IndexedFile: Sendable, Equatable {
    let path: String
    let size: Int64
    let lastUsed: Date?
}

/// Spotlight, or a fake in tests.
protocol LargeFileIndex: Sendable {
    /// Files of at least `minimumBytes` (logical size) under `scopes`, straight from the index.
    func largeFiles(in scopes: [String], minimumBytes: Int64) -> [IndexedFile]
}

/// Synchronous `MDQuery` on `kMDItemFSSize`, with `kMDItemLastUsedDate` read from the result
/// values (the files themselves aren't touched). See PROGRESS.md for why it's `MDQuery` and not
/// `NSMetadataQuery`.
struct SpotlightLargeFiles: LargeFileIndex {
    func largeFiles(in scopes: [String], minimumBytes: Int64) -> [IndexedFile] {
        guard !scopes.isEmpty else { return [] }
        let predicate = "kMDItemFSSize >= \(minimumBytes)" as CFString
        let values = [kMDItemPath, kMDItemFSSize, kMDItemLastUsedDate] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate, values, nil) else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var files: [IndexedFile] = []
        for index in 0..<MDQueryGetResultCount(query) {
            // Result items carry the index's values; reading them doesn't open the file.
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let size = (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.int64Value ?? 0
            let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            files.append(IndexedFile(path: path, size: size, lastUsed: lastUsed))
        }
        return files
    }
}

struct LargeOldScan: Sendable, Equatable {
    var files: [LargeFile] = []
    /// Big files Spotlight knows about in folders Dustpan can't open without Full Disk Access
    /// (counted from the index only; never touched).
    var needsAccessCount = 0
    var usedSpotlight = false
    var seconds: TimeInterval = 0
}

/// Finds big files in the home folder for Large & old.
///
/// Spotlight (`kMDItemFSSize`, `kMDItemLastUsedDate`) finds indexed files; a `DiskWalker` walk
/// of the same scope catches what Spotlight doesn't index (hidden folders, folders excluded
/// from Spotlight, unindexed volumes). Every hit then goes through `accept`:
/// - inside the scope, and not in `~/Library` or `~/.Trash` (app data and the Trash);
/// - without Full Disk Access, not in a guarded folder — checked on the path text before any
///   `lstat`; such hits are only counted;
/// - not a ProtectedList place, not an app database file, not inside a package or a tool
///   folder, no link anywhere on its path;
/// - a regular file on disk, at least `minimumBytes` allocated, not a cloud placeholder;
/// - each file on disk once (hard links).
actor LargeOldFinder {
    let home: String
    private let protectedList: ProtectedList
    private let hasFullDiskAccess: @Sendable () -> Bool
    private let cloud: any CloudStatusChecking
    private let index: (any LargeFileIndex)?
    private let logger = Logger(subsystem: "app.dustpan", category: "largeold")

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        protectedList: ProtectedList? = nil,
        hasFullDiskAccess: @escaping @Sendable () -> Bool,
        cloud: any CloudStatusChecking = SystemCloudStatus(),
        index: (any LargeFileIndex)? = SpotlightLargeFiles()
    ) {
        self.home = PathTools.canonical(home.path) ?? home.standardizedFileURL.path
        self.protectedList = protectedList ?? ProtectedList(home: home)
        self.hasFullDiskAccess = hasFullDiskAccess
        self.cloud = cloud
        self.index = index
    }

    /// Big files under `scopes` (the home folder by default) of at least `minimumBytes`.
    /// Filtering by age and kind happens in the view (`LargeOldFilter`), so changing a filter
    /// doesn't look again.
    func find(
        scopes: [URL]? = nil, minimumBytes: Int64 = LargeOldFilter.MinimumSize.mb100.rawValue
    ) async throws -> LargeOldScan {
        assertNotMainThread()
        let started = Date()
        let access = hasFullDiskAccess()
        let roots = DuplicateFinder.withoutNested(
            (scopes ?? [URL(fileURLWithPath: home, isDirectory: true)]).compactMap {
                DuplicateFinder.normalized($0.path)
            })
        var scan = LargeOldScan()
        var seen = Set<String>()
        var inodes = Set<FileFacts.FileID>()
        let databaseFolders = DatabaseFolderCheck(home: home, protectedList: protectedList)

        func consider(_ path: String, lastUsed: Date?, fromIndex: Bool) {
            guard let root = roots.first(where: { PathTools.isInside(path, root: $0) }),
                seen.insert(path.lowercased()).inserted
            else { return }
            switch accept(
                path, root: root, access: access, minimumBytes: minimumBytes, databaseFolders: databaseFolders)
            {
            case .needsAccess:
                if fromIndex { scan.needsAccessCount += 1 }
            case .skip:
                break
            case .file(let facts):
                guard inodes.insert(facts.fileID).inserted else { return }
                scan.files.append(
                    LargeFile(
                        url: URL(fileURLWithPath: path), allocatedSize: facts.allocated, lastUsed: lastUsed,
                        modified: facts.modified, kind: .of(path)))
            }
        }

        // Spotlight first: it knows when files were last opened.
        if let index {
            scan.usedSpotlight = true
            for hit in index.largeFiles(in: roots, minimumBytes: minimumBytes) {
                try Task.checkCancellation()
                guard let path = DuplicateFinder.normalized(hit.path) else { continue }
                consider(path, lastUsed: hit.lastUsed, fromIndex: true)
            }
        }

        // Then a walk for what Spotlight doesn't index. The walker already skips guarded folders
        // without access, ProtectedList places and links.
        let walker = DiskWalker(
            home: URL(fileURLWithPath: home), protectedList: protectedList, hasFullDiskAccess: { access })
        for root in roots {
            try Task.checkCancellation()
            let (folders, files) = walkRoots(for: root)
            for file in files { consider(file, lastUsed: nil, fromIndex: false) }
            for folder in folders {
                let tree = try await walker.walk(URL(fileURLWithPath: folder, isDirectory: true))
                for node in tree.nodes(ofKind: .file) where tree.size(node) >= minimumBytes {
                    consider(tree.path(node), lastUsed: nil, fromIndex: false)
                }
            }
        }

        scan.files.sort { $0.allocatedSize > $1.allocatedSize }
        scan.seconds = Date().timeIntervalSince(started)
        logger.info(
            """
            Large & old: \(scan.files.count, privacy: .public) files, \(scan.needsAccessCount, privacy: .public) \
            need access, \(scan.seconds, privacy: .public) s
            """)
        return scan
    }

    /// What to walk for `root`. The home folder is walked folder by folder, leaving out
    /// `~/Library` and `~/.Trash` (never listed here); files directly in home are returned to be
    /// checked one by one.
    private func walkRoots(for root: String) -> (folders: [String], files: [String]) {
        guard root.lowercased() == home.lowercased() else { return ([root], []) }
        var folders: [String] = []
        var files: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] {
            let lower = name.lowercased()
            guard lower != "library", lower != ".trash" else { continue }
            let path = home + "/" + name
            guard let facts = FileFacts.read(path), !facts.isSymlink else { continue }
            if facts.isRegularFile { files.append(path) } else { folders.append(path) }
        }
        return (folders, files)
    }

    enum Verdict: Equatable {
        case file(FileFacts)
        case needsAccess
        case skip
    }

    /// Every check for one hit. Text-only checks come first; the disk is touched only after the
    /// Full Disk Access guard passed.
    func accept(
        _ path: String, root: String, access: Bool, minimumBytes: Int64, databaseFolders: DatabaseFolderCheck
    ) -> Verdict {
        guard PathTools.isStrictlyInside(path, root: home) else { return .skip }
        let rootInLibrary = PathTools.isInside(root, root: home + "/Library")
        if !rootInLibrary && PathTools.isInside(path, root: home + "/Library") { return .skip }
        if PathTools.isInside(path, root: home + "/.Trash") { return .skip }
        if !access && FullDiskAccessPaths.isGuardedWithoutAccess(path, home: home) { return .needsAccess }
        if protectedList.isProtectedPath(path) || ProtectedList.isDatabaseFile(URL(fileURLWithPath: path)) {
            return .skip
        }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") { return .skip }
        guard DuplicateFinder.isLinkFree(path),
            !ClutterPaths.isInsidePackageOrToolFolder(path, root: home),
            !databaseFolders.isInsideDatabaseFolder(path),
            let facts = FileFacts.read(path), facts.isRegularFile, facts.allocated >= minimumBytes,
            !cloud.isCloudOnly(URL(fileURLWithPath: path), facts: facts)
        else { return .skip }
        return .file(facts)
    }
}
