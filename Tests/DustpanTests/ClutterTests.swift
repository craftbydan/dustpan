import Darwin
import Foundation
import Testing

@testable import Dustpan

/// Pretends the listed paths are cloud placeholders.
struct FakeCloud: CloudStatusChecking {
    var paths: Set<String> = []
    func isCloudOnly(_ url: URL, facts: FileFacts) -> Bool { facts.isDataless || paths.contains(url.path) }
}

/// A Spotlight stand-in that returns fixed hits.
struct FakeIndex: LargeFileIndex {
    var hits: [IndexedFile] = []
    func largeFiles(in scopes: [String], minimumBytes: Int64) -> [IndexedFile] {
        hits.filter { hit in scopes.contains { PathTools.isInside(hit.path, root: $0) } && hit.size >= minimumBytes }
    }
}

/// Fixture helpers for the Clutter tests: temp home, Trash and database only.
struct ClutterHarness {
    let fixture: FixtureHome
    let trash: URL
    let store: CleanupStore

    init() throws {
        fixture = try FixtureHome()
        let container = fixture.outside.deletingLastPathComponent()
        trash = container.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        store = CleanupStore(database: try AppDatabase(directory: container.appendingPathComponent("db")))
    }

    var home: URL { fixture.url }
    func path(_ relative: String) -> URL { fixture.path(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative).path) }

    /// `count` bytes of a pattern decided by `seed`.
    static func content(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ Int(seed) &* 17 &+ ($0 >> 9)) })
    }

    @discardableResult
    func write(_ relative: String, _ data: Data, createdDaysAgo: Double? = nil) throws -> URL {
        let url = path(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let createdDaysAgo {
            let date = fixture.now.addingTimeInterval(-createdDaysAgo * 86_400)
            try FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        return url
    }

    func finder(access: Bool = true, cloud: FakeCloud = FakeCloud()) -> DuplicateFinder {
        DuplicateFinder(
            home: home, protectedList: ProtectedList(home: home), hasFullDiskAccess: { access }, cloud: cloud)
    }

    func cleaner(access: Bool = true, cloud: FakeCloud = FakeCloud()) -> Cleaner {
        Cleaner(
            home: home, trashMover: TempTrashMover(trashDirectory: trash), store: store,
            protectedList: ProtectedList(home: home), rules: { [] }, now: { fixture.now },
            hasFullDiskAccess: { access },
            appContext: AppCleaningContext(
                appRoots: [path("Applications")], systemLibrary: fixture.outside, signing: FakeSigning(),
                installedApps: { [] }, isKnownApp: { _ in false }),
            ownPaths: [path("Library/Application Support/Dustpan")], cloudStatus: cloud)
    }

    func scan(_ roots: [String], access: Bool = true, cloud: FakeCloud = FakeCloud()) async throws -> DuplicateScan {
        try await finder(access: access, cloud: cloud).find(roots.map { path($0) })
    }
}

@Suite("Duplicate finder")
struct DuplicateFinderTests {
    @Test("3 identical, 2 same-size-different and 1 tiny file give exactly one group of 3")
    func acceptance() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let same = ClutterHarness.content(200_000, seed: 1)
        try h.write("Documents/a.bin", same)
        try h.write("Documents/sub/b.bin", same)
        try h.write("Documents/c-copy.bin", same)
        // Same length; one differs only in the middle (beyond both 16 KB samples).
        var middle = same
        middle[100_000] ^= 0xFF
        try h.write("Documents/d.bin", middle)
        try h.write("Documents/e.bin", ClutterHarness.content(200_000, seed: 9))
        try h.write("Documents/tiny.txt", Data("hello".utf8))

        let scan = try await h.scan(["Documents"])
        #expect(scan.groups.count == 1)
        let group = try #require(scan.groups.first)
        #expect(group.files.count == 3)
        #expect(Set(group.urls.map(\.lastPathComponent)) == ["a.bin", "b.bin", "c-copy.bin"])
        #expect(group.size == 200_000)
        #expect(scan.filesSeen == 6)
    }

    @Test("Files under 100 KB are never grouped")
    func tinyFilesIgnored() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let small = ClutterHarness.content(50_000, seed: 2)
        try h.write("Documents/one.bin", small)
        try h.write("Documents/two.bin", small)
        #expect(try await h.scan(["Documents"]).groups.isEmpty)
    }

    @Test("Hard links of one file are not duplicates; a real copy still is")
    func hardLinks() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 3)
        let original = try h.write("Documents/original.bin", data)
        #expect(link(original.path, h.path("Documents/hardlink.bin").path) == 0)
        #expect(try await h.scan(["Documents"]).groups.isEmpty)

        try h.write("Desktop/real-copy.bin", data)
        let scan = try await h.scan(["Documents", "Desktop"])
        #expect(scan.groups.count == 1)
        #expect(scan.groups.first?.files.count == 2)
    }

    @Test("Symlinks are never followed or counted")
    func symlinksIgnored() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 4)
        let file = try h.write("Documents/file.bin", data)
        try h.fixture.symlink("Documents/link.bin", to: file)
        // A linked folder holding a real copy outside the roots.
        try FileManager.default.createDirectory(at: h.fixture.outside, withIntermediateDirectories: true)
        try data.write(to: h.fixture.outside.appendingPathComponent("copy.bin"))
        try h.fixture.symlink("Documents/elsewhere", to: h.fixture.outside)
        #expect(try await h.scan(["Documents"]).groups.isEmpty)
        // A root that is itself a link is refused.
        try h.fixture.symlink("LinkedRoot", to: h.fixture.outside)
        try data.write(to: h.fixture.outside.appendingPathComponent("copy2.bin"))
        #expect(try await h.scan(["LinkedRoot"]).groups.isEmpty)
    }

    @Test("Packages, tool folders, hidden files and app databases are skipped")
    func packagesSkipped() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 5)
        try h.write("Documents/keep.bin", data)
        try h.write("Documents/Tool.app/Contents/Resources/keep.bin", data)
        try h.write("Pictures/Photos Library.photoslibrary/originals/keep.bin", data)
        try h.write("Documents/Thing.bundle/keep.bin", data)
        try h.write("Documents/site/node_modules/pkg/keep.bin", data)
        try h.write("Documents/.hidden/keep.bin", data)
        try h.write("Documents/.keep.bin", data)
        let db = ClutterHarness.content(150_000, seed: 6)
        try h.write("Documents/one.sqlite", db)
        try h.write("Documents/two.sqlite", db)
        #expect(try await h.scan(["Documents", "Pictures"]).groups.isEmpty)
    }

    @Test("Cloud placeholders are skipped without being read")
    func cloudSkipped() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 7)
        try h.write("Documents/a.bin", data)
        try h.write("Documents/b.bin", data)
        let cloudy = try h.write("Documents/c.bin", data)
        let scan = try await h.scan(["Documents"], cloud: FakeCloud(paths: [cloudy.path]))
        #expect(scan.groups.count == 1)
        #expect(scan.groups.first?.files.count == 2)
        #expect(scan.groups.first?.urls.contains(cloudy) == false)
    }

    @Test("Without Full Disk Access the guarded folders are skipped and reported")
    func needsAccess() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 8)
        try h.write("Downloads/a.bin", data)
        try h.write("Downloads/b.bin", data)
        try h.write("Projects/a.bin", data)
        try h.write("Projects/b.bin", data)
        let scan = try await h.scan(["Downloads", "Projects"], access: false)
        #expect(scan.needsAccess.map(\.lastPathComponent) == ["Downloads"])
        #expect(scan.groups.count == 1)
        #expect(scan.groups.first?.urls.allSatisfy { $0.path.contains("/Projects/") } == true)
    }

    @Test("Keeper: Documents over Desktop over Downloads, else the oldest")
    func keeperRule() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let one = ClutterHarness.content(120_000, seed: 10)
        try h.write("Downloads/one.bin", one, createdDaysAgo: 300)
        try h.write("Desktop/one.bin", one, createdDaysAgo: 200)
        try h.write("Documents/Work/one.bin", one, createdDaysAgo: 10)
        let two = ClutterHarness.content(130_000, seed: 11)
        try h.write("Downloads/two.bin", two, createdDaysAgo: 300)
        try h.write("Desktop/two.bin", two, createdDaysAgo: 5)
        let three = ClutterHarness.content(140_000, seed: 12)
        try h.write("Downloads/three-new.bin", three, createdDaysAgo: 2)
        try h.write("Downloads/three-old.bin", three, createdDaysAgo: 90)
        try h.write("Downloads/three-mid.bin", three, createdDaysAgo: 30)

        let scan = try await h.scan(["Downloads", "Desktop", "Documents"])
        #expect(scan.groups.count == 3)
        func keeper(_ size: Int64) -> String? {
            scan.groups.first { $0.size == size }.map { String($0.keeper.path.dropFirst(h.home.path.count + 1)) }
        }
        #expect(keeper(120_000) == "Documents/Work/one.bin")
        #expect(keeper(130_000) == "Desktop/two.bin")
        #expect(keeper(140_000) == "Downloads/three-old.bin")
        // The keeper is listed first.
        #expect(scan.groups.allSatisfy { $0.files.first?.url == $0.keeper })
    }
}

