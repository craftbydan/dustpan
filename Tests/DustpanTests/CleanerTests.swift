import CryptoKit
import Foundation
import GRDB
import Testing

@testable import Dustpan

/// Cleaner tests: a temp home, a temp "Trash" folder and a temp database. Never the real ones.
@Suite("Cleaner")
struct CleanerTests {
    struct Harness {
        let fixture: FixtureHome
        let trash: URL
        let dbDirectory: URL
        let store: CleanupStore
        let database: AppDatabase

        init() throws {
            fixture = try FixtureHome()
            let container = fixture.outside.deletingLastPathComponent()
            trash = container.appendingPathComponent("trash", isDirectory: true)
            dbDirectory = container.appendingPathComponent("db", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            database = try AppDatabase(directory: dbDirectory)
            store = CleanupStore(database: database)
        }

        func cleaner(_ rules: [Rule], running: [String: String] = [:], access: Bool = true) -> Cleaner {
            Cleaner(
                home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash),
                runningApps: FakeRunningApps(running: running), store: store,
                protectedList: ProtectedList(home: fixture.url), rules: { rules }, now: { fixture.now },
                hasFullDiskAccess: { access })
        }

        func scan(_ rules: [Rule], ignore: IgnoreList = IgnoreList()) async -> [ScanItem] {
            await JunkScanner(rules: rules, home: fixture.url, now: fixture.now, ignore: ignore).scan()
                .flatMap(\.items)
        }

        func item(_ items: [ScanItem], _ relative: String) -> ScanItem? {
            let path = fixture.path(relative).path.lowercased()
            return items.first { $0.url.path.lowercased() == path }
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: fixture.path(relative).path)
        }

