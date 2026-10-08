import Foundation
import Testing

@testable import Dustpan

@Suite("Scanning without Full Disk Access")
struct FullDiskAccessScanTests {
    private func bundledRules(home: URL) throws -> [Rule] {
        let url = try #require(Bundle.main.url(forResource: "rules", withExtension: "json"))
        return try RuleCatalog.decode(try Data(contentsOf: url), protectedList: ProtectedList(home: home))
    }

    private func fixture() throws -> FixtureHome {
        let f = try FixtureHome()
        try f.file("Library/Caches/com.example.app/a.bin", bytes: 10_000)
        try f.file("Library/Logs/old.log", bytes: 5_000)
        try f.file(".npm/_cacache/content-v2/x", bytes: 12_000)
        try f.file("Downloads/Tool.dmg", bytes: 30_000, ageDays: 20)
        try f.file("Desktop/Setup.pkg", bytes: 30_000, ageDays: 20)
        try f.file(".Trash/old.txt", bytes: 9_000)
        try f.file("Library/Containers/com.docker.docker/Data/vms/0/disk.raw", bytes: 40_000)
        try f.file("Library/Containers/com.docker.docker/Data/log/vm.log", bytes: 4_000)
        try f.file("Library/Application Support/Google/Chrome/Default/GPUCache/data_0", bytes: 6_000)
        try f.file("Library/Application Support/discord/Cache/x", bytes: 6_000)
        // Spotify's offline music: carved out by a `.never` rule that also has an App Support path.
        try f.file("Library/Caches/com.spotify.client/Data/song.file", bytes: 50_000)
        return f
    }

    @Test("Bundled catalogue marks the Trash, Downloads, Desktop and Docker rules")
    func bundledFlags() throws {
        let rules = try bundledRules(home: URL(fileURLWithPath: "/Users/fixture"))
        let flagged = Set(rules.filter(\.needsFullDiskAccess).map(\.id))
        for id in [
            "trash.home", "installers.dmg", "installers.pkg", "installers.zip", "installers.xip",
            "installers.desktop", "logs.docker", "dev.docker.disk", "dev.docker.cache", "cache.chrome.gpu",
            "cache.discord", "ai.vscode.cacheddata",
        ] {
            #expect(flagged.contains(id), "\(id)")
        }
        #expect(!flagged.contains("cache.apps"))
        #expect(!flagged.contains("cache.chrome"))
        #expect(!flagged.contains("logs.user"))
        for rule in rules where rule.paths.contains(where: FullDiskAccessPaths.requiresAccess) {
            #expect(rule.needsFullDiskAccess, "\(rule.id)")
        }
    }