@Suite("Clutter cleaner")
struct ClutterCleanerTests {
    func group(_ h: ClutterHarness, _ roots: [String]) async throws -> DuplicateGroup {
        try #require(try await h.scan(roots).groups.first)
    }

    @Test("Duplicates move to the Trash, are logged, and can be put back")
    func movesDuplicates() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(160_000, seed: 20)
        try h.write("Documents/report.pdf", data, createdDaysAgo: 50)
        try h.write("Downloads/report.pdf", data, createdDaysAgo: 40)
        try h.write("Downloads/report (1).pdf", data, createdDaysAgo: 30)
        let g = try await group(h, ["Documents", "Downloads"])
        #expect(g.keeper == h.path("Documents/report.pdf"))
        let removals = g.files.filter { $0.url != g.keeper }.map {
            DuplicateRemoval(url: $0.url, keeper: g.keeper, hash: g.hash, size: g.size)
        }
        let cleaner = h.cleaner()
        let report = await cleaner.trashDuplicates(removals)
        #expect(report.skipped.isEmpty)
        #expect(report.moved.count == 2)
        #expect(h.exists("Documents/report.pdf"))
        #expect(!h.exists("Downloads/report.pdf"))
        #expect(try await h.store.logs().allSatisfy { $0.ruleID == Cleaner.duplicateRuleID })
        let undo = await cleaner.undo(report.logIDs)
        #expect(undo.failed.isEmpty)
        #expect(h.exists("Downloads/report.pdf") && h.exists("Downloads/report (1).pdf"))
    }

    @Test("Every copy of a group can never go, whatever the request says")
    func neverAllCopies() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(160_000, seed: 21)
        try h.write("Documents/a.bin", data)
        try h.write("Downloads/b.bin", data)
        let g = try await group(h, ["Documents", "Downloads"])
        let a = h.path("Documents/a.bin")
        let b = h.path("Downloads/b.bin")
        let cleaner = h.cleaner()
        // Each names the other as keeper: both would go.
        var report = await cleaner.trashDuplicates([
            DuplicateRemoval(url: a, keeper: b, hash: g.hash, size: g.size),
            DuplicateRemoval(url: b, keeper: a, hash: g.hash, size: g.size),
        ])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.lastCopy, .lastCopy])
        // A file that is its own keeper.
        report = await cleaner.trashDuplicates([DuplicateRemoval(url: a, keeper: a, hash: g.hash, size: g.size)])
        #expect(report.skipped.map(\.reason) == [.lastCopy])
        // A hard link of the file as its "keeper".
        #expect(link(a.path, h.path("Documents/a-link.bin").path) == 0)
        report = await cleaner.trashDuplicates([
            DuplicateRemoval(url: a, keeper: h.path("Documents/a-link.bin"), hash: g.hash, size: g.size)
        ])
        #expect(report.skipped.map(\.reason) == [.lastCopy])
        #expect(h.exists("Documents/a.bin") && h.exists("Downloads/b.bin"))
    }

    @Test("A copy whose content changed after the scan, or whose keeper changed or went, stays")
    func changedContentRefused() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(160_000, seed: 22)
        try h.write("Documents/keep.bin", data)
        try h.write("Downloads/copy.bin", data)
        try h.write("Desktop/copy2.bin", data)
        let g = try await group(h, ["Documents", "Downloads", "Desktop"])
        let keeper = h.path("Documents/keep.bin")
        #expect(g.keeper == keeper)
        let cleaner = h.cleaner()

        // The copy changed (same length, one byte different, in the middle).
        var changed = data
        changed[80_000] ^= 1
        try changed.write(to: h.path("Downloads/copy.bin"))
        var report = await cleaner.trashDuplicates([
            DuplicateRemoval(url: h.path("Downloads/copy.bin"), keeper: keeper, hash: g.hash, size: g.size)
        ])
        #expect(report.skipped.map(\.reason) == [.contentChanged])
        #expect(h.exists("Downloads/copy.bin"))

        // The keeper changed.
        try changed.write(to: keeper)
        report = await cleaner.trashDuplicates([
            DuplicateRemoval(url: h.path("Desktop/copy2.bin"), keeper: keeper, hash: g.hash, size: g.size)
        ])
        #expect(report.skipped.map(\.reason) == [.contentChanged])

        // The keeper is gone.
        try FileManager.default.removeItem(at: keeper)
        report = await cleaner.trashDuplicates([
            DuplicateRemoval(url: h.path("Desktop/copy2.bin"), keeper: keeper, hash: g.hash, size: g.size)
        ])
        #expect(report.skipped.map(\.reason) == [.keeperMissing])
        #expect(h.exists("Desktop/copy2.bin"))
    }

    @Test("A wrong hash from the caller is refused")
    func wrongHash() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(160_000, seed: 23)
        try h.write("Documents/keep.bin", data)
        try h.write("Downloads/copy.bin", data)
        let g = try await group(h, ["Documents", "Downloads"])
        let report = await h.cleaner().trashDuplicates([
            DuplicateRemoval(url: h.path("Downloads/copy.bin"), keeper: g.keeper, hash: g.hash ^ 1, size: g.size)
        ])
        #expect(report.skipped.map(\.reason) == [.contentChanged])
    }

    @Test("Large & old: files only, nothing guarded, packaged, cloud-only, linked or in Library")
    func largeFileChecks() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(120_000, seed: 30)
        try h.write("Projects/old.mov", data)
        try h.write("Projects/folder/inside.mov", data)
        try h.write("Library/Caches/big.bin", data)
        try h.write("Projects/Tool.app/Contents/big.bin", data)
        try h.write("Projects/Lib.photoslibrary/big.bin", data)
        let cloudy = try h.write("Projects/cloudy.mov", data)
        try h.write("Downloads/setup.dmg", data)
        try h.fixture.symlink("Projects/link.mov", to: h.path("Projects/old.mov"))
        try h.write("Projects/db/data.sqlite", data)
        let cleaner = h.cleaner(access: false, cloud: FakeCloud(paths: [cloudy.path]))

        func reason(_ relative: String) async -> SkipReason? {
            await cleaner.trashLargeFiles([h.path(relative)]).skipped.first?.reason
        }
        #expect(await reason("Projects/folder") == .notAFile)
        #expect(await reason("Movies/x.mov") == .needsFullDiskAccess)
        #expect(await reason("Library/Caches/big.bin") == .homeFolder)
        #expect(await reason("Projects/Tool.app/Contents/big.bin") == .insideApp)
        #expect(await reason("Projects/Lib.photoslibrary/big.bin") == .insidePackage)
        #expect(await reason("Projects/cloudy.mov") == .cloudOnly)
        #expect(await reason("Downloads/setup.dmg") == .needsFullDiskAccess)
        #expect(await reason("Projects/link.mov") == .isSymlink)
        #expect(await reason("Projects/db/data.sqlite") == .appDatabaseFolder)
        #expect(h.exists("Downloads/setup.dmg") && h.exists("Projects/Lib.photoslibrary/big.bin"))

        let report = await cleaner.trashLargeFiles([h.path("Projects/old.mov")])
        #expect(report.skipped.isEmpty)
        #expect(report.moved.count == 1)
        #expect(!h.exists("Projects/old.mov"))
        #expect(try await h.store.logs().first?.ruleID == Cleaner.largeOldRuleID)
    }
}