        func remove() { fixture.remove() }
    }

    static func rule(
        _ id: String, _ category: JunkCategory = .userCache, paths: [String], globs: [String] = [],
        risk: Risk = .safe, appBundleID: String? = nil, requiresQuit: Bool = false, detectionOnly: Bool = false
    ) -> Rule {
        Rule(
            id: id, title: id, category: category, paths: paths, globs: globs, risk: risk, why: "Test rule.",
            appBundleID: appBundleID, requiresQuit: requiresQuit, detectionOnly: detectionOnly)
    }

    static let caches = rule("cache.apps", paths: ["~/Library/Caches"], globs: ["*"])

    /// SHA-256 over every file's relative path and contents, so a restore can be compared exactly.
    static func digest(_ url: URL) throws -> String {
        var hasher = SHA256()
        let base = url.path
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(atPath: base) {
            while let relative = enumerator.nextObject() as? String { files.append(relative) }
        }
        for relative in files.sorted() {
            let full = base + "/" + relative
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            hasher.update(data: Data(relative.utf8))
            if !isDirectory.boolValue { hasher.update(data: try Data(contentsOf: URL(fileURLWithPath: full))) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test("Cleaning moves items to the fake Trash and writes one log row each")
    func cleanMovesAndLogs() async throws {
        let h = try Harness()
        defer { h.remove() }
        let bytesA = try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 20_000)
        try h.fixture.file("Library/Caches/com.example.b/y.bin", bytes: 8_000)
        let items = await h.scan([Self.caches])
        let a = try #require(h.item(items, "Library/Caches/com.example.a"))
        let b = try #require(h.item(items, "Library/Caches/com.example.b"))
        #expect(a.allocatedSize == bytesA)

        let report = await h.cleaner([Self.caches]).clean([a, b])

        #expect(report.skipped.isEmpty)
        #expect(report.moved.count == 2)
        #expect(report.freedBytes == a.allocatedSize + b.allocatedSize)
        #expect(report.cleanedItemIDs == [a.id, b.id])
        #expect(!h.exists("Library/Caches/com.example.a"))
        #expect(FileManager.default.fileExists(atPath: h.trash.appendingPathComponent("com.example.a/x.bin").path))

        let logs = try await h.store.logs()
        #expect(logs.count == 2)
        #expect(Set(logs.compactMap(\.id)) == Set(report.logIDs))
        let logA = try #require(logs.first { $0.originalPath == a.url.path })
        #expect(logA.trashPath == h.trash.appendingPathComponent("com.example.a").path)
        #expect(logA.bytes == a.allocatedSize)
        #expect(logA.ruleID == "cache.apps")
        #expect(logA.restoredAt == nil)
        #expect(abs(logA.date.timeIntervalSince(h.fixture.now)) < 0.01)
    }

    @Test("Undo puts items back byte-identical and marks the rows restored")
    func undoRestoresByteIdentical() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 30_001)
        try h.fixture.file("Library/Caches/com.example.a/deep/er/y.bin", bytes: 4_097)
        try h.fixture.file("Library/Caches/com.example.a/z.txt", bytes: 17)
        let original = h.fixture.path("Library/Caches/com.example.a")
        let before = try Self.digest(original)
        let items = await h.scan([Self.caches])
        let cleaner = h.cleaner([Self.caches])

        let report = await cleaner.clean(items)
        #expect(!h.exists("Library/Caches/com.example.a"))
        let history = try await cleaner.history()
        #expect(history.map(\.status) == [.inTrash])

        let undo = await cleaner.undo(report.logIDs)
        #expect(undo.failed.isEmpty)
        #expect(undo.restored == report.logIDs)
        #expect(try Self.digest(original) == before)
        #expect(!FileManager.default.fileExists(atPath: h.trash.appendingPathComponent("com.example.a").path))
        let rows = try await h.store.logs()
        #expect(rows.allSatisfy { $0.restoredAt != nil })

        // A second undo is refused, not repeated.
        let again = await cleaner.undo(report.logIDs)
        #expect(again.restored.isEmpty)
        #expect(again.failed.values.allSatisfy { $0 == .alreadyRestored })
    }

    @Test("Undo refuses when the item left the Trash or its old place is taken")
    func undoRefusals() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 1_000)
        try h.fixture.file("Library/Caches/com.example.b/x.bin", bytes: 1_000)
        let items = await h.scan([Self.caches])
        let cleaner = h.cleaner([Self.caches])
        let report = await cleaner.clean(items)
        let byPath = Dictionary(uniqueKeysWithValues: report.moved.map { ($0.original.lastPathComponent, $0) })
        let a = try #require(byPath["com.example.a"]?.logID)
        let b = try #require(byPath["com.example.b"]?.logID)

        try FileManager.default.removeItem(at: h.trash.appendingPathComponent("com.example.a"))
        try h.fixture.file("Library/Caches/com.example.b/new.bin", bytes: 10)

        let undo = await cleaner.undo([a, b, 999])
        #expect(undo.restored.isEmpty)
        #expect(undo.failed[a] == .notInTrash)
        #expect(undo.failed[b] == .originalTaken, "\(undo)")
        #expect(undo.failed[999] == .notLogged)
        let history = try await cleaner.history()
        #expect(history.first { $0.log.id == a }?.status == .gone)
    }

    @Test("Undo refuses a log row whose Trash path is outside the Trash")
    func undoRefusesUnsafePath() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("elsewhere/doc.txt", bytes: 100)
        let row = CleanupLog(
            id: nil, date: h.fixture.now, originalPath: h.fixture.path("Library/Caches/x").path,
            trashPath: h.fixture.path("elsewhere/doc.txt").path, bytes: 100, ruleID: nil, restoredAt: nil)
        let inserted = try await h.store.insert([row])
        let id = try #require(inserted.first?.id)
        let undo = await h.cleaner([]).undo([id])
        #expect(undo.failed[id] == .unsafePath)
        #expect(h.exists("elsewhere/doc.txt"))
    }

    @Test("Protected items are skipped with a reason and never moved")
    func protectedSkipped() async throws {
        let h = try Harness()
        defer { h.remove() }
        // An app database outside Caches (scanner would drop it; the Cleaner re-checks anyway).
        try h.fixture.file("Library/Application Support/Notes/store.sqlite", bytes: 4_000)
        try h.fixture.file("Library/Mail/V10/msg.emlx", bytes: 1_000)
        let support = Self.rule("support", paths: ["~/Library/Application Support/Notes"])
        let mail = Self.rule("mail", paths: ["~/Library/Mail"])
        let items = [
            ScanItem(
                id: UUID(), url: h.fixture.path("Library/Application Support/Notes"), allocatedSize: 4_096,
                modified: .distantPast, category: .userCache, ruleID: "support", risk: .safe, isSelected: true),
            ScanItem(
                id: UUID(), url: h.fixture.path("Library/Mail"), allocatedSize: 4_096, modified: .distantPast,
                category: .userCache, ruleID: "mail", risk: .safe, isSelected: true),
        ]
        let report = await h.cleaner([support, mail]).clean(items)
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.protected, .protected])
        #expect(!SkipReason.protected.explanation.isEmpty)
        #expect(h.exists("Library/Application Support/Notes/store.sqlite"))
        #expect(h.exists("Library/Mail/V10/msg.emlx"))
        #expect(try await h.store.logs().isEmpty)
    }

    @Test("A path that resolves outside its rule's root is skipped; a link item is skipped")
    func symlinkEscapesSkipped() async throws {
        let h = try Harness()
        defer { h.remove() }
        let outsideCaches = h.fixture.outside.appendingPathComponent("Caches", isDirectory: true)
        try h.fixture.file("x", bytes: 5_000, absolute: outsideCaches.appendingPathComponent("tool/data.bin"))
        try h.fixture.file("x", bytes: 5_000, absolute: h.fixture.outside.appendingPathComponent("target/t.bin"))
        // ~/Library/Caches is a link to a folder outside home.
        try h.fixture.symlink("Library/Caches", to: outsideCaches)
        // ~/.cache/tool is itself a link.
        try h.fixture.symlink(".cache/tool", to: h.fixture.outside.appendingPathComponent("target"))
        let rules = [Self.caches, Self.rule("dotcache", paths: ["~/.cache/tool"])]
        let viaLink = ScanItem(
            id: UUID(), url: h.fixture.path("Library/Caches/tool"), allocatedSize: 5_000, modified: .distantPast,
            category: .userCache, ruleID: "cache.apps", risk: .safe, isSelected: true)
        let link = ScanItem(
            id: UUID(), url: h.fixture.path(".cache/tool"), allocatedSize: 5_000, modified: .distantPast,
            category: .userCache, ruleID: "dotcache", risk: .safe, isSelected: true)

        let report = await h.cleaner(rules).clean([viaLink, link])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.leavesRuleRoot, .isSymlink])
        #expect(FileManager.default.fileExists(atPath: outsideCaches.appendingPathComponent("tool/data.bin").path))
        #expect(FileManager.default.fileExists(atPath: h.fixture.outside.appendingPathComponent("target/t.bin").path))
    }

    @Test("An item that isn't where its rule looks is skipped as a mismatch")
    func wrongRootSkipped() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Documents/Thesis/draft.txt", bytes: 2_000)
        let item = ScanItem(
            id: UUID(), url: h.fixture.path("Documents/Thesis"), allocatedSize: 4_096, modified: .distantPast,
            category: .userCache, ruleID: "cache.apps", risk: .safe, isSelected: true)
        let unknown = ScanItem(
            id: UUID(), url: h.fixture.path("Documents/Thesis"), allocatedSize: 4_096, modified: .distantPast,
            category: .userCache, ruleID: "no.such.rule", risk: .safe, isSelected: true)
        let report = await h.cleaner([Self.caches]).clean([item, unknown])
        #expect(report.skipped.map(\.reason) == [.ruleMismatch, .unknownRule])
        #expect(h.exists("Documents/Thesis/draft.txt"))
    }

    @Test("requiresQuit: skipped and reported while the app runs, moved once it's closed")
    func requiresQuit() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.google.Chrome/Cache/data", bytes: 9_000)
        let chrome = Self.rule(
            "cache.chrome", paths: ["~/Library/Caches/com.google.Chrome"], appBundleID: "com.google.Chrome",
            requiresQuit: true)
        let items = await h.scan([chrome])
        #expect(items.count == 1)

        let running = await h.cleaner([chrome], running: ["com.google.Chrome": "Google Chrome"]).clean(items)
        #expect(running.moved.isEmpty)
        #expect(running.skipped.map(\.reason) == [.appRunning("Google Chrome")])
        #expect(SkipReason.appRunning("Google Chrome").explanation.contains("Google Chrome"))
        #expect(h.exists("Library/Caches/com.google.Chrome/Cache/data"))

        let closed = await h.cleaner([chrome]).clean(items)
        #expect(closed.moved.count == 1)
        #expect(!h.exists("Library/Caches/com.google.Chrome"))
    }

    @Test("Detection-only items (Docker, the Trash) are refused")
    func detectionOnlyRefused() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file(".Trash/old.zip", bytes: 3_000)
        try h.fixture.file(".docker/buildx/cache/blob", bytes: 3_000)
        let trashRule = Self.rule("trash.home", .trash, paths: ["~/.Trash"], risk: .review, detectionOnly: true)
        let docker = Self.rule("dev.docker.buildx", .dev, paths: ["~/.docker/buildx/cache"], risk: .review)
        let dockerItem = ScanItem(
            id: UUID(), url: h.fixture.path(".docker/buildx/cache"), allocatedSize: 4_096, modified: .distantPast,
            category: .dev, ruleID: "dev.docker.buildx", risk: .review, isSelected: true, detectionOnly: true)
        // The rule flag alone is enough, even if an item claims otherwise.
        let trashItem = ScanItem(
            id: UUID(), url: h.fixture.path(".Trash"), allocatedSize: 4_096, modified: .distantPast,
            category: .trash, ruleID: "trash.home", risk: .review, isSelected: true, detectionOnly: false)

        let report = await h.cleaner([trashRule, docker]).clean([dockerItem, trashItem])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.detectionOnly, .detectionOnly])
        #expect(h.exists(".Trash/old.zip"))
        #expect(h.exists(".docker/buildx/cache/blob"))
    }

    @Test("An item with excluded paths is cleaned around them, never moved whole")
    func excludedChildrenStay() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.spotify.client/Browser/cache.bin", bytes: 6_000)
        try h.fixture.file("Library/Caches/com.spotify.client/Data/offline/song.file", bytes: 50_000)
        try h.fixture.file("Library/Caches/com.spotify.client/Storage/keep/inner.bin", bytes: 2_000)
        try h.fixture.file("Library/Caches/com.spotify.client/Storage/other.bin", bytes: 3_000)
        try h.fixture.file("Library/Caches/com.spotify.client/top.bin", bytes: 1_000)
        let rules = [
            Self.caches,
            Self.rule("spotify.music", paths: ["~/Library/Caches/com.spotify.client/Data"], risk: .never),
            Self.rule("keep.deep", paths: ["~/Library/Caches/com.spotify.client/Storage/keep"], risk: .never),
        ]
        let items = await h.scan(rules)
        let spotify = try #require(h.item(items, "Library/Caches/com.spotify.client"))
        #expect(spotify.excludedURLs.count == 2)

        let report = await h.cleaner(rules).clean([spotify])
        #expect(report.skipped.isEmpty)
        let moved = Set(report.moved.map { $0.original.lastPathComponent })
        #expect(moved == ["Browser", "other.bin", "top.bin"])
        #expect(h.exists("Library/Caches/com.spotify.client"))
        #expect(h.exists("Library/Caches/com.spotify.client/Data/offline/song.file"))
        #expect(h.exists("Library/Caches/com.spotify.client/Storage/keep/inner.bin"))
        #expect(!h.exists("Library/Caches/com.spotify.client/Browser"))
        #expect(!h.exists("Library/Caches/com.spotify.client/Storage/other.bin"))
        #expect(try await h.store.logs().count == 3)

        // And it all comes back.
        let undo = await h.cleaner(rules).undo(report.logIDs)
        #expect(undo.restored.count == 3)
        #expect(h.exists("Library/Caches/com.spotify.client/Storage/other.bin"))
    }

    @Test("Ignore entries (path and rule) are left out of scans but keep their claim")
    func ignoreRespectedByScanner() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.keep/a.bin", bytes: 2_000)
        try h.fixture.file("Library/Caches/com.example.other/b.bin", bytes: 2_000)
        try h.fixture.file("Library/Caches/Homebrew/downloads/pkg.tar.gz", bytes: 9_000)
        try h.fixture.file("Library/Caches/Homebrew/other.json", bytes: 2_000)
        try h.fixture.file("Library/Logs/old.log", bytes: 2_000)
        let brew = Self.rule("dev.brew", .dev, paths: ["~/Library/Caches/Homebrew/downloads"])
        let logs = Self.rule("logs.user", .logs, paths: ["~/Library/Logs"], globs: ["*"])
        let rules = [Self.caches, brew, logs]

        try await h.store.ignore(path: h.fixture.path("Library/Caches/com.example.keep").path)
        try await h.store.ignore(ruleID: "dev.brew")
        try await h.store.ignore(ruleID: "logs.user")
        let ignore = await h.store.ignoreList()
        #expect(ignore.ruleIDs == ["dev.brew", "logs.user"])

        let items = await h.scan(rules, ignore: ignore)
        #expect(h.item(items, "Library/Caches/com.example.keep") == nil)
        #expect(h.item(items, "Library/Caches/com.example.other") != nil)
        #expect(h.item(items, "Library/Caches/Homebrew/downloads") == nil)
        #expect(h.item(items, "Library/Logs/old.log") == nil)
        // The ignored rule still owns its folder: Homebrew is cleaned around it.
        let homebrew = try #require(h.item(items, "Library/Caches/Homebrew"))
        #expect(homebrew.excludedURLs.map(\.lastPathComponent) == ["downloads"])

        // Taking an entry off the list brings it back.
        let entries = try await h.store.ignoreEntries()
        let pathEntry = try #require(entries.first { $0.path != nil }?.id)
        try await h.store.removeIgnore(id: pathEntry)
        let again = await h.scan(rules, ignore: await h.store.ignoreList())
        #expect(h.item(again, "Library/Caches/com.example.keep") != nil)
    }

    @Test("Empty Trash deletes only the confirmed entries of the injected Trash folder")
    func emptyTrashTouchesOnlyInjectedTrash() async throws {
        let h = try Harness()
        defer { h.remove() }
        let fm = FileManager.default
        try h.fixture.file("x", bytes: 7_000, absolute: h.trash.appendingPathComponent("old.zip"))
        try h.fixture.file("x", bytes: 3_000, absolute: h.trash.appendingPathComponent("folder/inner.bin"))
        try h.fixture.file(".Trash/real-looking.zip", bytes: 1_000)  // the fake home's own .Trash
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 1_000)
        let sibling = h.trash.deletingLastPathComponent().appendingPathComponent("sibling.txt")
        try h.fixture.file("x", bytes: 100, absolute: sibling)
        let cleaner = h.cleaner([Self.caches])

        let summary = try await cleaner.trashSummary()
        #expect(Set(summary.names) == ["old.zip", "folder"])
        #expect(summary.bytes > 0)

        // Something arriving after the user confirmed is not deleted.
        try h.fixture.file("x", bytes: 500, absolute: h.trash.appendingPathComponent("later.txt"))
        let freed = try await cleaner.emptyTrash(summary).freedBytes

        #expect(freed == summary.bytes)
        #expect(try fm.contentsOfDirectory(atPath: h.trash.path) == ["later.txt"])
        #expect(fm.fileExists(atPath: sibling.path))
        #expect(h.exists(".Trash/real-looking.zip"))
        #expect(h.exists("Library/Caches/com.example.a/x.bin"))
    }

    @Test("Empty Trash refuses a trash folder that is the home folder or holds it")
    func emptyTrashRefusesHome() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 1_000)
        for directory in [h.fixture.url, h.fixture.url.deletingLastPathComponent()] {
            let cleaner = Cleaner(
                home: h.fixture.url, trashMover: TempTrashMover(trashDirectory: directory), store: h.store,
                protectedList: ProtectedList(home: h.fixture.url), rules: { [] })
            await #expect(throws: DustpanError.self) { try await cleaner.trashSummary() }
            await #expect(throws: DustpanError.self) {
                try await cleaner.emptyTrash(TrashSummary(names: ["home", "Library"], bytes: 0))
            }
        }
        #expect(h.exists("Library/Caches/com.example.a/x.bin"))
    }
}

