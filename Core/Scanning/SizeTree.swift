import Collections
import Foundation

/// What a file or folder mostly is, for the Space map colours.
enum FileKind: UInt8, Sendable, CaseIterable {
    case other, apps, media, documents, dev, caches

    var title: String {
        switch self {
        case .other: "Other"
        case .apps: "Apps"
        case .media: "Media"
        case .documents: "Documents"
        case .dev: "Developer"
        case .caches: "Caches"
        }
    }

    /// By file extension (lowercased, without the dot).
    static func forExtension(_ ext: String) -> FileKind {
        extensionKinds[ext] ?? .other
    }

    /// A fixed kind for well-known folder names, or nil to take the kind of its biggest child.
    static func forDirectory(name: String) -> FileKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".app") { return .apps }
        if lower.hasSuffix(".photoslibrary") || lower.hasSuffix(".musiclibrary") || lower.hasSuffix(".tvlibrary") {
            return .media
        }
        if directoryKinds[lower] != nil { return directoryKinds[lower] }
        return nil
    }

    private static let directoryKinds: [String: FileKind] = [
        "caches": .caches, ".cache": .caches, "cache": .caches, "deriveddata": .caches, ".npm": .caches,
        "node_modules": .dev, ".git": .dev, "developer": .dev, ".cargo": .dev, ".rustup": .dev, ".gradle": .dev,
        ".m2": .dev, ".venv": .dev, "venv": .dev, "pods": .dev, ".cocoapods": .dev, ".pub-cache": .dev,
    ]

    private static let extensionKinds: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        let groups: [(FileKind, [String])] = [
            (
                .media,
                [
                    "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw",
                    "dng", "psd", "webp", "mov", "mp4", "m4v", "avi", "mkv", "webm", "mp3", "m4a", "aac", "wav",
                    "aif", "aiff", "flac", "caf", "logicx", "band",
                ]
            ),
            (
                .documents,
                [
                    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf",
                    "rtfd", "md", "csv", "epub", "odt", "ods", "sketch", "fig",
                ]
            ),
            (.apps, ["dmg", "pkg", "mpkg", "ipa", "xip"]),
            (
                .dev,
                [
                    "swift", "c", "h", "m", "mm", "cpp", "hpp", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs",
                    "java", "kt", "o", "a", "dylib", "so", "jar", "class", "pyc", "wasm", "xcarchive", "dSYM",
                    "pch", "pcm", "ipynb",
                ]
            ),
            (.caches, ["cache", "tmp", "log"]),
        ]
        for (kind, exts) in groups {
            for ext in exts { map[ext.lowercased()] = kind }
        }
        return map
    }()
}

/// The result of a disk walk: every file and folder as one node, stored in flat arrays
/// (CLAUDE.md: never one class instance per file).
///
/// Layout per node: `sizes` (Int64), `parent` / `firstChild` / `nextSibling` (UInt32 indices,
/// `SizeTree.none` = no link), `kinds` and `fileKinds` (UInt8), and its name in `names`, one
/// contiguous UTF-8 byte buffer plus a UInt32 end offset per node. That is 26 bytes plus the
/// name's bytes per node: about 46 MB for a million nodes with 20-byte names.
///
/// A parent always has a smaller index than its children, so folder sizes roll up in one
/// backwards pass (`finalize()`).
struct SizeTree: Sendable {
    enum Kind: UInt8, Sendable {
        case file, directory, link
        /// A ProtectedList place: its size is measured, its contents are not listed.
        case protected
        /// Guarded by macOS; not opened because Dustpan has no Full Disk Access. Size unknown (0).
        case needsAccess
        /// Another volume is mounted here; not crossed.
        case otherVolume
        /// macOS refused to list it (permissions). Size unknown (0).
        case unreadable
        /// Listing stopped partway with an error: its size counts only what was read.
        case partial
        case other
    }

    /// No node (end of a sibling list, the root's parent).
    static let none = UInt32.max
    static let root: UInt32 = 0

    /// Node names: UTF-8 bytes back to back; node i's name ends at `ends[i]`.
    struct NameTable: Sendable {
        fileprivate(set) var bytes: [UInt8] = []
        fileprivate(set) var ends: [UInt32] = []

        func name(_ index: UInt32) -> String {
            let i = Int(index)
            let start = i == 0 ? 0 : Int(ends[i - 1])
            let end = Int(ends[i])
            return bytes.withUnsafeBufferPointer { String(decoding: $0[start..<end], as: UTF8.self) }
        }

        fileprivate mutating func append<C: Collection>(_ name: C) where C.Element == UInt8 {
            bytes.append(contentsOf: name)
            ends.append(UInt32(bytes.count))
        }
    }

    /// The walked folder's absolute path (the root node's name is the same path).
    let rootPath: String
    private(set) var names = NameTable()
    private(set) var sizes: [Int64] = []
    private(set) var parent: [UInt32] = []
    private(set) var firstChild: [UInt32] = []
    private(set) var nextSibling: [UInt32] = []
    private(set) var kinds: [Kind] = []
    private(set) var fileKinds: [FileKind] = []
    /// Nodes that were replaced by `graft` and are no longer reachable.
    private(set) var detachedCount = 0
    /// Counters filled by the walker.
    var fileCount = 0
    var directoryCount = 0

