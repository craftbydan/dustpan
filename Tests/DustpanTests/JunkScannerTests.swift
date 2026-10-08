import Foundation
import Testing

@testable import Dustpan

@Suite("Junk scanner")
struct JunkScannerTests {
    private func bundledRules(home: URL) throws -> [Rule] {
        let url = try #require(Bundle.main.url(forResource: "rules", withExtension: "json"))
        return try RuleCatalog.decode(try Data(contentsOf: url), protectedList: ProtectedList(home: home))
    }

    private func rule(
        _ id: String, _ category: JunkCategory = .userCache, paths: [String], globs: [String] = [],
        exclude: [String] = [], minAge: Int = 0, risk: Risk = .safe
    ) -> Rule {
        Rule(
            id: id, title: id, category: category, paths: paths, globs: globs, excludeGlobs: exclude,
            minAgeDays: minAge, risk: risk, why: "Test rule.")
    }

    private func scan(_ rules: [Rule], _ fixture: FixtureHome) async -> [ScanResult] {
        await JunkScanner(rules: rules, home: fixture.url, now: fixture.now).scan()
    }

    private func items(_ results: [ScanResult]) -> [ScanItem] { results.flatMap(\.items) }

    private func item(_ results: [ScanResult], _ fixture: FixtureHome, _ relative: String) -> ScanItem? {
        let path = fixture.path(relative).path.lowercased()
        return items(results).first { $0.url.path.lowercased() == path }
    }

    @Test("Bundled rules on a fixture home: categories, byte totals, selection, exclusions")
    func fixtureHome() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        var expected: [JunkCategory: Int64] = [:]

        // userCache: one old app cache (selected), one young (shown, not selected).
        expected[.userCache, default: 0] += try f.file("Library/Caches/com.example.app/a.bin", bytes: 10_000)
        expected[.userCache, default: 0] += try f.file("Library/Caches/com.example.app/sub/b.bin", bytes: 50_000)
        expected[.userCache, default: 0] += try f.file(
            "Library/Caches/com.example.young/y.bin", bytes: 4_000, ageDays: 1)
        // A .db inside a Caches folder is fine.
        expected[.userCache, default: 0] += try f.file("Library/Caches/com.example.db/index.db", bytes: 3_000)
        // com.apple.* caches are .review.
        expected[.userCache, default: 0] += try f.file("Library/Caches/com.apple.example/x.bin", bytes: 8_000)
        // An Electron update folder goes to installers (`*.ShipIt` beats `*`) once 14 days old.
        expected[.installers, default: 0] += try f.file(
            "Library/Caches/com.example.app.ShipIt/update.zip", bytes: 21_000, ageDays: 20)
        // .never: Spotify offline music and LM Studio models never appear.
        try f.file("Library/Caches/com.spotify.client/Data/song.file", bytes: 100_000)
        try f.file(".cache/lm-studio/models/model.gguf", bytes: 100_000)
        // Homebrew downloads belong to dev; the rest of Homebrew stays in userCache.
        expected[.dev, default: 0] += try f.file("Library/Caches/Homebrew/downloads/pkg.tar.gz", bytes: 40_000)
        expected[.userCache, default: 0] += try f.file("Library/Caches/Homebrew/other.json", bytes: 6_000)
        // logs: old kept, new (< 7 days) left out by minAgeDays.
        expected[.logs, default: 0] += try f.file("Library/Logs/old.log", bytes: 5_000)
        try f.file("Library/Logs/new.log", bytes: 5_000, ageDays: 2)
        expected[.logs, default: 0] += try f.file("Library/Logs/DiagnosticReports/App-2026.ips", bytes: 7_000)
        // savedState
        expected[.savedState, default: 0] += try f.file(
            "Library/Saved Application State/com.example.app.savedState/data.data", bytes: 3_000)
        // installers: 20 days old shown (review); 3 days old left out (minAge 14).
        expected[.installers, default: 0] += try f.file("Downloads/Tool.dmg", bytes: 30_000, ageDays: 20)
        try f.file("Downloads/Fresh.dmg", bytes: 30_000, ageDays: 3)
        try f.file("Downloads/notes.txt", bytes: 2_000)
        // xcode, dev, ai
        expected[.xcode, default: 0] += try f.file(
            "Library/Developer/Xcode/DerivedData/Proj-abc/Build/x.o", bytes: 70_000)
        expected[.dev, default: 0] += try f.file(".npm/_cacache/content-v2/x", bytes: 12_000)
        expected[.ai, default: 0] += try f.file(".cache/uv/wheels/x.whl", bytes: 9_000)
        expected[.userCache, default: 0] += try f.file(".cache/other/x", bytes: 2_000)
        // Symlinks: never followed, never counted.
        try f.file("big.bin", bytes: 200_000, absolute: f.outside.appendingPathComponent("big.bin"))
        try f.symlink("Library/Caches/com.example.app/link", to: f.outside.appendingPathComponent("big.bin"))
        try f.symlink("Library/Caches/elsewhere", to: f.outside)
        // Protected place no rule should ever reach.
        try f.file("Library/Mail/V10/msg.emlx", bytes: 9_000)