// MARK: - Fix round 1: the Cleaner re-derives every rule match and distrusts links

extension CleanerTests {
    static func bundledRules(home: URL) throws -> [Rule] {
        let url = try #require(Bundle.main.url(forResource: "rules", withExtension: "json"))
        return try RuleCatalog.decode(try Data(contentsOf: url), protectedList: ProtectedList(home: home))
    }

    static func forged(_ url: URL, _ ruleID: String, _ category: JunkCategory = .userCache) -> ScanItem {
        ScanItem(
            id: UUID(), url: url, allocatedSize: 4_096, modified: .distantPast, category: category, ruleID: ruleID,
            risk: .safe, isSelected: true)
    }

    @Test("Home-rooted glob rules can't take Documents or Desktop (forged items)")
    func homeRootedGlobsRefuseFolders() async throws {
        let h = try Harness()
        defer { h.remove() }
        let rules = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file("Documents/thesis.txt", bytes: 2_000, ageDays: 60)
        try h.fixture.file("Desktop/photo.jpg", bytes: 2_000, ageDays: 60)
        try h.fixture.file("crash.hprof", bytes: 2_000, ageDays: 60)
        let items = [
            Self.forged(h.fixture.path("Documents"), "dev.hprof", .dev),
            Self.forged(h.fixture.path("Desktop"), "logs.wget", .logs),
            Self.forged(h.fixture.path("crash.hprof"), "logs.wget", .logs),
        ]
        let report = await h.cleaner(rules).clean(items)
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.ruleMismatch, .ruleMismatch, .ruleMismatch])
        #expect(h.exists("Documents/thesis.txt"))
        #expect(h.exists("Desktop/photo.jpg"))
        #expect(h.exists("crash.hprof"))

        // The real match still works.
        let real = await h.cleaner(rules).clean([Self.forged(h.fixture.path("crash.hprof"), "dev.hprof", .dev)])
        #expect(real.moved.count == 1)
    }

    @Test("An excluded name (com.apple.* under App caches) is refused for that rule")
    func excludeGlobRespected() async throws {
        let h = try Harness()
        defer { h.remove() }
        let rules = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file("Library/Caches/com.apple.Safari/blob", bytes: 3_000)
        let report = await h.cleaner(rules).clean([
            Self.forged(h.fixture.path("Library/Caches/com.apple.Safari"), "cache.apps")
        ])
        #expect(report.skipped.map(\.reason) == [.ruleMismatch])
        #expect(h.exists("Library/Caches/com.apple.Safari/blob"))
    }

    @Test("A more specific rule's item can't be taken through a broader rule (requiresQuit bypass)")
    func winningRuleRequired() async throws {
        let h = try Harness()
        defer { h.remove() }
        let rules = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file("Library/Caches/com.google.Chrome/Cache/data", bytes: 3_000)
        let report = await h.cleaner(rules, running: ["com.google.Chrome": "Google Chrome"]).clean([
            Self.forged(h.fixture.path("Library/Caches/com.google.Chrome"), "cache.apps")
        ])
        #expect(report.skipped.map(\.reason) == [.ruleMismatch])
        #expect(h.exists("Library/Caches/com.google.Chrome/Cache/data"))
    }

    @Test(".never places: refused when targeted, and kept when inside an item that lies about them")
    func neverContainment() async throws {
        let h = try Harness()
        defer { h.remove() }
        // Bundled catalogue: all of com.spotify.client is `.never`, under any rule.
        let bundled = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file("Library/Caches/com.spotify.client/Data/offline/song.file", bytes: 50_000)
        try h.fixture.file("Library/Caches/com.spotify.client/Browser/cache.bin", bytes: 6_000)
        for target in ["Library/Caches/com.spotify.client", "Library/Caches/com.spotify.client/Data"] {
            let report = await h.cleaner(bundled).clean([Self.forged(h.fixture.path(target), "cache.apps")])
            #expect(report.moved.isEmpty, "\(target)")
            #expect(report.skipped.map(\.reason) == [.ruleMismatch], "\(target)")
        }
        #expect(h.exists("Library/Caches/com.spotify.client/Browser/cache.bin"))

        // A catalogue where only Data is `.never`: an item with its `excludedURLs` wiped is
        // still cleaned around Data, because the Cleaner recomputes them from the catalogue.
        let rules = [
            Self.caches,
            Self.rule("spotify.music", paths: ["~/Library/Caches/com.spotify.client/Data"], risk: .never),
        ]
        let liar = Self.forged(h.fixture.path("Library/Caches/com.spotify.client"), "cache.apps")
        #expect(liar.excludedURLs.isEmpty)
        let report = await h.cleaner(rules).clean([liar])
        #expect(report.moved.map { $0.original.lastPathComponent } == ["Browser"])
        #expect(h.exists("Library/Caches/com.spotify.client/Data/offline/song.file"))
        #expect(!h.exists("Library/Caches/com.spotify.client/Browser"))
    }

    @Test("minAgeDays is checked again at clean time")
    func minAgeRechecked() async throws {
        let h = try Harness()
        defer { h.remove() }
        let logs = Self.rule("logs.user", .logs, paths: ["~/Library/Logs"], globs: ["*"])
        let aged = Rule(
            id: logs.id, title: logs.title, category: .logs, paths: logs.paths, globs: logs.globs, minAgeDays: 7,
            risk: .safe, why: "Test rule.")
        try h.fixture.file("Library/Logs/old.log", bytes: 2_000, ageDays: 30)
        let items = await h.scan([aged])
        let item = try #require(h.item(items, "Library/Logs/old.log"))
        // Written to again after the scan.
        try h.fixture.file("Library/Logs/old.log", bytes: 2_000, ageDays: 1)
        let report = await h.cleaner([aged]).clean([item])
        #expect(report.skipped.map(\.reason) == [.tooRecent])
        #expect(h.exists("Library/Logs/old.log"))
    }

    @Test("Empty Trash refuses a Trash that is a link (to Documents), and never follows links inside")
    func trashSymlinkRefused() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Documents/keep.txt", bytes: 2_000)
        try h.fixture.symlink(".Trash", to: h.fixture.path("Documents"))
        let cleaner = Cleaner(
            home: h.fixture.url, trashMover: FileManagerTrashMover(home: h.fixture.url), store: h.store,
            protectedList: ProtectedList(home: h.fixture.url), rules: { [] })
        await #expect(throws: DustpanError.self) { try await cleaner.trashSummary() }
        await #expect(throws: DustpanError.self) {
            try await cleaner.emptyTrash(TrashSummary(names: ["keep.txt"], bytes: 0))
        }
        #expect(h.exists("Documents/keep.txt"))

        // A link inside a real Trash: the link goes, its target stays.
        let trash = h.trash
        try FileManager.default.createSymbolicLink(
            at: trash.appendingPathComponent("docs-link"), withDestinationURL: h.fixture.path("Documents"))
        let real = h.cleaner([])
        let summary = try await real.trashSummary()
        #expect(summary.names == ["docs-link"])
        #expect(summary.bytes == 0)
        try await real.emptyTrash(summary)
        #expect(Cleaner.linkState(trash.appendingPathComponent("docs-link").path) == .missing)
        #expect(h.exists("Documents/keep.txt"))
    }

    @Test("The real Trash mover only accepts <home>/.Trash")
    func realTrashMustBeHomeTrash() async throws {
        let h = try Harness()
        defer { h.remove() }
        try FileManager.default.createDirectory(at: h.fixture.path(".Trash"), withIntermediateDirectories: true)
        try h.fixture.file(".Trash/old.zip", bytes: 1_000)
        let cleaner = Cleaner(
            home: h.fixture.url, trashMover: FileManagerTrashMover(home: h.fixture.url), store: h.store,
            protectedList: ProtectedList(home: h.fixture.url), rules: { [] })
        let summary = try await cleaner.trashSummary()
        #expect(summary.names == ["old.zip"])
    }

    @Test("A path swapped for a link between checking and moving is refused")
    func toctouSwapRefused() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/cache.bin", bytes: 3_000)
        let victim = h.fixture.outside.appendingPathComponent("victim", isDirectory: true)
        try h.fixture.file("x", bytes: 3_000, absolute: victim.appendingPathComponent("precious.txt"))
        let rule = Self.rule(
            "app.cache", paths: ["~/Library/Caches/com.example.app"], appBundleID: "com.example.app",
            requiresQuit: true)
        let items = await h.scan([rule])
        #expect(items.count == 1)
        let fixture = h.fixture
        // Runs after the item was resolved and checked, before the move.
        let swapper = SwappingRunningApps {
            let fm = FileManager.default
            try? fm.moveItem(
                at: fixture.path("Library/Caches"), to: fixture.outside.appendingPathComponent("moved-caches"))
            try? fm.createDirectory(
                at: fixture.outside.appendingPathComponent("evil"), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(
                at: victim.deletingLastPathComponent().appendingPathComponent("evil/com.example.app"),
                withDestinationURL: victim)
            try? fm.createSymbolicLink(
                at: fixture.path("Library/Caches"), withDestinationURL: fixture.outside.appendingPathComponent("evil"))
        }
        let cleaner = Cleaner(
            home: h.fixture.url, trashMover: TempTrashMover(trashDirectory: h.trash), runningApps: swapper,
            store: h.store, protectedList: ProtectedList(home: h.fixture.url), rules: { [rule] },
            now: { fixture.now })
        let report = await cleaner.clean(items)
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.changedDuringClean])
        #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.trash.path).isEmpty)
    }

    @Test("Undo refuses when a folder on the way back became a link")
    func undoParentLinkRefused() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 1_000)
        let cleaner = h.cleaner([Self.caches])
        let report = await cleaner.clean(await h.scan([Self.caches]))
        let id = try #require(report.logIDs.first)
        let elsewhere = h.fixture.outside.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: h.fixture.path("Library/Caches"), to: h.fixture.outside.appendingPathComponent("old-caches"))
        try h.fixture.symlink("Library/Caches", to: elsewhere)

        let undo = await cleaner.undo([id])
        #expect(undo.failed[id] == .unsafePath)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.trash.appendingPathComponent("com.example.a/x.bin").path))
    }
}