    init(rootPath: String, rootKind: Kind = .directory, capacity: Int = 0) {
        self.rootPath = rootPath
        if capacity > 0 { reserve(capacity) }
        _ = append(name: Array(rootPath.utf8), parent: Self.none, kind: rootKind, size: 0, fileKind: nil)
    }

    var count: Int { sizes.count }
    var totalSize: Int64 { sizes.isEmpty ? 0 : sizes[0] }

    mutating func reserve(_ capacity: Int) {
        sizes.reserveCapacity(capacity)
        parent.reserveCapacity(capacity)
        firstChild.reserveCapacity(capacity)
        nextSibling.reserveCapacity(capacity)
        kinds.reserveCapacity(capacity)
        fileKinds.reserveCapacity(capacity)
        names.ends.reserveCapacity(capacity)
        names.bytes.reserveCapacity(capacity * 20)
    }

    // MARK: - Building

    /// Adds a node under `parent`. `size` is the node's own allocated size (files); folders get
    /// their children's sizes in `finalize()`. `fileKind` nil = decide from the biggest child.
    @discardableResult
    mutating func append<C: Collection>(
        name: C, parent parentIndex: UInt32, kind: Kind, size: Int64, fileKind: FileKind?
    ) -> UInt32 where C.Element == UInt8 {
        let index = UInt32(sizes.count)
        names.append(name)
        sizes.append(size)
        parent.append(parentIndex)
        firstChild.append(Self.none)
        kinds.append(kind)
        fileKinds.append(fileKind ?? .other)
        undecidedKinds.append(fileKind == nil)
        if parentIndex != Self.none {
            nextSibling.append(firstChild[Int(parentIndex)])
            firstChild[Int(parentIndex)] = index
        } else {
            nextSibling.append(Self.none)
        }
        return index
    }

    /// Marks what the walker found at a folder (unreadable, another volume).
    mutating func setKind(_ kind: Kind, at index: UInt32) {
        kinds[Int(index)] = kind
    }

    /// Adds bytes to one node (a protected folder measured without listing it).
    mutating func addSize(_ bytes: Int64, to index: UInt32) {
        sizes[Int(index)] += bytes
    }

    /// Temporary during building: folders whose kind comes from their biggest child.
    private var undecidedKinds: [Bool] = []

    /// Rolls sizes up into folders and gives undecided folders the kind of their biggest child.
    /// Call once, after the last `append`.
    mutating func finalize() {
        guard count > 1 else {
            undecidedKinds = []
            return
        }
        let n = count
        var best = [Int64](repeating: -1, count: n)
        var sizes = self.sizes
        var fileKinds = self.fileKinds
        let parent = self.parent
        let undecided = undecidedKinds
        self.sizes = []
        self.fileKinds = []
        for i in stride(from: n - 1, through: 1, by: -1) {
            let p = Int(parent[i])
            guard p != Int(Self.none) else { continue }
            sizes[p] += sizes[i]
            if undecided[p], sizes[i] > best[p] {
                best[p] = sizes[i]
                fileKinds[p] = fileKinds[i]
            }
        }
        self.sizes = sizes
        self.fileKinds = fileKinds
        undecidedKinds = []
    }

    // MARK: - Reading

    func name(_ index: UInt32) -> String { index == Self.root ? rootPath : names.name(index) }
    func size(_ index: UInt32) -> Int64 { sizes[Int(index)] }
    func kind(_ index: UInt32) -> Kind { kinds[Int(index)] }
    func fileKind(_ index: UInt32) -> FileKind { fileKinds[Int(index)] }
    func parent(of index: UInt32) -> UInt32? {
        let p = parent[Int(index)]
        return p == Self.none ? nil : p
    }

    /// A folder whose children are listed (the walker opened it).
    func isBrowsable(_ index: UInt32) -> Bool {
        (kinds[Int(index)] == .directory || kinds[Int(index)] == .partial) && firstChild[Int(index)] != Self.none
    }

    func children(of index: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        var child = firstChild[Int(index)]
        while child != Self.none {
            result.append(child)
            child = nextSibling[Int(child)]
        }
        return result
    }

    /// Children, biggest first.
    func sortedChildren(of index: UInt32) -> [UInt32] {
        children(of: index).sorted { sizes[Int($0)] > sizes[Int($1)] }
    }

    /// The `limit` biggest direct children, biggest first, picked with a bounded min-heap.
    func topChildren(of index: UInt32, limit: Int, where include: (UInt32) -> Bool = { _ in true }) -> [UInt32] {
        guard limit > 0 else { return [] }
        var heap = Heap<Ranked>()
        var child = firstChild[Int(index)]
        while child != Self.none {
            if include(child) {
                let ranked = Ranked(size: sizes[Int(child)], index: child)
                if heap.count < limit {
                    heap.insert(ranked)
                } else if let smallest = heap.min, smallest < ranked {
                    _ = heap.replaceMin(with: ranked)
                }
            }
            child = nextSibling[Int(child)]
        }
        var result: [UInt32] = []
        result.reserveCapacity(heap.count)
        while let next = heap.popMax() { result.append(next.index) }
        return result
    }

