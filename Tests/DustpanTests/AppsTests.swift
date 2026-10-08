import Foundation
import Testing

@testable import Dustpan

/// Signatures by bundle file name, so fixture apps can have team IDs or look Apple-signed.
struct FakeSigning: CodeSigningReading {
    var byName: [String: SigningInfo] = [:]
    func signing(of appURL: URL) -> SigningInfo { byName[appURL.lastPathComponent] ?? .unsigned }
}

struct FakeLastUsed: LastUsedReading {
    var byName: [String: Date] = [:]
    func lastUsed(_ appURL: URL) -> Date? { byName[appURL.lastPathComponent] }
}

@MainActor
final class FakeQuitter: AppQuitting {
    var succeeds: Bool
    private(set) var asked: [String] = []
    init(succeeds: Bool) { self.succeeds = succeeds }
    func quit(bundleID: String) async -> Bool {
        asked.append(bundleID)
        return succeeds
    }
}

/// Apps: scanner, leftover matcher, orphans and the Cleaner's uninstall path. Fixture trees in a
/// temp folder only: a fake home, a fake app folder, a fake `/Library` and a fake Trash.
@Suite("Apps")
struct AppsTests {
    struct Harness {
        let fixture: FixtureHome
        let apps: URL
        let systemLibrary: URL
        let trash: URL
        let store: CleanupStore
        var signing = FakeSigning()

        init() throws {
            fixture = try FixtureHome()
            let container = fixture.outside.deletingLastPathComponent()
            apps = container.appendingPathComponent("Applications", isDirectory: true)
            systemLibrary = container.appendingPathComponent("SystemLibrary", isDirectory: true)
            trash = container.appendingPathComponent("trash", isDirectory: true)
            for url in [apps, systemLibrary, trash] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            store = CleanupStore(database: try AppDatabase(directory: container.appendingPathComponent("db")))
        }

        /// Writes `<apps>/<name>.app` with an Info.plist and some payload.
        @discardableResult
        func app(_ name: String, id: String, in folder: URL? = nil, payload: Int = 9_000) throws -> URL {
            let bundle = (folder ?? apps).appendingPathComponent("\(name).app", isDirectory: true)
            let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.2",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            try fixture.file("", bytes: payload, absolute: contents.appendingPathComponent("MacOS/\(name)"))
            return bundle
        }

        var scanner: AppScanner {
            AppScanner(roots: [apps], useSpotlight: false, signing: signing, lastUsed: FakeLastUsed())
        }

        func matcher(access: Bool = true, elsewhere: [String: String] = [:]) -> LeftoverMatcher {
            LeftoverMatcher(
                home: fixture.url, systemLibrary: systemLibrary, protectedList: ProtectedList(home: fixture.url),
                hasFullDiskAccess: access, now: fixture.now, knownAppPath: { elsewhere[$0] })
        }

        func cleaner(
            running: [String: String] = [:], access: Bool = true, known: Set<String> = [],
            elsewhere: [String: String] = [:]
        ) -> Cleaner {
            let scanner = scanner
            return Cleaner(
                home: fixture.url, trashMover: TempTrashMover(trashDirectory: trash),
                runningApps: FakeRunningApps(running: running), store: store,
                protectedList: ProtectedList(home: fixture.url), rules: { [] }, now: { fixture.now },
                hasFullDiskAccess: { access },
                appContext: AppCleaningContext(
                    appRoots: [apps], systemLibrary: systemLibrary, signing: signing,
                    installedApps: { await scanner.identities() }, isKnownApp: { known.contains($0) },
                    knownAppPath: { elsewhere[$0] }))
        }

        func record(_ bundleID: String) async throws -> AppRecord {
            try #require(await scanner.installedApps().first { $0.bundleID == bundleID })
        }

        func lib(_ relative: String) -> URL { fixture.path("Library/\(relative)") }

        func remove() { fixture.remove() }
    }