// MARK: - Fix round 2

extension CleanerTests {
    @Test("Items whose parent is the home folder clean and put back byte-identical")
    func homeParentUndo() async throws {
        let h = try Harness()
        defer { h.remove() }
        let rules = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file("heap.hprof", bytes: 33_333, ageDays: 30)
        try h.fixture.file(".node-gyp/22.9.0/include/node/node.h", bytes: 7_777, ageDays: 30)
        try h.fixture.file(".node-gyp/22.9.0/installVersion", bytes: 3, ageDays: 30)
        let heapBefore = try Data(contentsOf: h.fixture.path("heap.hprof"))
        let gypBefore = try Self.digest(h.fixture.path(".node-gyp"))
        let items = await h.scan(rules)
        let heap = try #require(h.item(items, "heap.hprof"))
        let gyp = try #require(h.item(items, ".node-gyp"))
        #expect(heap.ruleID == "dev.hprof")
        #expect(gyp.ruleID == "dev.node-gyp")

        let cleaner = h.cleaner(rules)
        let report = await cleaner.clean([heap, gyp])
        #expect(report.skipped.isEmpty)
        #expect(report.moved.count == 2)
        #expect(!h.exists("heap.hprof"))
        #expect(!h.exists(".node-gyp"))

        let undo = await cleaner.undo(report.logIDs)
        #expect(undo.failed.isEmpty, "\(undo)")
        #expect(Set(undo.restored) == Set(report.logIDs))
        #expect(try Data(contentsOf: h.fixture.path("heap.hprof")) == heapBefore)
        #expect(try Self.digest(h.fixture.path(".node-gyp")) == gypBefore)
    }