@Suite("Large & old")
struct LargeOldTests {
    static let mb: Int64 = 1_048_576

    func file(_ name: String, mb: Int64, lastUsedDaysAgo: Double?, modifiedDaysAgo: Double, now: Date) -> LargeFile {
        LargeFile(
            url: URL(fileURLWithPath: "/Users/x/" + name), allocatedSize: mb * Self.mb,
            lastUsed: lastUsedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            modified: now.addingTimeInterval(-modifiedDaysAgo * 86_400), kind: .of(name))
    }

    @Test("Filters respect size, age (opened or changed) and kind")
    func filters() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let movie = file("trip.mov", mb: 700, lastUsedDaysAgo: 400, modifiedDaysAgo: 500, now: now)
        let iso = file("linux.iso", mb: 120, lastUsedDaysAgo: 200, modifiedDaysAgo: 300, now: now)
        let recentOpen = file("edit.mov", mb: 2_000, lastUsedDaysAgo: 10, modifiedDaysAgo: 400, now: now)
        let recentChange = file("vm.bin", mb: 2_000, lastUsedDaysAgo: nil, modifiedDaysAgo: 20, now: now)
        let never = file("notes.pdf", mb: 150, lastUsedDaysAgo: nil, modifiedDaysAgo: 120, now: now)

