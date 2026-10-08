import Darwin
import Foundation
import Testing

@testable import Dustpan

/// Every scanner and the Cleaner must degrade gracefully — skip, report a reason, show a quiet
/// banner — never crash: folders they can't read (mode 000), files that vanish while they look,
/// a whole root that disappears mid-walk (what an ejected volume looks like to a walker), and
/// items gone before the move. Fixture trees in a temp folder only.
@Suite("Crash-proofing", .serialized)
struct CrashProofingTests {
    /// Makes `relative` unreadable (mode 000) until `restore` runs.
    static func lock(_ fixture: FixtureHome, _ relative: String) throws -> () -> Void {
        let url = fixture.path(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "x".write(to: url.appendingPathComponent("hidden.txt"), atomically: false, encoding: .utf8)
        chmod(url.path, 0)
        return { chmod(url.path, 0o755) }
    }

    /// A tree of `folders` × `files` small files under `relative`.
    static func bulk(_ fixture: FixtureHome, _ relative: String, folders: Int, files: Int) throws {
        let bytes = Data(repeating: 1, count: 128)
        for folder in 0..<folders {
            let dir = fixture.path("\(relative)/f\(folder)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<files { try bytes.write(to: dir.appendingPathComponent("\(file).bin")) }
        }
    }

    @Test("Unreadable folders: every scanner finishes and leaves them out")
    func unreadableFolders() async throws {
        let fixture = try FixtureHome()
        var restores: [() -> Void] = []
        defer {
            restores.forEach { $0() }
            fixture.remove()
        }
        try fixture.file("Library/Caches/com.example.ok/a.bin", bytes: 9_000)
        try fixture.file("Library/Caches/com.example.partly/a.bin", bytes: 9_000)
        restores.append(try Self.lock(fixture, "Library/Caches/com.example.partly/locked"))
        try fixture.file("Library/Logs/com.example.logs/old.log", bytes: 9_000, ageDays: 30)
        restores.append(try Self.lock(fixture, "Library/Logs/com.example.logs/locked"))
        restores.append(try Self.lock(fixture, "Library/Caches/com.example.locked"))
        try fixture.file("Documents/a.bin", bytes: 200_000)
        try fixture.file("Documents/b.bin", bytes: 200_000)
        restores.append(try Self.lock(fixture, "Documents/locked"))
        restores.append(try Self.lock(fixture, "Library/Preferences"))

        let rules = try await RuleCatalog().rules()
        let items = await JunkScanner(rules: rules, home: fixture.url, now: fixture.now).scan().flatMap(\.items)
        let names = Set(items.map(\.url.lastPathComponent))
        #expect(names.contains("com.example.ok"))
        // Outside Caches an unreadable part could hide an app database: left out (fails closed).
        #expect(!names.contains("com.example.logs"))

        let tree = try await DiskWalker(home: fixture.url, hasFullDiskAccess: { true }).walk(fixture.url)
        let locked = (0..<UInt32(tree.count)).filter { tree.path($0).hasSuffix("/locked") }
        #expect(!locked.isEmpty)
        #expect(locked.allSatisfy { tree.kind($0) == .unreadable })

        let duplicates = try await DuplicateFinder(home: fixture.url, hasFullDiskAccess: { true })
            .find([fixture.path("Documents")])
        #expect(duplicates.groups.count == 1)
        let large = try await LargeOldFinder(home: fixture.url, hasFullDiskAccess: { true }, index: nil)
            .find(minimumBytes: 1)
        #expect(large.files.contains { $0.url.lastPathComponent == "a.bin" })

        let matcher = LeftoverMatcher(home: fixture.url, systemLibrary: fixture.outside, hasFullDiskAccess: true)
        _ = matcher.orphans(installed: [], isKnownApp: { _ in false })
        _ = matcher.leftovers(
            for: AppIdentity(
                bundleID: "com.example.locked", teamID: nil, name: "Locked",
                url: fixture.outside.appendingPathComponent("Locked.app")),
            installed: [])
    }

    @Test("A folder the Cleaner can't fully read is not moved")
    func cleanerUnreadable() async throws {
        let h = try CleanerTests.Harness()
        var restore: () -> Void = {}
        defer {
            restore()
            h.remove()
        }
        let logRule = CleanerTests.rule("logs.user", .logs, paths: ["~/Library/Logs"], globs: ["*"])
        try h.fixture.file("Library/Logs/com.example.logs/old.log", bytes: 9_000, ageDays: 30)
        let items = await h.scan([logRule])
        let item = try #require(h.item(items, "Library/Logs/com.example.logs"))
        restore = try Self.lock(h.fixture, "Library/Logs/com.example.logs/locked")
        let report = await h.cleaner([logRule]).clean([item])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.protected])
        #expect(h.exists("Library/Logs/com.example.logs/old.log"))
    }