    @Test("Without Full Disk Access a forged item in Downloads is refused before it is touched")
    func noAccessRefusesGuardedFolders() async throws {
        let h = try Harness()
        defer { h.remove() }
        let rules = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file("Downloads/Tool.dmg", bytes: 30_000, ageDays: 30)
        let installer = try #require(
            rules.first { $0.paths.contains("~/Downloads") && $0.globs.contains { $0.contains("dmg") } })
        let item = Self.forged(h.fixture.path("Downloads/Tool.dmg"), installer.id, .installers)

        let without = await h.cleaner(rules, access: false).clean([item])
        #expect(without.moved.isEmpty)
        #expect(without.skipped.map(\.reason) == [.needsFullDiskAccess])
        #expect(h.exists("Downloads/Tool.dmg"))

        // A path that only spells its way into Downloads is treated the same.
        let sneaky = Self.forged(
            URL(fileURLWithPath: h.fixture.url.path + "/Library/../Downloads/Tool.dmg"), installer.id, .installers)
        let sneakyReport = await h.cleaner(rules, access: false).clean([sneaky])
        #expect(sneakyReport.skipped.map(\.reason) == [.needsFullDiskAccess])

        // With access, the same genuine item is cleaned.
        let with = await h.cleaner(rules, access: true).clean([item])
        #expect(with.moved.count == 1)
    }
}

