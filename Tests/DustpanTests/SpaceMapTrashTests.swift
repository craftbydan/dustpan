import Foundation
import Testing

@testable import Dustpan

/// `Cleaner.trashUserChosen` (Space map → Move to Trash). A temp home, Trash and database only.
@Suite("Space map trash")
struct SpaceMapTrashTests {
    struct Harness {
        let fixture: FixtureHome
        let trash: URL
        let store: CleanupStore
        let own: URL

        init() throws {
            fixture = try FixtureHome()
            let container = fixture.outside.deletingLastPathComponent()
            trash = container.appendingPathComponent("trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            store = CleanupStore(database: try AppDatabase(directory: container.appendingPathComponent("db")))
            own = fixture.path("Library/Application Support/Dustpan")
        }

        func cleaner(access: Bool = true, signing: FakeSigning = FakeSigning()) -> Cleaner {
            Cleaner(
                home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash), store: store,
                protectedList: ProtectedList(home: fixture.url), rules: { [] }, now: { fixture.now },
                hasFullDiskAccess: { access },
                appContext: AppCleaningContext(
                    appRoots: [fixture.path("Applications")], systemLibrary: fixture.outside, signing: signing,
                    installedApps: { [] }, isKnownApp: { _ in false }),
                ownPaths: [own, fixture.path("Applications/Dustpan.app")])
        }

        func reason(_ relative: String, access: Bool = true, signing: FakeSigning = FakeSigning()) async -> SkipReason?
        {
            await reason(url: fixture.path(relative), access: access, signing: signing)
        }