        let results = await scan(try bundledRules(home: f.url), f)
        var actual: [JunkCategory: Int64] = [:]
        for result in results {
            actual[result.category] = result.totalBytes
            #expect(result.totalBytes == result.items.reduce(0) { $0 + $1.allocatedSize })
            #expect(result.items.map(\.allocatedSize) == result.items.map(\.allocatedSize).sorted(by: >))
        }
        #expect(actual == expected)

        let all = items(results)
        // No byte counted twice: every item path is unique and no item's counted bytes overlap.
        #expect(Set(all.map { $0.url.path.lowercased() }).count == all.count)
        #expect(all.reduce(0) { $0 + $1.allocatedSize } == expected.values.reduce(0, +))

        #expect(item(results, f, "Library/Caches/com.example.app")?.isSelected == true)
        #expect(item(results, f, "Library/Caches/com.example.app")?.ruleID == "cache.apps")
        #expect(item(results, f, "Library/Caches/com.example.young")?.isSelected == false)
        #expect(item(results, f, "Library/Caches/com.apple.example")?.risk == .review)
        #expect(item(results, f, "Library/Caches/com.apple.example")?.isSelected == false)
        #expect(item(results, f, "Downloads/Tool.dmg")?.risk == .review)
        #expect(item(results, f, "Downloads/Tool.dmg")?.isSelected == false)
        #expect(item(results, f, "Downloads/Fresh.dmg") == nil)
        #expect(item(results, f, "Library/Logs/new.log") == nil)
        #expect(item(results, f, "Library/Caches/Homebrew/downloads")?.category == .dev)
        let homebrew = item(results, f, "Library/Caches/Homebrew")
        #expect(homebrew?.category == .userCache)
        #expect(homebrew?.excludedURLs.map(\.lastPathComponent) == ["downloads"])
        #expect(item(results, f, "Library/Caches/elsewhere") == nil)
        #expect(item(results, f, "Library/Caches/com.example.app.ShipIt")?.ruleID == "installers.shipit")