    @Test("Files vanishing while the scanners look: no crash", arguments: 0..<3)
    func vanishingFiles(round: Int) async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        try Self.bulk(fixture, "Library/Caches/com.example.churn", folders: 20, files: 100)
        try Self.bulk(fixture, "Documents/churn", folders: 20, files: 100)
        let churn = Task.detached {
            // Delete and recreate files and folders while the scans run.
            var n = 0
            while !Task.isCancelled {
                for folder in 0..<20 {
                    for root in ["Library/Caches/com.example.churn", "Documents/churn"] {
                        let dir = fixture.path("\(root)/f\(folder)")
                        if n % 2 == 0 {
                            try? FileManager.default.removeItem(at: dir)
                        } else {
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            try? Data(count: 200_000).write(to: dir.appendingPathComponent("big.bin"))
                        }
                    }
                }
                n += 1
            }
        }
        defer { churn.cancel() }
        let rules = try await RuleCatalog().rules()
        for _ in 0..<5 {
            _ = await JunkScanner(rules: rules, home: fixture.url, now: fixture.now).scan()
            _ = try? await DiskWalker(home: fixture.url, hasFullDiskAccess: { true }).walk(fixture.url)
            _ = try? await DuplicateFinder(home: fixture.url, hasFullDiskAccess: { true })
                .find([fixture.path("Documents")])
            _ = try? await LargeOldFinder(home: fixture.url, hasFullDiskAccess: { true }, index: nil)
                .find(minimumBytes: 1)
        }
        churn.cancel()
        _ = await churn.value
    }

    /// What an ejected volume looks like to a walker: the root and everything in it disappear.
    @Test("The root disappearing mid-walk ends the walk quietly")
    func rootVanishes() async throws {
        let fixture = try FixtureHome()
        defer { fixture.remove() }
        let root = fixture.path("Volume")
        try Self.bulk(fixture, "Volume", folders: 200, files: 50)
        let walker = DiskWalker(home: fixture.url, hasFullDiskAccess: { true })
        let walk = Task { try await walker.walk(root) }
        let finder = DuplicateFinder(home: fixture.url, hasFullDiskAccess: { true })
        let duplicates = Task { try await finder.find([root]) }
        try await Task.sleep(for: .milliseconds(5))
        try FileManager.default.removeItem(at: root)
        // Either a (partial) map or an error; never a crash.
        if let tree = try? await walk.value { #expect(tree.count >= 1) }
        _ = try? await duplicates.value
        // And looking at a root that's already gone.
        let gone = try? await walker.walk(root)
        #expect(gone == nil || gone!.count <= 1)
        let none = try await finder.find([root])
        #expect(none.groups.isEmpty)
        let junk = await JunkScanner(
            rules: [CleanerTests.rule("x", paths: ["~/Volume"], globs: ["*"])], home: fixture.url
        ).scan()
        #expect(junk.isEmpty)
    }

    @Test("The Sweep still finishes, offering nothing, when the home folder vanishes")
    @MainActor
    func sweepWhenHomeVanishes() async throws {
        let h = try SweepHarness()
        defer { h.remove() }
        try h.populate()
        let state = await h.appState()
        try FileManager.default.removeItem(at: h.fixture.url)
        await state.sweep.sweep()
        #expect(state.sweep.phase == .results)
        #expect(state.sweep.recommendedItems.isEmpty)
        await state.sweep.confirmClean()
        #expect(state.sweep.lastReport == nil || state.sweep.lastReport?.moved.isEmpty == true)
    }

    @Test("Items gone before the move are skipped as already gone")
    func goneBeforeMove() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 9_000)
        try h.fixture.file("Library/Caches/com.example.b/y.bin", bytes: 9_000)
        let items = await h.scan([CleanerTests.caches])
        let a = try #require(h.item(items, "Library/Caches/com.example.a"))
        let b = try #require(h.item(items, "Library/Caches/com.example.b"))
        try FileManager.default.removeItem(at: a.url)
        let report = await h.cleaner([CleanerTests.caches]).clean([a, b])
        #expect(report.skipped.map(\.reason) == [.notFound])
        #expect(report.moved.map(\.itemID) == [b.id])
        #expect(try await h.store.logs().count == 1)

        // Space map, Large & old and Duplicates on files that are gone.
        let cleaner = h.cleaner([CleanerTests.caches])
        let gone = h.fixture.path("Documents/gone.bin")
        #expect(await cleaner.trashUserChosen(gone).skipped.map(\.reason) == [.notFound])
        #expect(await cleaner.trashLargeFiles([gone]).skipped.map(\.reason) == [.notFound])
        let keeper = h.fixture.path("Documents/keeper.bin")
        try h.fixture.file("Documents/keeper.bin", bytes: 200_000)
        let dup = await cleaner.trashDuplicates([DuplicateRemoval(url: gone, keeper: keeper, hash: 1, size: 200_000)])
        #expect(dup.moved.isEmpty && dup.skipped.count == 1)
        // Undo of something no longer in the Trash.
        let logID = try #require(report.logIDs.first)
        try FileManager.default.removeItem(at: report.moved[0].trashed)
        let undo = await cleaner.undo([logID])
        #expect(undo.failed[logID] == .notInTrash)
    }

    /// The item vanishes between the Cleaner's last check and the move itself.
    @Test("An item that vanishes during the move is reported, not logged")
    func vanishesDuringMove() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        try h.fixture.file("Library/Caches/com.example.a/x.bin", bytes: 9_000)
        let items = await h.scan([CleanerTests.caches])
        let a = try #require(h.item(items, "Library/Caches/com.example.a"))
        struct VanishingMover: TrashMover {
            let inner: TempTrashMover
            var trashDirectory: URL { inner.trashDirectory }
            func trash(_ url: URL) throws -> URL {
                try FileManager.default.removeItem(at: url)
                return try inner.trash(url)
            }
        }
        let cleaner = Cleaner(
            home: h.fixture.url, trashMover: VanishingMover(inner: TempTrashMover(trashDirectory: h.trash)),
            store: h.store, protectedList: ProtectedList(home: h.fixture.url), rules: { [CleanerTests.caches] },
            now: { h.fixture.now })
        let report = await cleaner.clean([a])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.moveFailed])
        #expect(try await h.store.logs().isEmpty)
    }
}