// MARK: - Audit (2026-10-07)

extension CleanerTests {
    @Test("Hugging Face sign-in tokens beside its cache stay when ~/.cache/huggingface is cleaned")
    func huggingFaceTokensStay() async throws {
        let h = try Harness()
        defer { h.remove() }
        let rules = try Self.bundledRules(home: h.fixture.url)
        try h.fixture.file(".cache/huggingface/token", bytes: 40)
        try h.fixture.file(".cache/huggingface/stored_tokens", bytes: 120)
        try h.fixture.file(".cache/huggingface/assets/note.json", bytes: 3_000)
        try h.fixture.file(".cache/huggingface/hub/models--x/blob.bin", bytes: 30_000)

        let items = await h.scan(rules)
        // The tokens are never items of their own, and the folder around them leaves them out.
        #expect(h.item(items, ".cache/huggingface/token") == nil)
        #expect(h.item(items, ".cache/huggingface/stored_tokens") == nil)
        let folder = try #require(h.item(items, ".cache/huggingface"))
        let excluded = Set(folder.excludedURLs.map(\.lastPathComponent))
        #expect(excluded.isSuperset(of: ["token", "stored_tokens"]))

        let report = await h.cleaner(rules).clean([folder])
        #expect(report.logFailed == false)
        #expect(!h.exists(".cache/huggingface/assets"))
        #expect(h.exists(".cache/huggingface/token"))
        #expect(h.exists(".cache/huggingface/stored_tokens"))
        #expect(h.exists(".cache/huggingface/hub/models--x/blob.bin"))
    }