    /// The `com.example.Notes` fixture: the app, a look-alike, and files around the Library.
    static func makeNotes(_ h: inout Harness) throws {
        h.signing.byName["Notes.app"] = SigningInfo(teamID: "EXAMPLE123", isApple: false)
        try h.app("Notes", id: "com.example.Notes")
        try h.app("Notes Widget Kit", id: "com.example.Notes.Widget")
        try h.app("Sketchpad", id: "com.example.NotesPro")
        let f = h.fixture
        try f.file("Library/Caches/com.example.Notes/cache.bin", bytes: 40_000)
        try f.file("Library/Preferences/com.example.Notes.plist", bytes: 300)
        try f.file("Library/Saved Application State/com.example.Notes.savedState/windows.plist", bytes: 900)
        try f.file("Library/Containers/com.example.Notes.ShareExtension/Data/x.bin", bytes: 2_000)
        try f.file("Library/Group Containers/EXAMPLE123.shared/x.bin", bytes: 1_000)
        try f.file("Library/Application Support/Notes/state.json", bytes: 5_000)
        try f.file("Library/Logs/Notes Sync/sync.log", bytes: 700)
        try f.file("Library/Application Support/com.example.Notes/store.sqlite", bytes: 4_000)
        // Not Notes': the look-alike, another installed app's folder, Apple's container.
        try f.file("Library/Caches/com.example.NotesPro/c.bin", bytes: 3_000)
        try f.file("Library/Caches/com.example.Notes.Widget/c.bin", bytes: 3_000)
        try f.file("Library/Containers/com.apple.Notes/Data/x.bin", bytes: 3_000)
        try f.file("Library/Caches/Note/c.bin", bytes: 100)
        try f.file(
            "", bytes: 200,
            absolute: h.systemLibrary.appendingPathComponent("LaunchAgents/com.example.Notes.helper.plist"))
    }

    // MARK: - Leftovers

    @Test("Leftovers of com.example.Notes are found with the right reasons")
    func notesLeftovers() async throws {
        var h = try Harness()
        defer { h.remove() }
        try Self.makeNotes(&h)
        let installed = await h.scanner.identities()
        let notes = try #require(installed.first { $0.bundleID == "com.example.Notes" })
        let scan = h.matcher().leftovers(for: notes, installed: installed)
        let byName = Dictionary(
            scan.matches.map { ($0.url.lastPathComponent, $0) },
            uniquingKeysWith: { a, b in
                a.folderTitle == "Caches" ? a : b
            })

        let cache = try #require(byName["com.example.Notes"])
        #expect(cache.folderTitle == "Caches")
        #expect(cache.reason == .bundleID && cache.confidence == .high && cache.isSelectedByDefault)
        #expect(cache.explanation.contains("com.example.Notes"))
        #expect(byName["com.example.Notes.plist"]?.reason == .bundleID)
        #expect(byName["com.example.Notes.savedState"]?.reason == .bundleID)
        #expect(byName["com.example.Notes.ShareExtension"]?.reason == .bundleIDPrefix)
        #expect(byName["com.example.Notes.ShareExtension"]?.isSelectedByDefault == true)
        let group = try #require(byName["EXAMPLE123.shared"])
        #expect(group.reason == .teamID)
        let support = try #require(byName["Notes"])
        #expect(support.reason == .nameToken && support.confidence == .medium)
        let logs = try #require(byName["Notes Sync"])
        #expect(logs.reason == .nameToken && logs.confidence == .low && !logs.isSelectedByDefault)
        // The app database folder is listed but protected; the /Library agent needs the helper.
        let database = try #require(
            scan.matches.first {
                $0.folderTitle == "Application Support" && $0.url.lastPathComponent == "com.example.Notes"
            })
        #expect(database.status == .holdsDatabase && !database.isSelectedByDefault)
        let agent = try #require(byName["com.example.Notes.helper.plist"])
        #expect(agent.status == .needsHelper && agent.reason == .bundleIDPrefix && !agent.isSelectedByDefault)