        // .never paths never appear, and nothing inside them either.
        #expect(!all.contains { $0.url.path.localizedCaseInsensitiveContains("com.spotify.client") })
        #expect(!all.contains { $0.url.path.localizedCaseInsensitiveContains("lm-studio") })
        #expect(!all.contains { $0.risk == .never })
        // Nothing protected comes back, by the full check either.
        let protectedList = ProtectedList(home: f.url)
        #expect(!all.contains { protectedList.isProtected($0.url) })
        // Nothing from outside the fake home.
        #expect(all.allSatisfy { PathTools.isInside($0.url.path, root: f.url.path) })
    }

    @Test("Items modified within 7 days are never pre-selected; .review never is")
    func selection() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        try f.file("Library/Caches/old/a", bytes: 1_000, ageDays: 8)
        try f.file("Library/Caches/sixdays/a", bytes: 1_000, ageDays: 6.9)
        try f.file("Library/Caches/mixed/old", bytes: 1_000, ageDays: 60)
        try f.file("Library/Caches/mixed/new", bytes: 1_000, ageDays: 0.1)
        try f.file("Library/Review/old/a", bytes: 1_000, ageDays: 90)
        let rules = [
            rule("safe", paths: ["~/Library/Caches"], globs: ["*"]),
            rule("review", paths: ["~/Library/Review"], globs: ["*"], risk: .review),
        ]
        let results = await scan(rules, f)
        #expect(item(results, f, "Library/Caches/old")?.isSelected == true)
        #expect(item(results, f, "Library/Caches/sixdays")?.isSelected == false)
        #expect(item(results, f, "Library/Caches/mixed")?.isSelected == false)  // newest file decides
        #expect(item(results, f, "Library/Review/old")?.isSelected == false)
    }

    @Test("Protected paths are never returned, even when a rule reaches them")
    func protectedNeverReturned() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        try f.file("Library/Mail/V10/msg.emlx", bytes: 9_000)
        try f.file("Library/Keychains/login.keychain-db", bytes: 9_000)
        try f.file("Library/Mobile Documents/com~apple~CloudDocs/doc.pages", bytes: 9_000)
        try f.file("Library/Containers/com.apple.Notes/Data/x", bytes: 9_000)
        try f.file("Library/Group Containers/group.com.apple.notes/x", bytes: 9_000)
        try f.file("Library/Application Support/MobileSync/Backup/x", bytes: 9_000)
        try f.file("Library/Application Support/DBApp/library.sqlite", bytes: 9_000)
        try f.file("Library/Application Support/DeepDB/a/b/c/d/e/store.realm", bytes: 9_000)
        try f.file("Pictures/Photos Library.photoslibrary/database/x", bytes: 9_000)
        let fine = try f.file("Library/Application Support/Plain/x.json", bytes: 9_000)
        try f.symlink("Library/Application Support/MailLink", to: f.path("Library/Mail"))
        let rules = [
            rule("library", paths: ["~/Library"], globs: ["*"]),
            rule("appsupport", paths: ["~/Library/Application Support"], globs: ["*"]),
            rule("containers", paths: ["~/Library/Containers", "~/Library/Group Containers"], globs: ["*"]),
            rule("pictures", paths: ["~/Pictures"], globs: ["*"]),
        ]
        let results = await scan(rules, f)
        let paths = items(results).map { $0.url.path.replacingOccurrences(of: f.url.path + "/", with: "") }
        // Only the plain folder survives; Library/Caches etc. don't exist here.
        #expect(paths == ["Library/Application Support/Plain"])
        #expect(results.first?.totalBytes == fine)
    }

    @Test("Unreadable subfolders outside Caches drop the item; inside Caches they don't")
    func unreadableSubfolders() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        try f.file("Library/Application Support/Locked/readable.json", bytes: 4_000)
        try f.file("Library/Application Support/Locked/secret/x.json", bytes: 4_000)
        let plain = try f.file("Library/Application Support/Plain/x.json", bytes: 4_000)
        let cacheReadable = try f.file("Library/Caches/com.example/readable.bin", bytes: 4_000)
        try f.file("Library/Caches/com.example/secret/x.bin", bytes: 4_000)
        let lockedDirs = [
            f.path("Library/Application Support/Locked/secret"), f.path("Library/Caches/com.example/secret"),
        ]
        for dir in lockedDirs {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        }
        defer {
            for dir in lockedDirs {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
        }
        let rules = [
            rule("appsupport", paths: ["~/Library/Application Support"], globs: ["*"]),
            rule("caches", paths: ["~/Library/Caches"], globs: ["*"]),
        ]
        let results = await scan(rules, f)
        #expect(item(results, f, "Library/Application Support/Locked") == nil)
        #expect(item(results, f, "Library/Application Support/Plain")?.allocatedSize == plain)
        #expect(item(results, f, "Library/Caches/com.example")?.allocatedSize == cacheReadable)
    }

    @Test("Detection-only items are never selected and carry the flag")
    func detectionOnlyItems() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        try f.file("Library/Containers/com.docker.docker/Data/vms/0/Docker.raw", bytes: 9_000, ageDays: 60)
        let docker = Rule(
            id: "docker", title: "Docker", category: .dev,
            paths: ["~/Library/Containers/com.docker.docker/Data/vms"], risk: .safe, why: "Test.",
            detectionOnly: true)
        let results = await scan([docker], f)
        let found = item(results, f, "Library/Containers/com.docker.docker/Data/vms")
        #expect(found?.detectionOnly == true)
        #expect(found?.isSelected == false)
    }

    @Test("Most specific rule wins and nested items are not double counted")
    func precedence() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        let outer = try f.file("root/app/outer.bin", bytes: 5_000)
        let inner = try f.file("root/app/inner/deep.bin", bytes: 11_000)
        let never = try f.file("root/app/music/song", bytes: 13_000)
        let same = try f.file("root/shared/x", bytes: 17_000)
        _ = never
        let rules = [
            rule("broad", paths: ["~/root"], globs: ["*"]),
            rule("inner", .dev, paths: ["~/root/app/inner"]),
            rule("music", paths: ["~/root/app/music"], risk: .never),
            rule("shared.specific", .ai, paths: ["~/root/shared"], risk: .review),
        ]
        let results = await scan(rules, f)
        #expect(item(results, f, "root/app")?.allocatedSize == outer)
        #expect(item(results, f, "root/app")?.excludedURLs.count == 2)
        #expect(item(results, f, "root/app/inner")?.allocatedSize == inner)
        #expect(item(results, f, "root/app/music") == nil)
        #expect(item(results, f, "root/shared")?.ruleID == "shared.specific")
        #expect(items(results).reduce(0) { $0 + $1.allocatedSize } == outer + inner + same)
    }

    @Test("Precedence order: never, then deeper root, then review, then catalogue order")
    func beats() {
        typealias C = JunkScanner.Candidate
        let never = C(ruleIndex: 9, ruleID: "r9", path: "/h/a", specificity: 1, risk: .never)
        let deep = C(ruleIndex: 5, ruleID: "r5", path: "/h/a", specificity: 3, risk: .safe)
        let shallow = C(ruleIndex: 0, ruleID: "r0", path: "/h/a", specificity: 2, risk: .safe)
        let review = C(ruleIndex: 7, ruleID: "r7", path: "/h/a", specificity: 2, risk: .review)
        #expect(JunkScanner.beats(never, deep))
        #expect(JunkScanner.beats(deep, shallow))
        #expect(JunkScanner.beats(review, shallow))
        let literalGlob = C(ruleIndex: 8, ruleID: "r8", path: "/h/a", specificity: 2, globSpecificity: 6, risk: .safe)
        let starGlob = C(ruleIndex: 0, ruleID: "r0", path: "/h/a", specificity: 2, globSpecificity: 0, risk: .review)
        #expect(JunkScanner.beats(literalGlob, starGlob))
        #expect(JunkScanner.beats(deep, literalGlob))
        #expect(JunkScanner.beats(shallow, C(ruleIndex: 1, ruleID: "r1", path: "/h/a", specificity: 2, risk: .safe)))
    }

    @Test("Rule roots reached through a symlink, or outside home, are refused")
    func symlinkedRoots() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        try f.file("x", bytes: 50_000, absolute: f.outside.appendingPathComponent("cache/x"))
        try f.symlink("linked", to: f.outside.appendingPathComponent("cache"))
        try f.file("real/sub/x", bytes: 1_000)
        try f.symlink("alias", to: f.path("real"))
        let rules = [
            rule("linked", paths: ["~/linked"]),
            rule("linked.children", paths: ["~/linked"], globs: ["*"]),
            rule("alias", paths: ["~/alias"], globs: ["*"]),
        ]
        #expect(await scan(rules, f).isEmpty)
    }

    @Test("Wildcard path components expand")
    func wildcardPaths() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        let a = try f.file("Library/Developer/CoreSimulator/Devices/AAA/data/Library/Caches/c1/x", bytes: 3_000)
        let b = try f.file("Library/Developer/CoreSimulator/Devices/BBB/data/Library/Caches/c2/x", bytes: 4_000)
        let results = await scan(try bundledRules(home: f.url), f)
        #expect(results.map(\.category) == [.xcode])
        #expect(results.first?.totalBytes == a + b)
    }

    @Test("Progress reports every item and finishes")
    func progress() async throws {
        let f = try FixtureHome()
        defer { f.remove() }
        for index in 0..<5 { try f.file("Library/Caches/app\(index)/x", bytes: 1_000) }
        let scanner = JunkScanner(
            rules: [rule("all", paths: ["~/Library/Caches"], globs: ["*"])], home: f.url, now: f.now)
        let (stream, continuation) = AsyncStream.makeStream(of: ScanProgress.self)
        async let results = scanner.scan(progress: continuation)
        var updates: [ScanProgress] = []
        for await update in stream { updates.append(update) }
        #expect(await results.first?.items.count == 5)
        #expect(updates.first?.phase == .matching)
        #expect(updates.last?.phase == .finished)
        #expect(updates.last?.fraction == 1)
        #expect(updates.filter { $0.phase == .measuring }.count == 5)
    }
}