    @Test("Validation rejects a protected-folder rule without needsFullDiskAccess")
    func validationRequiresFlag() {
        let protectedList = ProtectedList(home: URL(fileURLWithPath: "/Users/fixture"))
        let missing = Rule(
            id: "x", title: "x", category: .installers, paths: ["~/Downloads"], globs: ["*.dmg"], risk: .review,
            why: "Test.")
        #expect(throws: DustpanError.self) { try RuleCatalog.validate([missing], protectedList: protectedList) }
        let flagged = Rule(
            id: "x", title: "x", category: .installers, paths: ["~/Downloads"], globs: ["*.dmg"], risk: .review,
            why: "Test.", needsFullDiskAccess: true)
        #expect(throws: Never.self) { try RuleCatalog.validate([flagged], protectedList: protectedList) }

        for path in ["~/Library/Application Support/Slack/Cache", "~/Library/CloudStorage/x", "~/Documents/x"] {
            let unmarked = Rule(id: "y", title: "y", category: .userCache, paths: [path], risk: .safe, why: "Test.")
            #expect(throws: DustpanError.self, "\(path)") {
                try RuleCatalog.validate([unmarked], protectedList: protectedList)
            }
        }
        // A skippable rule must not mix access-only and ordinary paths (only `.never` may).
        let mixed = Rule(
            id: "z", title: "z", category: .userCache,
            paths: ["~/Library/Caches/com.example", "~/Library/Application Support/Example/Cache"], risk: .safe,
            why: "Test.", needsFullDiskAccess: true)
        #expect(throws: DustpanError.self) { try RuleCatalog.validate([mixed], protectedList: protectedList) }
        let mixedNever = Rule(
            id: "z", title: "z", category: .userCache,
            paths: ["~/Library/Caches/com.example", "~/Library/Application Support/Example/Cache"], risk: .never,
            why: "Test.", needsFullDiskAccess: true)
        #expect(throws: Never.self) { try RuleCatalog.validate([mixedNever], protectedList: protectedList) }
    }

    @Test("Without access: caches still scanned, access-only rules skipped and reported")
    func skipsWithoutAccess() async throws {
        let f = try fixture()
        defer { f.remove() }
        let rules = try bundledRules(home: f.url)

        let scanner = JunkScanner(rules: rules, home: f.url, now: f.now, hasFullDiskAccess: false)
        let results = await scanner.scan()
        let paths = results.flatMap(\.items).map { $0.url.path.lowercased() }

        #expect(paths.contains(f.path("Library/Caches/com.example.app").path.lowercased()))
        #expect(paths.contains(f.path("Library/Logs/old.log").path.lowercased()))
        #expect(paths.contains(f.path(".npm/_cacache").path.lowercased()))
        for blocked in ["Downloads", "Desktop", ".Trash", "Library/Containers", "Library/Application Support"] {
            let prefix = f.path(blocked).path.lowercased()
            #expect(!paths.contains { $0.hasPrefix(prefix) }, "\(blocked)")
        }
        #expect(!results.contains { $0.category == .trash })
        #expect(!results.contains { $0.category == .installers })

        let skippedIDs = Set(scanner.skipped.map(\.ruleID))
        #expect(skippedIDs == Set(rules.filter { $0.needsFullDiskAccess && $0.risk != .never }.map(\.id)))
        #expect(scanner.skipped.allSatisfy { $0.reason == .needsFullDiskAccess })
        #expect(!skippedIDs.contains("cache.spotify.never"))
        // The `.never` carve-out still holds without access: Spotify's offline music never appears.
        #expect(!paths.contains { $0.hasPrefix(f.path("Library/Caches/com.spotify.client").path.lowercased()) })
        #expect(Set(scanner.skipped.map(\.category)).isSuperset(of: [.trash, .installers, .dev, .logs, .userCache]))
    }

    @Test("With access: the same rules run and nothing is skipped")
    func runsWithAccess() async throws {
        let f = try fixture()
        defer { f.remove() }
        let scanner = JunkScanner(rules: try bundledRules(home: f.url), home: f.url, now: f.now)
        let results = await scanner.scan()
        #expect(scanner.skipped.isEmpty)
        #expect(results.contains { $0.category == .trash })
        #expect(results.contains { $0.category == .installers })
        let paths = results.flatMap(\.items).map { $0.url.path.lowercased() }
        #expect(paths.contains(f.path("Library/Containers/com.docker.docker/Data/vms").path.lowercased()))
    }

    @Test("JunkModel reports skipped categories for the UI")
    @MainActor
    func modelCounts() async throws {
        let f = try fixture()
        defer { f.remove() }
        let catalog = RuleCatalog(protectedList: ProtectedList(home: f.url))
        let store = CleanupStore(database: nil)
        let cleaner = Cleaner(
            home: f.url, trashMover: TempTrashMover(trashDirectory: f.outside), store: store, rules: { [] })
        let model = JunkModel(catalog: catalog, cleaner: cleaner, store: store, home: f.url)
        await model.scan(hasFullDiskAccess: false)
        #expect(model.issue == nil)
        let rules = try await RuleCatalog(protectedList: ProtectedList(home: f.url)).rules()
        let expected = Set(rules.filter { $0.needsFullDiskAccess && $0.risk != .never }.map(\.category)).sorted()
        #expect(model.skippedCategories == expected)
        #expect(model.skippedCategories.contains(.trash))
        #expect(model.totalBytes > 0)
    }
}