        // Never matched: the look-alike, another app's folder, Apple's container, short names.
        #expect(byName["com.example.NotesPro"] == nil)
        #expect(byName["com.example.Notes.Widget"] == nil)
        #expect(byName["com.apple.Notes"] == nil)
        #expect(byName["Note"] == nil)
        #expect(!scan.matches.contains { PathTools.isInside($0.url.path, root: h.apps.path) })
        #expect(scan.skippedFolders.isEmpty)
    }

    @Test("Short and generic names never match")
    func genericNames() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.app("Mac Update Helper App", id: "net.vendor.thing")
        try h.app("Box", id: "io.box.client")
        for folder in ["Mac", "Update", "Helper", "App", "Box", "Mac Update Helper App", "Box Sync"] {
            try h.fixture.file("Library/Application Support/\(folder)/x.bin", bytes: 100)
        }
        let installed = await h.scanner.identities()
        for app in installed {
            let scan = h.matcher().leftovers(for: app, installed: installed)
            #expect(scan.matches.isEmpty, "\(app.name) matched \(scan.matches.map(\.url.lastPathComponent))")
        }
        #expect(LeftoverMatcher.significantTokens("Mac Update Helper App").isEmpty)
        #expect(LeftoverMatcher.significantTokens("Box").isEmpty)
    }

    @Test("Without Full Disk Access, guarded folders are skipped and named")
    func leftoversWithoutAccess() async throws {
        var h = try Harness()
        defer { h.remove() }
        try Self.makeNotes(&h)
        let installed = await h.scanner.identities()
        let notes = try #require(installed.first { $0.bundleID == "com.example.Notes" })
        let scan = h.matcher(access: false).leftovers(for: notes, installed: installed)
        #expect(Set(scan.skippedFolders) == ["Application Support", "Containers", "Group Containers", "Cookies"])
        #expect(
            !scan.matches.contains {
                ["Application Support", "Containers", "Group Containers"].contains($0.folderTitle)
            })
        #expect(scan.matches.contains { $0.folderTitle == "Caches" })
    }

    // MARK: - Scanner

    @Test("The scanner lists apps, one level down, and leaves out Apple, links and nested apps")
    func scannerListing() async throws {
        var h = try Harness()
        defer { h.remove() }
        try h.app("Notes", id: "com.example.Notes", payload: 50_000)
        try h.app("Tool", id: "com.example.Tool", in: h.apps.appendingPathComponent("Utilities"))
        try h.app("Pages", id: "com.apple.iWork.Pages")
        try h.app("Signed", id: "com.vendor.signed")
        h.signing.byName["Signed.app"] = SigningInfo(teamID: "59GAB85EFG", isApple: true)
        let notes = h.apps.appendingPathComponent("Notes.app")
        try h.app("Inner", id: "com.example.Inner", in: notes.appendingPathComponent("Contents/Helpers"))
        try FileManager.default.createSymbolicLink(
            at: h.apps.appendingPathComponent("Linked.app"), withDestinationURL: notes)
        try FileManager.default.createDirectory(
            at: h.apps.appendingPathComponent("NoPlist.app"), withIntermediateDirectories: true)

        let apps = await h.scanner.installedApps()
        #expect(Set(apps.map(\.bundleID)) == ["com.example.Notes", "com.example.Tool"])
        let record = try #require(apps.first { $0.bundleID == "com.example.Notes" })
        #expect(record.size >= 50_000 && record.version == "1.2" && record.name == "Notes")
    }

    @Test("Unused means opened more than six months ago")
    func unusedBadge() {
        let now = Date()
        func app(_ days: Double?) -> AppRecord {
            AppRecord(
                bundleID: "a.b.c", teamID: nil, name: "A", url: URL(fileURLWithPath: "/A.app"), version: "",
                size: 0, lastUsed: days.map { now.addingTimeInterval(-$0 * 86_400) })
        }
        #expect(app(200).isUnused(now: now))
        #expect(!app(30).isUnused(now: now))
        #expect(!app(nil).isUnused(now: now))
    }

    // MARK: - Uninstall

    @Test("Uninstall moves the bundle and selected leftovers to the Trash; undo restores all byte-identical")
    func uninstallRoundTrip() async throws {
        var h = try Harness()
        defer { h.remove() }
        try Self.makeNotes(&h)
        let record = try await h.record("com.example.Notes")
        let installed = await h.scanner.identities()
        let scan = h.matcher().leftovers(for: record.identity, installed: installed)
        let selected = scan.matches.filter(\.isSelectedByDefault)
        #expect(selected.count >= 5)
        var digests: [String: String] = [record.url.path: try CleanerTests.digest(record.url)]
        for match in selected { digests[match.url.path] = try Self.fileDigest(match.url) }

        let cleaner = h.cleaner()
        let report = await cleaner.uninstall(app: record, leftovers: selected)
        #expect(report.skipped.isEmpty, "\(report.skipped)")
        #expect(report.appRemoved)
        #expect(report.moved.count == selected.count + 1)
        for path in digests.keys { #expect(!FileManager.default.fileExists(atPath: path)) }
        for moved in report.moved { #expect(PathTools.isInside(moved.trashed.path, root: h.trash.path)) }
        // Unselected and other apps' things stay.
        #expect(FileManager.default.fileExists(atPath: h.lib("Logs/Notes Sync").path))
        #expect(FileManager.default.fileExists(atPath: h.lib("Caches/com.example.NotesPro").path))
        let logs = try await h.store.logs()
        #expect(logs.count == report.moved.count)
        #expect(logs.allSatisfy { $0.ruleID == "app:com.example.Notes" })

        let undo = await cleaner.undo(report.logIDs)
        #expect(undo.failed.isEmpty, "\(undo.failed)")
        #expect(Set(undo.restored) == Set(report.logIDs))
        for (path, digest) in digests {
            #expect(try Self.fileDigest(URL(fileURLWithPath: path)) == digest, "\(path)")
        }
        #expect(try await h.store.logs().allSatisfy { $0.restoredAt != nil })
    }

    static func fileDigest(_ url: URL) throws -> String {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return try CleanerTests.digest(url) }
        return try Data(contentsOf: url).base64EncodedString()
    }

    static func forged(_ url: URL, id: String = "com.example.Notes", folder: String = "Caches") -> LeftoverMatch {
        LeftoverMatch(
            appBundleID: id, url: url, reason: .bundleID, confidence: .high, explanation: "forged",
            folderTitle: folder, size: 1, modified: .distantPast, status: .removable)
    }

    @Test("The Cleaner refuses forged leftovers")
    func forgedLeftovers() async throws {
        var h = try Harness()
        defer { h.remove() }
        try Self.makeNotes(&h)
        try h.fixture.file("Documents/com.example.Notes/doc.txt", bytes: 100)
        try h.fixture.symlink("Library/Caches/com.example.Notes.link", to: h.fixture.path("Documents"))
        try h.fixture.file("Library/Caches/com.example.Notes.Deep/inner/com.example.Notes/x", bytes: 10)
        try h.fixture.file("Library/Caches/Unrelated/x.bin", bytes: 10)
        let record = try await h.record("com.example.Notes")
        let cases: [(URL, SkipReason, String)] = [
            (h.fixture.path("Documents/com.example.Notes"), .notALeftover, "outside Library folders"),
            (h.lib("Caches/com.example.Notes.Widget"), .notALeftover, "another installed app's folder"),
            (h.lib("Caches/com.example.NotesPro"), .notALeftover, "look-alike app's folder"),
            (h.lib("Caches/Unrelated"), .notALeftover, "no name match"),
            (h.lib("Containers/com.apple.Notes"), .protected, "Apple container"),
            (h.lib("Caches/com.example.Notes.link"), .isSymlink, "link"),
            (h.lib("Caches/com.example.Notes.Deep/inner/com.example.Notes"), .notALeftover, "not a direct child"),
            (h.lib("Application Support/com.example.Notes"), .protected, "app database"),
            (
                h.systemLibrary.appendingPathComponent("LaunchAgents/com.example.Notes.helper.plist"), .needsHelper,
                "/Library"
            ),
            (URL(fileURLWithPath: h.lib("Caches").path + "/../Caches/com.example.Notes"), .notALeftover, "dot-dot"),
            (h.lib("Caches/com.example.Gone"), .notFound, "missing"),
        ]
        let cleaner = h.cleaner()
        let report = await cleaner.uninstall(app: record, leftovers: cases.map { Self.forged($0.0) })
        #expect(report.appRemoved)
        #expect(report.moved.count == 1)
        for (url, reason, label) in cases {
            #expect(report.skipped.first { $0.url == url }?.reason == reason, "\(label)")
        }
        // A leftover claimed for a different app is refused too.
        try h.app("Notes", id: "com.example.Notes")
        let again = try await h.record("com.example.Notes")
        let other = await cleaner.uninstall(
            app: again, leftovers: [Self.forged(h.lib("Caches/com.example.Notes"), id: "com.example.NotesPro")])
        #expect(other.skipped.first { $0.url.lastPathComponent == "com.example.Notes" }?.reason == .notALeftover)
        #expect(FileManager.default.fileExists(atPath: h.fixture.path("Documents/com.example.Notes/doc.txt").path))
        #expect(FileManager.default.fileExists(atPath: h.lib("Containers/com.apple.Notes").path))
        #expect(FileManager.default.fileExists(atPath: h.lib("Caches/com.example.Notes.Widget").path))
    }

    @Test("The Cleaner re-checks the app bundle itself")
    func forgedApps() async throws {
        var h = try Harness()
        defer { h.remove() }
        let notes = try h.app("Notes", id: "com.example.Notes")
        try h.app("Pages", id: "com.apple.iWork.Pages")
        try h.app("Signed", id: "com.vendor.signed")
        let outside = try h.app("Elsewhere", id: "com.example.Elsewhere", in: h.fixture.path("Downloads"))
        try FileManager.default.createSymbolicLink(
            at: h.apps.appendingPathComponent("Link.app"), withDestinationURL: notes)
        let record = try await h.record("com.example.Notes")
        func fake(_ url: URL, _ id: String) -> AppRecord {
            AppRecord(bundleID: id, teamID: nil, name: "X", url: url, version: "", size: 1, lastUsed: nil)
        }
        h.signing.byName["Signed.app"] = SigningInfo(teamID: nil, isApple: true)
        let cleaner = h.cleaner(running: ["com.example.Notes": "Notes"])
        let cases: [(AppRecord, SkipReason)] = [
            (fake(notes, "com.example.Other"), .notAnApp),
            (fake(outside, "com.example.Elsewhere"), .notAnApp),
            (fake(h.apps.appendingPathComponent("Link.app"), "com.example.Notes"), .isSymlink),
            (fake(h.apps.appendingPathComponent("Pages.app"), "com.apple.iWork.Pages"), .appleApp),
            (fake(h.apps.appendingPathComponent("Signed.app"), "com.vendor.signed"), .appleApp),
            (fake(h.lib("Caches"), "com.example.Notes"), .notAnApp),
            (record, .appRunning("Notes")),
        ]
        for (app, reason) in cases {
            let report = await cleaner.uninstall(app: app, leftovers: [Self.forged(h.lib("Caches/com.example.Notes"))])
            #expect(report.moved.isEmpty)
            #expect(report.skipped.first?.reason == reason, "\(app.url.lastPathComponent)")
        }
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test("If the app won't move, its leftovers stay")
    func appMoveFails() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.app("Notes", id: "com.example.Notes")
        try h.fixture.file("Library/Caches/com.example.Notes/c.bin", bytes: 100)
        let record = try await h.record("com.example.Notes")
        let scanner = h.scanner
        let cleaner = Cleaner(
            home: h.fixture.url, trashMover: FailingTrashMover(trashDirectory: h.trash), runningApps: FakeRunningApps(),
            store: h.store, protectedList: ProtectedList(home: h.fixture.url), rules: { [] }, now: { h.fixture.now },
            appContext: AppCleaningContext(
                appRoots: [h.apps], systemLibrary: h.systemLibrary, signing: h.signing,
                installedApps: { await scanner.identities() }, isKnownApp: { _ in false }))
        let report = await cleaner.uninstall(app: record, leftovers: [Self.forged(h.lib("Caches/com.example.Notes"))])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.appMoveFailed, .appNotRemoved])
        #expect(FileManager.default.fileExists(atPath: h.lib("Caches/com.example.Notes").path))
    }

    // MARK: - Orphans

    @Test("Orphans: bundle-ID names no app has, older than 30 days, never protected or Apple")
    func orphans() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.app("Notes", id: "com.example.Notes")
        let f = h.fixture
        try f.file("Library/Caches/com.gone.Tool/c.bin", bytes: 5_000, ageDays: 90)
        try f.file("Library/Preferences/com.gone.Tool.plist", bytes: 100, ageDays: 90)
        try f.file("Library/Caches/com.gone.Fresh/c.bin", bytes: 100, ageDays: 5)
        try f.file("Library/Caches/com.apple.Something/c.bin", bytes: 100, ageDays: 90)
        try f.file("Library/Caches/com.example.Retired/c.bin", bytes: 100, ageDays: 90)
        try f.file("Library/Caches/com.known.Elsewhere/c.bin", bytes: 100, ageDays: 90)
        try f.file("Library/Caches/NotAnID/c.bin", bytes: 100, ageDays: 90)
        try f.file("Library/Containers/com.apple.Thing/Data/x", bytes: 100, ageDays: 90)
        try f.file("Library/Application Support/net.old.Writer/db.sqlite", bytes: 100, ageDays: 90)
        try f.symlink("Library/Caches/com.gone.Link", to: f.path("Documents"))
        let installed = await h.scanner.identities()
        let scan = h.matcher().orphans(installed: installed, isKnownApp: { $0 == "com.known.Elsewhere" })
        let names = Set(scan.matches.map(\.url.lastPathComponent))
        #expect(names == ["com.gone.Tool", "com.gone.Tool.plist", "net.old.Writer"])
        #expect(scan.matches.allSatisfy { !$0.isSelectedByDefault && $0.confidence == .low })
        #expect(scan.matches.first { $0.url.lastPathComponent == "net.old.Writer" }?.status == .holdsDatabase)

        // The Cleaner re-checks: a recent one, an installed vendor's folder and a known app are refused.
        let cleaner = h.cleaner(known: ["com.known.Elsewhere"])
        let candidates =
            scan.matches + [
                Self.forged(h.lib("Caches/com.gone.Fresh"), id: "com.gone.Fresh"),
                Self.forged(h.lib("Caches/com.example.Retired"), id: "com.example.Retired"),
                Self.forged(h.lib("Caches/com.known.Elsewhere"), id: "com.known.Elsewhere"),
                Self.forged(h.lib("Caches/com.gone.Link"), id: "com.gone.Link"),
            ]
        let report = await cleaner.removeOrphans(candidates)
        #expect(Set(report.moved.map(\.original.lastPathComponent)) == ["com.gone.Tool", "com.gone.Tool.plist"])
        let reasons = Dictionary(uniqueKeysWithValues: report.skipped.map { ($0.url.lastPathComponent, $0.reason) })
        #expect(reasons["com.gone.Fresh"] == .tooRecent)
        #expect(reasons["com.example.Retired"] == .notALeftover)
        #expect(reasons["com.known.Elsewhere"] == .notALeftover)
        #expect(reasons["com.gone.Link"] == .isSymlink)
        #expect(reasons["net.old.Writer"] == .protected)
        #expect(try await h.store.logs().allSatisfy { $0.ruleID?.hasPrefix("orphan:") == true })
        let undo = await cleaner.undo(report.logIDs)
        #expect(undo.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: h.lib("Caches/com.gone.Tool/c.bin").path))
    }

    // MARK: - Model

    @Test("Uninstalling an open app asks to quit it first, politely")
    @MainActor
    func quitFirst() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.app("Notes", id: "com.example.Notes")
        let quitter = FakeQuitter(succeeds: false)
        let model = AppsModel(
            scanner: h.scanner, cleaner: h.cleaner(), home: h.fixture.url, systemLibrary: h.systemLibrary,
            runningApps: FakeRunningApps(running: ["com.example.Notes": "Notes"]), quitter: quitter,
            isKnownApp: { _ in false }, now: { h.fixture.now })
        await model.load(hasFullDiskAccess: true)
        await model.select(model.apps.first)
        model.requestUninstall()
        #expect(model.quitPromptName == "Notes")
        #expect(!model.isConfirmingUninstall)
        await model.confirmQuit()
        #expect(quitter.asked == ["com.example.Notes"])
        #expect(model.issue == .appDidNotQuit("Notes"))
        #expect(!model.isConfirmingUninstall)
        quitter.succeeds = true
        model.requestUninstall()
        await model.confirmQuit()
        #expect(model.isConfirmingUninstall)
    }

    @Test("Dustpan never uninstalls itself: no quit prompt, and the Cleaner refuses its bundle")
    @MainActor
    func neverUninstallsItself() async throws {
        let h = try Harness()
        defer { h.remove() }
        let bundle = try h.app("Dustpan", id: "app.dustpan.Dustpan")
        let quitter = FakeQuitter(succeeds: true)
        let model = AppsModel(
            scanner: h.scanner, cleaner: h.cleaner(), home: h.fixture.url, systemLibrary: h.systemLibrary,
            runningApps: FakeRunningApps(running: ["app.dustpan.Dustpan": "Dustpan"]), quitter: quitter,
            isKnownApp: { _ in false }, now: { h.fixture.now }, ownBundleID: "app.dustpan.Dustpan")
        await model.load(hasFullDiskAccess: true)
        await model.select(model.apps.first)
        let app = try #require(model.selectedApp)
        #expect(model.isDustpan(app))
        model.requestUninstall()
        #expect(model.quitPromptName == nil)
        #expect(!model.isConfirmingUninstall)
        #expect(quitter.asked.isEmpty)

        // Even asked directly (and with Dustpan not running), the Cleaner keeps it.
        let report = await h.cleaner().uninstall(app: app, leftovers: [])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.first?.reason == .dustpanItself)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        let own = ["/x/Dustpan.app"]
        #expect(!Cleaner.isDustpan(path: "/x/Other.app", bundleID: "com.example.Other", ownPaths: own))
        #expect(Cleaner.isDustpan(path: "/x/Dustpan.app", bundleID: "com.example.Renamed", ownPaths: own))
    }

    // MARK: - Review round 1

    @Test("Team-ID group containers with a group. prefix belong to their app, never orphans")
    func teamGroupContainers() async throws {
        var h = try Harness()
        defer { h.remove() }
        h.signing.byName["Notes.app"] = SigningInfo(teamID: "EXAMPLE123", isApple: false)
        try h.app("Notes", id: "com.example.Notes")
        try h.app("Teams", id: "com.microsoft.teams2")
        try h.fixture.file("Library/Group Containers/EXAMPLE123.group.com.example.Notes/x", bytes: 100, ageDays: 90)
        try h.fixture.file("Library/Group Containers/UBF8T346G9.group.com.microsoft.shared/x", bytes: 100, ageDays: 90)
        try h.fixture.file("Library/Group Containers/ABCDE12345.group.com.gone.Thing/x", bytes: 100, ageDays: 90)
        #expect(
            LeftoverMatcher.idPart(of: "EQHXZ8M8AV.group.com.google.drivefs", inGroupContainers: true).id
                == "com.google.drivefs")
        let installed = await h.scanner.identities()
        let notes = try #require(installed.first { $0.bundleID == "com.example.Notes" })
        let leftovers = h.matcher().leftovers(for: notes, installed: installed)
        #expect(
            leftovers.matches.first { $0.url.lastPathComponent == "EXAMPLE123.group.com.example.Notes" }?.reason
                == .bundleID)
        let orphans = h.matcher().orphans(installed: installed, isKnownApp: { _ in false })
        #expect(orphans.matches.map(\.url.lastPathComponent) == ["ABCDE12345.group.com.gone.Thing"])
        let report = await h.cleaner().removeOrphans([
            Self.forged(h.lib("Group Containers/UBF8T346G9.group.com.microsoft.shared"), id: "com.microsoft.shared")
        ])
        #expect(report.moved.isEmpty && report.skipped.first?.reason == .notALeftover)
    }

    @Test("macOS's own data and developer tools are never orphans or leftovers")
    func systemAndToolingNames() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.app("LINE", id: "jp.naver.line.mac")
        try h.app("Workflow Pal", id: "is.workflow.pal")
        let f = h.fixture
        for relative in [
            "Library/Group Containers/group.is.workflow.shortcuts/x",
            "Library/Group Containers/group.is.workflow.my.app/x",
            "Library/Containers/is.workflow.my.app/Data/x",
            "Library/Preferences/org.cups.PrintingPrefs.plist",
            "Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist",
            "Library/Caches/org.swift.swiftpm/x",
            "Library/Caches/com.Breakpad.crash_report_sender/x",
            "Library/Containers/LINE.VideoPreviewService.0/Data/x",
            "Library/Caches/com.gone.Parent.Helper/x",
            "Library/Caches/com.gone.Lonely/x",
        ] {
            try f.file(relative, bytes: 100, ageDays: 90)
        }
        let installed = await h.scanner.identities()
        let known: @Sendable (String) -> Bool = { $0 == "com.gone.Parent" }
        let orphans = h.matcher().orphans(installed: installed, isKnownApp: known)
        #expect(orphans.matches.map(\.url.lastPathComponent) == ["com.gone.Lonely"])
        #expect(
            LeftoverMatcher.idChain("com.gone.Parent.Helper.x") == [
                "com.gone.Parent.Helper.x", "com.gone.Parent.Helper", "com.gone.Parent",
            ])
        // An app whose ID looks like Shortcuts' still never claims Shortcuts' data.
        let pal = try #require(installed.first { $0.bundleID == "is.workflow.pal" })
        #expect(h.matcher().leftovers(for: pal, installed: installed).matches.isEmpty)
        // The Cleaner applies the same rules.
        let report = await h.cleaner(known: ["com.gone.Parent"]).removeOrphans([
            Self.forged(h.lib("Group Containers/group.is.workflow.shortcuts"), id: "x"),
            Self.forged(h.lib("Preferences/org.cups.PrintingPrefs.plist"), id: "x"),
            Self.forged(h.lib("LaunchAgents/homebrew.mxcl.postgresql@16.plist"), id: "x"),
            Self.forged(h.lib("Caches/com.gone.Parent.Helper"), id: "x"),
            Self.forged(h.lib("Containers/LINE.VideoPreviewService.0"), id: "x"),
        ])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.allSatisfy { $0.reason == .notALeftover })
    }

    @Test("A folder of an app macOS knows elsewhere isn't this app's leftover")
    func knownElsewhere() async throws {
        let h = try Harness()
        defer { h.remove() }
        try h.app("Bar", id: "com.foo.Bar")
        try h.fixture.file("Library/Caches/com.foo.Bar.Pro/x", bytes: 100)
        try h.fixture.file("Library/Caches/com.foo.Bar.Pro.Helper/x", bytes: 100)
        try h.fixture.file("Library/Caches/com.foo.Bar.ShipIt/x", bytes: 100)
        try h.fixture.file("Library/Caches/com.foo.Bar/x", bytes: 100)
        let barPath = h.apps.appendingPathComponent("Bar.app").path
        let elsewhere = [
            "com.foo.Bar.Pro": "/Users/Shared/Bar Pro.app",
            // A helper inside the app's own bundle is still the app's.
            "com.foo.Bar.ShipIt": barPath + "/Contents/Frameworks/ShipIt.app",
        ]
        let installed = await h.scanner.identities()
        let bar = try #require(installed.first)
        let names = Set(
            h.matcher(elsewhere: elsewhere).leftovers(for: bar, installed: installed).matches.map(
                \.url.lastPathComponent))
        #expect(names == ["com.foo.Bar.ShipIt", "com.foo.Bar"])
        // Its own ID known at another path (a second copy): matched but low and unticked.
        let copy = h.matcher(elsewhere: ["com.foo.Bar": "/Volumes/Backup/Bar.app"])
            .leftovers(for: bar, installed: installed)
        #expect(copy.matches.allSatisfy { $0.confidence == .low && !$0.isSelectedByDefault })

        let record = try await h.record("com.foo.Bar")
        let report = await h.cleaner(elsewhere: elsewhere).uninstall(
            app: record,
            leftovers: [
                Self.forged(h.lib("Caches/com.foo.Bar.Pro"), id: "com.foo.Bar"),
                Self.forged(h.lib("Caches/com.foo.Bar.Pro.Helper"), id: "com.foo.Bar"),
            ])
        #expect(report.appRemoved)
        #expect(report.skipped.map(\.reason) == [.notALeftover, .notALeftover])
    }

    @Test("Apps deeper than one sub-folder aren't listed (the Cleaner couldn't remove them)")
    func depthLimit() {
        let roots = ["/Applications"]
        #expect(AppScanner.isAcceptable("/Applications/X.app", roots: roots))
        #expect(AppScanner.isAcceptable("/Applications/Utilities/X.app", roots: roots))
        #expect(!AppScanner.isAcceptable("/Applications/Vendor/Suite/X.app", roots: roots))
        #expect(!AppScanner.isAcceptable("/Applications/Y.app/Contents/X.app", roots: roots))
    }
}

/// A Trash that always refuses (e.g. an app owned by another user).
struct FailingTrashMover: TrashMover {
    let trashDirectory: URL
    func trash(_ url: URL) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
}