        var filter = LargeOldFilter(minimumSize: .mb100, age: .months3, kind: nil)
        #expect(
            [movie, iso, recentOpen, recentChange, never].filter { filter.includes($0, now: now) } == [
                movie, iso, never,
            ])
        filter.minimumSize = .mb500
        #expect([movie, iso, never].filter { filter.includes($0, now: now) } == [movie])
        filter.minimumSize = .gb1
        #expect(!filter.includes(movie, now: now))
        filter = LargeOldFilter(minimumSize: .mb100, age: .months12, kind: nil)
        #expect([movie, iso, never].filter { filter.includes($0, now: now) } == [movie])
        filter = LargeOldFilter(minimumSize: .mb100, age: .months3, kind: .archive)
        #expect([movie, iso, never].filter { filter.includes($0, now: now) } == [iso])
        filter.kind = .video
        #expect([movie, iso, never].filter { filter.includes($0, now: now) } == [movie])
        filter.kind = .document
        #expect([movie, iso, never].filter { filter.includes($0, now: now) } == [never])
        #expect(ClutterKind.of("a.zip") == .archive && ClutterKind.of("a.dmg") == .archive)
        #expect(ClutterKind.of("a.heic") == .image && ClutterKind.of("a.mp3") == .audio)
    }

    @Test("Finder never lists protected, cloud-only, guarded, packaged, linked or Library files")
    func finderExclusions() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let big = 120_000
        let data = ClutterHarness.content(big, seed: 40)
        let indexed = try h.write("Projects/indexed.mov", data)
        let unindexed = try h.write(".models/weights.bin", data)
        let cloudy = try h.write("Projects/cloudy.mov", data)
        let mobile = try h.write("Library/Mobile Documents/com~apple~CloudDocs/doc.pdf", data)
        let library = try h.write("Library/Application Support/App/blob.bin", data)
        let downloads = try h.write("Downloads/setup.dmg", data)
        let packaged = try h.write("Projects/Tool.app/Contents/Resources/big.bin", data)
        let photos = try h.write("Pictures/Photos Library.photoslibrary/originals/big.heic", data)
        let modules = try h.write("Projects/site/node_modules/pkg/big.bin", data)
        let db = try h.write("Projects/db/store.sqlite", data)
        try h.fixture.symlink("Projects/link.mov", to: indexed)
        #expect(link(indexed.path, h.path("Projects/hard-link.mov").path) == 0)
        let small = try h.write("Projects/small.mov", ClutterHarness.content(10_000, seed: 41))
        let usedDate = h.fixture.now.addingTimeInterval(-200 * 86_400)
        let index = FakeIndex(
            hits: [indexed, cloudy, mobile, library, downloads, packaged, photos, modules, db, small].map {
                IndexedFile(path: $0.path, size: Int64(big), lastUsed: $0 == indexed ? usedDate : nil)
            } + [IndexedFile(path: h.path("Projects/link.mov").path, size: Int64(big), lastUsed: nil)])

        let finder = LargeOldFinder(
            home: h.home, protectedList: ProtectedList(home: h.home), hasFullDiskAccess: { false },
            cloud: FakeCloud(paths: [cloudy.path]), index: index)
        let scan = try await finder.find(minimumBytes: 100_000)
        let found = Set(scan.files.map(\.url.path))
        #expect(found.contains(indexed.path))
        #expect(found.contains(unindexed.path), "the walker finds what Spotlight doesn't index")
        #expect(found.count == 2, "\(found)")
        #expect(scan.needsAccessCount == 2, "Downloads and Pictures, counted from the index only")
        #expect(scan.files.first { $0.url == indexed }?.lastUsed == usedDate)

        // With access, Downloads is listed.
        let withAccess = LargeOldFinder(
            home: h.home, protectedList: ProtectedList(home: h.home), hasFullDiskAccess: { true },
            cloud: FakeCloud(paths: [cloudy.path]), index: index)
        let all = Set(try await withAccess.find(minimumBytes: 100_000).files.map(\.url.path))
        #expect(all == [indexed.path, unindexed.path, downloads.path])
    }
}

