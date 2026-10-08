import Foundation
import Testing
import os

@testable import Dustpan

/// SplitMix64: tiny, fast and seedable, so a failing run can be replayed exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A Trash that moves nothing: it records what the Cleaner asked to move, so thousands of
/// attempts run against the same unchanged tree.
final class RecordingTrashMover: TrashMover, Sendable {
    let trashDirectory: URL
    private let asked = OSAllocatedUnfairLock(initialState: [URL]())

    init(trashDirectory: URL) { self.trashDirectory = trashDirectory }

    func trash(_ url: URL) throws -> URL {
        asked.withLock { $0.append(url) }
        return trashDirectory.appendingPathComponent(UUID().uuidString)
    }

    func takeAsked() -> [URL] {
        asked.withLock { list in
            defer { list = [] }; return list
        }
    }
}

/// Fuzzing the Cleaner's path checks (safety rule 4): random item paths built from `..`, `.`,
/// `~`, `//`, trailing slashes, capitals, NFC/NFD spellings, links, link loops and linked
/// parents. Whatever the path, the Cleaner may only ever move a link-free path inside the rule's
/// root (junk) or inside home and outside protected places (Space map).
///
/// Seed: `DUSTPAN_FUZZ_SEED` (set as `TEST_RUNNER_DUSTPAN_FUZZ_SEED` for xcodebuild), else fixed.
@Suite("Cleaner fuzz")
struct CleanerFuzzTests {
    static var seed: UInt64 {
        ProcessInfo.processInfo.environment["DUSTPAN_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0xD057_9A11
    }

    struct Tree {
        let fixture: FixtureHome
        let trash: URL
        let store: CleanupStore
        let cachesRoot: String

        init() throws {
            fixture = try FixtureHome()
            let container = fixture.outside.deletingLastPathComponent()
            trash = container.appendingPathComponent("trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            store = CleanupStore(database: try AppDatabase(directory: container.appendingPathComponent("db")))
            let f = fixture
            try f.file("Library/Caches/com.fuzz.a/x.bin", bytes: 4_000)
            try f.file("Library/Caches/com.fuzz.b/deep/y.bin", bytes: 4_000)
            try f.file("Library/Caches/caf\u{E9}/z.bin", bytes: 4_000)  // NFC on disk
            try f.file("Library/Caches/com.fuzz.db/keep.sqlite", bytes: 4_000)  // allowed in Caches
            try f.file("Documents/secret/s.txt", bytes: 4_000)
            try f.file("Library/Logs/app/l.log", bytes: 4_000)
            try f.file("Library/Mail/V10/m.emlx", bytes: 4_000)
            try f.file("Library/Application Support/App/data.sqlite", bytes: 4_000)
            try f.file("Library/Application Support/App/notes.txt", bytes: 4_000)
            try f.file("", bytes: 4_000, absolute: f.outside.appendingPathComponent("o/o.txt"))
            try f.symlink("Library/Caches/com.fuzz.toDocs", to: f.path("Documents/secret"))
            try f.symlink("Library/Caches/com.fuzz.toOutside", to: f.outside.appendingPathComponent("o"))
            try f.symlink("Library/Caches/com.fuzz.viaParent", to: f.path("Documents"))
            try f.symlink("Library/Caches/com.fuzz.loop1", to: f.path("Library/Caches/com.fuzz.loop2"))
            try f.symlink("Library/Caches/com.fuzz.loop2", to: f.path("Library/Caches/com.fuzz.loop1"))
            try f.symlink("Library/CachesLink", to: f.path("Library/Caches"))
            try f.symlink("Documents/backToCaches", to: f.path("Library/Caches"))
            try f.symlink("Library/Caches/com.fuzz.a/inner", to: f.path("Library/Mail"))
            // Ordinary user files the Space map may move.
            for file in [
                "Documents/loose/a.txt", "Documents/loose/b.txt", "Documents/note.txt", "Movies/m1.mov",
                "Movies/clips/c.mov", "Desktop/note.txt",
            ] {
                try f.file(file, bytes: 4_000)
            }
            try f.symlink("Movies/toMail", to: f.path("Library/Mail"))
            cachesRoot = f.path("Library/Caches").path
        }

        func cleaner(_ mover: RecordingTrashMover) -> Cleaner {
            Cleaner(
                home: fixture.url, trashMover: mover, runningApps: FakeRunningApps(), store: store,
                protectedList: ProtectedList(home: fixture.url), rules: { [CleanerTests.caches] },
                now: { fixture.now }, hasFullDiskAccess: { true }, ownPaths: [])
        }
    }

    /// One random path aimed at (or near) the cache rule's root.
    /// Real files and folders in the fuzz tree's user folders (plus a link to Mail).
    static let userFiles = [
        "Documents/loose", "Documents/loose/a.txt", "Documents/loose/b.txt", "Documents/note.txt", "Movies/m1.mov",
        "Movies/clips", "Movies/clips/c.mov", "Desktop/note.txt", "Movies/toMail", "Documents/secret/s.txt",
    ]

    /// With `userFolders`, aimed at ordinary user files (Documents, Movies, Desktop) instead.
    static func randomPath(_ rng: inout SeededGenerator, home: String, userFolders: Bool = false) -> String {
        let cacheNames = [
            "com.fuzz.a", "com.fuzz.b", "caf\u{E9}", "cafe\u{301}", "com.fuzz.toDocs", "com.fuzz.toOutside",
            "com.fuzz.viaParent", "com.fuzz.loop1", "com.fuzz.db", "missing", "com.fuzz.a/inner",
        ]
        let tails = [
            [], [], ["x.bin"], ["deep"], ["secret"], ["s.txt"], ["inner"], ["..", "..", "..", "Documents", "secret"],
            ["..", "Logs", "app"], [".."], ["..", ".."], ["o.txt"], ["V10"],
        ]
        let cacheBases: [[String]] = [
            ["Library", "Caches"], ["Library", "Caches"], ["Library", "CachesLink"], ["Documents", "backToCaches"],
            ["Library", "Caches", "..", "Caches"], ["Library", ".", "Caches"], ["Library", "Logs"], ["Library"],
            ["Library", "Application Support", "App"], [],
        ]
        let userBases: [[String]] = [
            ["Documents"], ["Documents", "loose"], ["Documents", "loose"], ["Movies"], ["Movies", "clips"], ["Desktop"],
            ["Documents", ".", "loose"], ["Movies", "..", "Movies"],
        ]
        let userNames = [
            "loose", "a.txt", "b.txt", "m1.mov", "clips", "c.mov", "note.txt", "toMail", "secret", "s.txt", "missing",
        ]
        let names = userFolders ? userNames : cacheNames
        let bases = userFolders ? userBases : cacheBases
        var parts = bases.randomElement(using: &rng)!
        parts += names.randomElement(using: &rng)!.split(separator: "/").map(String.init)
        parts += userFolders && Bool.random(using: &rng) ? [] : tails.randomElement(using: &rng)!
        // User mode: most of the time start from a real file or folder, so the allowed path is
        // exercised too (each mutation below can still turn it into something refused).
        if userFolders, Int.random(in: 0..<10, using: &rng) < 7 {
            parts = Self.userFiles.randomElement(using: &rng)!.split(separator: "/").map(String.init)
        }
        let rare = userFolders ? 3 : 1  // user mode mutates less often
        if parts.last == "App" || Bool.random(using: &rng) && parts.contains("App") { parts.append("notes.txt") }
        // Sprinkle `.`, `..` + name, and capitals.
        if Int.random(in: 0..<(4 * rare), using: &rng) == 0, let i = parts.indices.randomElement(using: &rng) {
            parts.insert(".", at: i)
        }
        if Int.random(in: 0..<(5 * rare), using: &rng) == 0, parts.count > 1 {
            let i = Int.random(in: 1..<parts.count, using: &rng)
            parts.insert(contentsOf: ["..", parts[i - 1]], at: i)
        }
        parts = parts.map { Int.random(in: 0..<(6 * rare), using: &rng) == 0 ? $0.uppercased() : $0 }
        var head: String
        switch Int.random(in: 0..<(8 * rare), using: &rng) {
        case 0: head = "~"
        case 1: head = home.replacingOccurrences(of: "/private/var/", with: "/var/")  // through the /var link
        case 2: head = home.uppercased()
        case 3: head = ""  // relative
        default: head = home
        }
        var path = ([head] + parts).joined(separator: Int.random(in: 0..<6, using: &rng) == 0 ? "//" : "/")
        if Bool.random(using: &rng) { path += "/" }
        if Int.random(in: 0..<10, using: &rng) == 0 { path = path.decomposedStringWithCanonicalMapping }
        return path
    }

    @Test("Junk clean never moves anything outside the rule's root")
    func junkCleanStaysInRoot() async throws {
        let tree = try Tree()
        defer { tree.fixture.remove() }
        let mover = RecordingTrashMover(trashDirectory: tree.trash)
        let cleaner = tree.cleaner(mover)
        var rng = SeededGenerator(seed: Self.seed)
        var moved = 0
        var tried = 0
        for _ in 0..<400 {
            let paths = (0..<8).map { _ in Self.randomPath(&rng, home: tree.fixture.url.path) }
            tried += paths.count
            let items = paths.map { path in
                ScanItem(
                    id: UUID(), url: URL(fileURLWithPath: path), allocatedSize: 1, modified: .distantPast,
                    category: .userCache, ruleID: "cache.apps", risk: .safe, isSelected: true)
            }
            _ = await cleaner.clean(items)
            for url in mover.takeAsked() {
                moved += 1
                let canonical = PathTools.canonical(url.path)
                #expect(canonical == url.path, "seed \(Self.seed): moved through a link: \(url.path) from \(paths)")
                #expect(
                    PathTools.isStrictlyInside(url.path, root: tree.cachesRoot),
                    "seed \(Self.seed): moved \(url.path), outside the rule root, from \(paths)")
                // Only the cache folders themselves (one level below the root), never a link.
                #expect(PathTools.components(url.path).count == PathTools.components(tree.cachesRoot).count + 1)
                #expect(!url.path.contains("toDocs") && !url.path.contains("loop") && !url.path.contains("viaParent"))
            }
        }
        print("Cleaner fuzz (junk): seed \(Self.seed), \(tried) paths, \(moved) moves of legitimate cache folders")
        #expect(moved > 0, "the fuzz never produced a legitimate item; it isn't testing much")
    }

    @Test("Space map never moves a link, anything outside home, or a protected place")
    func userChosenStaysSafe() async throws {
        let tree = try Tree()
        defer { tree.fixture.remove() }
        let mover = RecordingTrashMover(trashDirectory: tree.trash)
        let cleaner = tree.cleaner(mover)
        let protectedList = ProtectedList(home: tree.fixture.url)
        let home = tree.fixture.url.path
        var rng = SeededGenerator(seed: Self.seed &+ 1)
        var moved = 0
        for attempt in 0..<1_500 {
            let path = Self.randomPath(&rng, home: home, userFolders: attempt % 2 == 0)
            _ = await cleaner.trashUserChosen(URL(fileURLWithPath: path))
            for url in mover.takeAsked() {
                moved += 1
                #expect(PathTools.canonical(url.path) == url.path, "seed \(Self.seed): via a link: \(path)")
                #expect(PathTools.isStrictlyInside(url.path, root: home), "seed \(Self.seed): outside home: \(path)")
                #expect(!protectedList.isProtectedPath(url.path), "seed \(Self.seed): protected: \(path)")
                #expect(!url.path.contains("Application Support/App"), "seed \(Self.seed): app data: \(path)")
                #expect(!url.path.contains("toMail") && !url.path.contains("/Library/"), "seed \(Self.seed): \(path)")
                #expect(PathTools.components(url.path).count >= PathTools.components(home).count + 2)
            }
        }
        print("Cleaner fuzz (Space map): seed \(Self.seed &+ 1), 1500 paths, \(moved) moves")
        #expect(moved >= 50, "only \(moved) legitimate moves: the fuzz isn't exercising the allowed path")
    }
}