    private struct Ranked: Comparable {
        let size: Int64
        let index: UInt32
        static func < (a: Ranked, b: Ranked) -> Bool {
            a.size != b.size ? a.size < b.size : a.index > b.index
        }
    }

    /// From the root down to `index`.
    func ancestry(of index: UInt32) -> [UInt32] {
        var chain: [UInt32] = [index]
        var current = index
        while let p = parent(of: current) {
            chain.append(p)
            current = p
        }
        return chain.reversed()
    }

    func path(_ index: UInt32) -> String {
        let chain = ancestry(of: index)
        guard chain.count > 1 else { return rootPath }
        let tail = chain.dropFirst().map { names.name($0) }.joined(separator: "/")
        return rootPath == "/" ? "/" + tail : rootPath + "/" + tail
    }

    /// The node at an absolute path inside the tree, matching names case-insensitively.
    func index(ofPath path: String) -> UInt32? {
        let root = rootPath.lowercased()
        let target = path.lowercased()
        if target == root { return Self.root }
        let prefix = root == "/" ? "/" : root + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var current = Self.root
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            guard
                let match = children(of: current).first(where: {
                    names.name($0).caseInsensitiveCompare(component) == .orderedSame
                })
            else { return nil }
            current = match
        }
        return current
    }

    /// Indices of every reachable node of `kind`.
    func nodes(ofKind kind: Kind) -> [UInt32] {
        var result: [UInt32] = []
        var stack: [UInt32] = [Self.root]
        while let node = stack.popLast() {
            if kinds[Int(node)] == kind { result.append(node) }
            var child = firstChild[Int(node)]
            while child != Self.none {
                stack.append(child)
                child = nextSibling[Int(child)]
            }
        }
        return result
    }

    // MARK: - Incremental refresh

    /// Replaces the contents of folder `index` with a fresh walk of the same folder (`subtree`,
    /// already finalized), and corrects every ancestor's size. The old child nodes stay in the
    /// arrays but are unreachable (`detachedCount`).
    mutating func graft(_ subtree: SizeTree, at index: UInt32) {
        let old = sizes[Int(index)]
        let removed = countDescendants(of: index)
        detachedCount += removed.nodes
        // Counters follow the fresh walk (files inside protected places are counted by the walk but
        // have no nodes, so this can drift slightly there).
        fileCount = max(fileCount - removed.files + subtree.fileCount, 0)
        directoryCount = max(directoryCount - removed.directories + max(subtree.directoryCount - 1, 0), 0)
        firstChild[Int(index)] = Self.none
        kinds[Int(index)] = subtree.kinds[0]
        fileKinds[Int(index)] = subtree.fileKinds[0]
        sizes[Int(index)] = subtree.sizes[0]
        // Map subtree indices to new indices; the subtree's root becomes `index`.
        var map = [UInt32](repeating: Self.none, count: subtree.count)
        map[0] = index
        reserve(count + subtree.count)
        for i in 1..<max(subtree.count, 1) {
            let newParent = map[Int(subtree.parent[i])]
            let start = Int(subtree.names.ends.indices.contains(i - 1) ? subtree.names.ends[i - 1] : 0)
            let end = Int(subtree.names.ends[i])
            let added = append(
                name: subtree.names.bytes[start..<end], parent: newParent, kind: subtree.kinds[i],
                size: subtree.sizes[i], fileKind: subtree.fileKinds[i])
            map[i] = added
        }
        undecidedKinds = []
        let delta = subtree.sizes[0] - old
        var current = parent(of: index)
        while let p = current {
            sizes[Int(p)] += delta
            current = parent(of: p)
        }
    }

    /// Reachable nodes below `index`, and how many of them are files (or links) and folders.
    private func countDescendants(of index: UInt32) -> (nodes: Int, files: Int, directories: Int) {
        var nodes = 0
        var files = 0
        var directories = 0
        var stack = children(of: index)
        while let node = stack.popLast() {
            nodes += 1
            switch kinds[Int(node)] {
            case .file, .link: files += 1
            case .directory, .partial: directories += 1
            default: break
            }
            stack.append(contentsOf: children(of: node))
        }
        return (nodes, files, directories)
    }

    // MARK: - Memory

    /// Bytes held by the arrays (by capacity), for the 1M-node budget (< 400 MB).
    var estimatedBytes: Int {
        sizes.capacity * MemoryLayout<Int64>.stride
            + (parent.capacity + firstChild.capacity + nextSibling.capacity + names.ends.capacity)
            * MemoryLayout<UInt32>.stride
            + kinds.capacity * MemoryLayout<Kind>.stride + fileKinds.capacity * MemoryLayout<FileKind>.stride
            + names.bytes.capacity + undecidedKinds.capacity
    }
}