@Suite("Duplicates model")
@MainActor
struct DuplicatesModelTests {
    @Test("Nothing is ticked until 'Select duplicates, keep one'; the keeper and the last copy can't be ticked")
    func selection() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 50)
        try h.write("Documents/a.bin", data)
        try h.write("Downloads/a.bin", data)
        try h.write("Downloads/a (1).bin", data)
        let cleaner = h.cleaner()
        let model = DuplicatesModel(finder: h.finder(), cleaner: cleaner, home: h.home)
        await model.scan()
        #expect(model.groups.count == 1)
        #expect(model.selection.isEmpty)
        let group = model.groups[0]
        let keeper = try #require(group.files.first { model.isKeeper($0, in: group) })
        #expect(keeper.url == h.path("Documents/a.bin"))

        model.setSelected(keeper, in: group, true)
        #expect(model.selection.isEmpty, "the keeper can't be ticked")

        model.selectDuplicatesKeepOne()
        #expect(model.selectedCount == 2)
        #expect(!model.isSelected(keeper))

        // Choosing another keeper unticks it; the old keeper can then be ticked, never all three.
        let other = group.files.first { $0.url == h.path("Downloads/a.bin") }!
        model.keep(other, in: group)
        #expect(!model.isSelected(other))
        model.setSelected(keeper, in: group, true)
        #expect(model.isSelected(keeper))
        model.setSelected(other, in: group, true)
        #expect(!model.isSelected(other))
        #expect(model.removals.count == 2)
        #expect(model.removals.allSatisfy { $0.keeper == other.url })

        model.requestMove()
        await model.confirmMove()
        #expect(model.groups.isEmpty)
        #expect(h.exists("Downloads/a.bin"))
        #expect(!h.exists("Documents/a.bin") && !h.exists("Downloads/a (1).bin"))
        await model.undoLastMove()
        #expect(h.exists("Documents/a.bin") && h.exists("Downloads/a (1).bin"))
        #expect(model.groups.first?.files.count == 3)
    }
}