    @Test("An excluded file inside an item doesn't hide the next folder's files from size or age checks")
    func excludedFileKeepsSiblingsCounted() async throws {
        let h = try Harness()
        defer { h.remove() }
        let logs = Rule(
            id: "logs.tool", title: "Tool logs", category: .logs, paths: ["~/.tool"], globs: [], minAgeDays: 7,
            risk: .safe, why: "Test rule.")
        let keep = Rule(
            id: "tool.key.never", title: "Tool key", category: .logs, paths: ["~/.tool/key"], globs: [],
            risk: .never, why: "Test rule.")
        let rules = [logs, keep]
        let path = h.fixture.path(".tool").path
        try h.fixture.file(".tool/key", bytes: 100, ageDays: 60)
        var expected = try h.fixture.file(".tool/old.log", bytes: 4_000, ageDays: 60)
        for name in ["a-dir", "m-dir", "z-dir"] {
            expected += try h.fixture.file(".tool/\(name)/old.log", bytes: 4_000, ageDays: 60)
        }
        // The walk goes in the file system's own order (the same as `contentsOfDirectory`). Make sure
        // a folder comes after `key`, and put the one recent file in the first such folder: the one
        // the walk used to skip.
        func folderAfterKey() throws -> String? {
            try FileManager.default.contentsOfDirectory(atPath: path).drop { $0 != "key" }.dropFirst()
                .first { $0.hasSuffix("-dir") }
        }
        var extra = 0
        while try folderAfterKey() == nil, extra < 50 {
            expected += try h.fixture.file(".tool/extra\(extra)-dir/old.log", bytes: 4_000, ageDays: 60)
            extra += 1
        }
        let next = try #require(try folderAfterKey())
        expected += try h.fixture.file(".tool/\(next)/new.log", bytes: 4_000, ageDays: 1)

        let scanner = JunkScanner(rules: rules, home: h.fixture.url, now: h.fixture.now)
        let measured = try #require(
            await scanner.measure(path, excluding: [path.lowercased() + "/key"], checkDatabases: true))
        #expect(measured.bytes == expected)
        #expect(measured.newest > h.fixture.now.addingTimeInterval(-2 * 86_400))
        // Too recent for its 7 days, so the scan leaves it out …
        #expect(h.item(await h.scan(rules), ".tool") == nil)
        // … and the Cleaner refuses a forged item for the same reason.
        let report = await h.cleaner(rules).clean([Self.forged(h.fixture.path(".tool"), logs.id, .logs)])
        #expect(report.skipped.map(\.reason) == [.tooRecent])
        #expect(h.exists(".tool/\(next)/new.log"))
    }

    @Test("History tells an item put back with Finder from one whose Trash was emptied")
    func historyBackInPlace() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 8_000)
        try h.fixture.file("Library/Caches/com.example.b/y.bin", bytes: 8_000)
        let items = await h.scan([Self.caches])
        let cleaner = h.cleaner([Self.caches])
        let report = await cleaner.clean(items)
        #expect(report.moved.count == 2)
        let byName = Dictionary(uniqueKeysWithValues: report.moved.map { ($0.original.lastPathComponent, $0) })
        let a = try #require(byName["com.example.a"])
        let b = try #require(byName["com.example.b"])
        // Finder's Put Back for one, Empty Trash for the other.
        try FileManager.default.moveItem(at: a.trashed, to: a.original)
        try FileManager.default.removeItem(at: b.trashed)

        let statuses = Dictionary(
            uniqueKeysWithValues: try await cleaner.history().map {
                (URL(fileURLWithPath: $0.log.originalPath).lastPathComponent, $0.status)
            })
        #expect(statuses["com.example.a"] == .backInPlace)
        #expect(statuses["com.example.b"] == .gone)
    }
}