        func reason(url: URL, access: Bool = true, signing: FakeSigning = FakeSigning()) async -> SkipReason? {
            let report = await cleaner(access: access, signing: signing).trashUserChosen(url)
            #expect(report.moved.isEmpty)
            return report.skipped.first?.reason
        }

        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: fixture.path(relative).path) }
    }

    @Test("A user folder moves to the Trash, is logged, and can be put back")
    func movesAndUndoes() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file("Projects/old/render.mov", bytes: 80_000)
        let cleaner = h.cleaner()
        let report = await cleaner.trashUserChosen(h.fixture.path("Projects/old"), knownBytes: 81_920)
        #expect(report.skipped.isEmpty)
        #expect(report.moved.count == 1)
        #expect(report.freedBytes == 81_920)
        #expect(!h.exists("Projects/old"))
        let logs = try await h.store.logs()
        #expect(logs.first?.ruleID == Cleaner.userChosenRuleID)
        let undo = await cleaner.undo(report.logIDs)
        #expect(undo.failed.isEmpty)
        #expect(h.exists("Projects/old/render.mov"))
    }

    @Test("Home itself and its standard folders are refused")
    func homeFolders() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        for folder in ["Library/Caches/x", "Documents/a", "Desktop/a", "Downloads/a", ".ssh/id"] {
            try h.fixture.file(folder, bytes: 10)
        }
        #expect(await h.reason(url: h.fixture.url) == .homeFolder)
        for folder in ["Library", "Documents", "Desktop", "Downloads", ".ssh", "Library/Caches"] {
            #expect(await h.reason(folder) == .homeFolder, "\(folder)")
            #expect(h.exists(folder))
        }
    }

    @Test("Anything outside home, or reached with .., is refused")
    func outsideHome() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file("x", bytes: 10, absolute: h.fixture.outside.appendingPathComponent("file.bin"))
        #expect(await h.reason(url: h.fixture.outside.appendingPathComponent("file.bin")) == .outsideHome)
        #expect(await h.reason(url: URL(fileURLWithPath: "/usr/bin/true")) == .outsideHome)
        #expect(await h.reason(url: URL(fileURLWithPath: h.fixture.url.path + "/../outside/file.bin")) == .outsideHome)
    }

    @Test("Protected places and app databases are refused (fail closed)")
    func protectedPlaces() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file("Library/Mail/V10/a.emlx", bytes: 10)
        try h.fixture.file("Library/Keychains/login.keychain-db", bytes: 10)
        try h.fixture.file("Work/notes-app/store.sqlite", bytes: 10)
        try h.fixture.file("Pictures/Old.photoslibrary/database/x", bytes: 10)
        #expect(await h.reason("Library/Mail/V10") == .protected)
        #expect(await h.reason("Library/Keychains/login.keychain-db") == .protected)
        #expect(await h.reason("Work/notes-app") == .protected)
        #expect(await h.reason("Pictures/Old.photoslibrary") == .protected)
        #expect(h.exists("Work/notes-app/store.sqlite"))
    }

    @Test("Links, and paths through a link, are refused")
    func links() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file("x", bytes: 10, absolute: h.fixture.outside.appendingPathComponent("target/file.bin"))
        try h.fixture.symlink("Work/link", to: h.fixture.outside.appendingPathComponent("target"))
        #expect(await h.reason("Work/link") == .isSymlink)
        #expect(await h.reason("Work/link/file.bin") == .isSymlink)
        #expect(
            FileManager.default.fileExists(atPath: h.fixture.outside.appendingPathComponent("target/file.bin").path))
    }

    @Test("Apple apps, files inside apps, Dustpan and its database are refused")
    func appsAndSelf() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        func app(_ name: String, id: String) throws {
            let contents = h.fixture.path("Applications/\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("Pages", id: "com.apple.iWork.Pages")
        try app("Signed", id: "com.example.signed")
        try app("Dustpan", id: "app.dustpan.Dustpan")
        try h.fixture.file("Library/Application Support/Dustpan/dustpan.sqlite", bytes: 10)
        let signing = FakeSigning(byName: ["Signed.app": SigningInfo(teamID: "59GAB85EFG", isApple: true)])
        #expect(await h.reason("Applications/Pages.app") == .appleApp)
        #expect(await h.reason("Applications/Signed.app", signing: signing) == .appleApp)
        #expect(await h.reason("Applications/Signed.app/Contents") == .insideApp)
        #expect(await h.reason("Applications/Dustpan.app") == .dustpanItself)
        #expect(await h.reason("Library/Application Support/Dustpan/dustpan.sqlite") == .dustpanItself)
        #expect(await h.reason("Library/Application Support/Dustpan") == .dustpanItself)
    }

    @Test("Without Full Disk Access, guarded folders are refused before any check")
    func guardedWithoutAccess() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file("Documents/old/a.pdf", bytes: 10)
        #expect(await h.reason("Documents/old", access: false) == .needsFullDiskAccess)
        #expect(await h.reason("Library/Containers/com.x/y", access: false) == .needsFullDiskAccess)
        #expect(h.exists("Documents/old/a.pdf"))
    }

    @Test("The Trash and things in it are refused")
    func trash() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file(".Trash/old.zip", bytes: 10)
        #expect(await h.reason(".Trash/old.zip") == .alreadyInTrash)
        #expect(await h.reason(".Trash") == .homeFolder)
    }

    @Test("Without access, folders the map doesn't open are refused too (Music, iTunes, com.apple.*)")
    func walkerGuardWithoutAccess() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        for relative in [
            "Music/Music/Music Library.musiclibrary/Library.musicdb", "Library/Caches/com.apple.Music/x",
            "Library/iTunes/x/y", "Library/MediaThing/z", "Library/Caches/com.vendor.app/blob",
        ] {
            try h.fixture.file(relative, bytes: 10)
        }
        for relative in [
            "Music/Music", "Music/Music/Music Library.musiclibrary", "Library/Caches/com.apple.Music",
            "Library/iTunes/x", "Library/MediaThing/z",
        ] {
            #expect(await h.reason(relative, access: false) == .needsFullDiskAccess, "\(relative)")
            #expect(h.exists(relative))
        }
        let report = await h.cleaner(access: false).trashUserChosen(h.fixture.path("Library/Caches/com.vendor.app"))
        #expect(report.moved.count == 1)
    }

    @Test("Folders holding an Apple app or a copy of Dustpan (two levels down) are refused")
    func foldersHoldingApps() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        func app(_ relative: String, id: String) throws {
            let contents = h.fixture.path(relative + "/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "x"], format: .xml, options: 0
            ).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try app("Stuff/Apple Stuff/Pages.app", id: "com.apple.iWork.Pages")
        try app("Old/copies/Dustpan.app", id: "app.dustpan.Dustpan")
        try app("Tools/Other.app", id: "com.example.other")
        #expect(await h.reason("Stuff/Apple Stuff") == .appleApp)
        #expect(await h.reason("Stuff") == .appleApp)
        #expect(await h.reason("Old") == .dustpanItself)
        #expect(h.exists("Stuff/Apple Stuff/Pages.app"))
        let report = await h.cleaner().trashUserChosen(h.fixture.path("Tools"))
        #expect(report.moved.count == 1)
    }

    @Test("A path that differs from the one on disk only in capitals gets its own reason")
    func wrongCase() async throws {
        let h = try Harness()
        defer { h.fixture.remove() }
        try h.fixture.file("Projects/Old/a.bin", bytes: 10)
        #expect(await h.reason("projects/OLD") == .pathMismatch)
        #expect(h.exists("Projects/Old/a.bin"))
    }

    @Test("Rules can't read places the map won't open without access unless they set the flag")
    func ruleValidationAgrees() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        let list = ProtectedList(home: home)
        let apple = Rule(
            id: "t.apple", title: "t", category: .userCache, paths: ["~/Library/Caches"], globs: ["com.apple.*"],
            risk: .review, why: "Test.")
        #expect(throws: (any Error).self) { try RuleCatalog.validate([apple], protectedList: list) }
        let itunes = Rule(
            id: "t.itunes", title: "t", category: .installers, paths: ["~/Library/iTunes/Updates"], risk: .review,
            why: "Test.")
        #expect(throws: (any Error).self) { try RuleCatalog.validate([itunes], protectedList: list) }
        let flagged = Rule(
            id: "t.ok", title: "t", category: .userCache, paths: ["~/Library/Caches"], globs: ["com.apple.*"],
            risk: .review, why: "Test.", needsFullDiskAccess: true)
        try RuleCatalog.validate([flagged], protectedList: list)
    }
}