@Suite("Clutter fixes (round 1)")
struct ClutterRoundOneTests {
    @Test("Files in a folder holding an app database are never listed or moved (Caches exempt)")
    func databaseFolders() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 60)
        try h.write("Documents/AppData/store.sqlite", Data("db".utf8))
        try h.write("Documents/AppData/blob.bin", data)
        try h.write("Documents/AppData/deeper/blob2.bin", data)
        try h.write("Desktop/blob-copy.bin", data)
        try h.write("Desktop/blob-copy2.bin", data)
        let scan = try await h.scan(["Documents", "Desktop"])
        #expect(scan.groups.count == 1)
        #expect(scan.groups.first?.urls.allSatisfy { !$0.path.contains("/AppData/") } == true)

        let cleaner = h.cleaner()
        let report = await cleaner.trashLargeFiles([
            h.path("Documents/AppData/blob.bin"), h.path("Documents/AppData/deeper/blob2.bin"),
        ])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.appDatabaseFolder, .appDatabaseFolder])
        #expect(h.exists("Documents/AppData/blob.bin"))

        // Large & old leaves them out too.
        let finder = LargeOldFinder(
            home: h.home, protectedList: ProtectedList(home: h.home), hasFullDiskAccess: { true },
            cloud: FakeCloud(), index: nil)
        let found = try await finder.find(minimumBytes: 100_000).files.map(\.url.path)
        #expect(!found.contains { $0.contains("/AppData/") })
        #expect(found.contains(h.path("Desktop/blob-copy.bin").path))
    }

    @Test("Large & old skips tool caches (~/.npm, ~/.cache, SwiftPM checkouts)")
    func skipsToolCaches() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(120_000, seed: 61)
        try h.write(".npm/_cacache/content-v2/sha512/ab/blob", data)
        try h.write(".cache/uv/wheel.whl", data)
        try h.write("Projects/app/build/SourcePackages/repositories/x/objects/pack/p.pack", data)
        let kept = try h.write("Projects/app/render.mov", data)
        let finder = LargeOldFinder(
            home: h.home, protectedList: ProtectedList(home: h.home), hasFullDiskAccess: { true },
            cloud: FakeCloud(), index: nil)
        let found = try await finder.find(minimumBytes: 100_000).files.map(\.url.path)
        #expect(found == [kept.path])
    }

    @Test("Added folders must be inside home, outside Library and the Trash")
    @MainActor
    func addedRoots() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        try FileManager.default.createDirectory(at: h.path("Projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: h.path("Library/Caches"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: h.fixture.outside, withIntermediateDirectories: true)
        let model = DuplicatesModel(finder: h.finder(), cleaner: h.cleaner(), home: h.home)
        let before = model.roots.count
        model.addRoot(h.fixture.outside)
        #expect(model.issue == .folderNotAllowed)
        model.dismissIssue()
        model.addRoot(h.path("Library/Caches"))
        #expect(model.issue == .folderNotAllowed)
        model.dismissIssue()
        model.addRoot(h.path("Projects"))
        #expect(model.issue == nil)
        #expect(model.roots.count == before + 1)
    }

    @Test("After a partial move the group keeps the copy the user chose to keep")
    @MainActor
    func keeperSurvivesMove() async throws {
        let h = try ClutterHarness()
        defer { h.fixture.remove() }
        let data = ClutterHarness.content(150_000, seed: 62)
        try h.write("Documents/a.bin", data)
        try h.write("Downloads/b.bin", data)
        try h.write("Downloads/c.bin", data)
        let model = DuplicatesModel(finder: h.finder(), cleaner: h.cleaner(), home: h.home)
        await model.scan()
        let group = try #require(model.groups.first)
        let chosen = try #require(group.files.first { $0.url == h.path("Downloads/b.bin") })
        model.keep(chosen, in: group)
        let doomed = try #require(group.files.first { $0.url == h.path("Downloads/c.bin") })
        model.setSelected(doomed, in: group, true)
        model.requestMove()
        await model.confirmMove()
        let after = try #require(model.groups.first)
        #expect(after.files.count == 2)
        #expect(after.keeper == chosen.url)
        #expect(model.keeper(of: after) == chosen.url)
    }
}