/// Calls `onCheck` the first time the Cleaner asks whether an app runs (after it has resolved
/// and checked the item), then says the app is closed.
final class SwappingRunningApps: RunningAppsChecking, @unchecked Sendable {
    private let onCheck: @Sendable () -> Void
    private let lock = NSLock()
    private var done = false

    init(onCheck: @escaping @Sendable () -> Void) { self.onCheck = onCheck }

    func runningAppName(bundleID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !done {
            done = true
            onCheck()
        }
        return nil
    }
}

@Suite("Junk and History models")
@MainActor
struct JunkFlowTests {
    @Test("Scan → clean → undo through the Junk model, then History lists it by day")
    func junkModelFlow() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000)
        try h.fixture.file("Library/Caches/com.example.young/b.bin", bytes: 4_000, ageDays: 1)
        let catalog = RuleCatalog()
        let cleaner = Cleaner(
            home: h.fixture.url, trashMover: TempTrashMover(trashDirectory: h.trash),
            runningApps: FakeRunningApps(), store: h.store, protectedList: ProtectedList(home: h.fixture.url),
            rules: { try await catalog.rules() })
        let model = JunkModel(catalog: catalog, cleaner: cleaner, store: h.store, home: h.fixture.url)

        await model.scan(hasFullDiskAccess: true)
        #expect(model.hasScanned)
        let old = try #require(model.allItems.first { $0.url.lastPathComponent == "com.example.app" })
        let young = try #require(model.allItems.first { $0.url.lastPathComponent == "com.example.young" })
        #expect(model.isSelected(old))
        #expect(!model.isSelected(young))  // safety rule 3: changed in the last 7 days
        #expect(model.summary.map(\.count) == [1])

        model.requestClean()
        #expect(model.isConfirming)
        await model.confirmClean()
        let report = try #require(model.lastReport)
        #expect(report.moved.count == 1)
        #expect(model.undoDeadline != nil)
        #expect(!model.allItems.contains { $0.id == old.id })
        #expect(!h.exists("Library/Caches/com.example.app"))

        let history = HistoryModel(cleaner: cleaner)
        await history.load()
        #expect(history.days.count == 1)
        #expect(history.days.first?.bytesInTrash == report.freedBytes)

        await model.undoLastClean()
        #expect(model.lastReport == nil)
        #expect(h.exists("Library/Caches/com.example.app/a.bin"))
        #expect(model.allItems.contains { $0.url.lastPathComponent == "com.example.app" })

        await history.load()
        guard case .restored = history.days.first?.entries.first?.status else {
            Issue.record("Expected the History row to be marked as put back")
            return
        }
    }

    @Test("Ignoring an item hides it now and on the next scan")
    func ignoreFromModel() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.app/a.bin", bytes: 12_000)
        let catalog = RuleCatalog()
        let cleaner = h.cleaner([])
        let model = JunkModel(catalog: catalog, cleaner: cleaner, store: h.store, home: h.fixture.url)
        await model.scan(hasFullDiskAccess: true)
        let item = try #require(model.allItems.first { $0.url.lastPathComponent == "com.example.app" })
        await model.ignore(item)
        #expect(!model.allItems.contains { $0.id == item.id })
        #expect(model.ignored.count == 1)
        await model.scan(hasFullDiskAccess: true)
        #expect(!model.allItems.contains { $0.url.lastPathComponent == "com.example.app" })
        await model.stopIgnoring(try #require(model.ignored.first))
        await model.scan(hasFullDiskAccess: true)
        #expect(model.allItems.contains { $0.url.lastPathComponent == "com.example.app" })
    }

    @Test("History groups entries by day, newest first")
    func historyGrouping() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        func entry(_ id: Int64, _ offset: TimeInterval, _ bytes: Int64) -> HistoryEntry {
            HistoryEntry(
                log: CleanupLog(
                    id: id, date: day.addingTimeInterval(offset), originalPath: "/x/\(id)", trashPath: "/t/\(id)",
                    bytes: bytes, ruleID: nil, restoredAt: nil),
                status: .inTrash)
        }
        let days = HistoryModel.group(
            [entry(1, 0, 10), entry(2, 60, 20), entry(3, -3 * 86_400, 5)], calendar: calendar)
        #expect(days.count == 2)
        #expect(days[0].entries.map(\.id) == [2, 1])
        #expect(days[0].totalBytes == 30)
        #expect(days[1].bytesInTrash == 5)
    }
}
