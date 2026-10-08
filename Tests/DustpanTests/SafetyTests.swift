import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Dustpan

// MARK: - CLAUDE.md safety rules → tests
//
// | Safety rule (CLAUDE.md)                                   | Tests                                                     |
// |-----------------------------------------------------------|-----------------------------------------------------------|
// | 1. Trash only, every move logged; only Empty Trash        | `SafetyTests.everyFlow` (every move is in the temp Trash  |
// |    deletes, after a confirm listing the size               |   with a log row), `onlyEmptyTrashDeletes` (source scan), |
// |                                                           |   `CleanerTests` Empty Trash tests (confirmed names only)  |
// | 2. ProtectedList, checked by scanners and Cleaner         | `everyFlow` (Sweep, Junk select-all, Apps uninstall +     |
// |    (system roots, iCloud, Mail, Photos, Apple containers, |   orphans, Large & old, Duplicates, Space map, forged     |
// |    Keychains, MobileSync, app databases + their files)    |   requests to every Cleaner API; FDA on and off),         |
// |                                                           |   `scannersNeverOfferDecoys`, `ProtectedListTests`         |
// | 3. Recent (< 7 days) and `.review` never pre-selected;    | `everyFlow` (pre-selection invariant on the bundled        |
// |    `.never` never appears                                 |   catalogue), `preselectionRules`                          |
// | 4. Resolve symlinks; refuse anything leaving the rule root| `everyFlow` (links from Caches/Logs into Documents, a     |
// |                                                           |   symlinked parent), `CleanerFuzzTests` (thousands of     |
// |                                                           |   mangled paths, loops, symlinked parents)                 |
// | 5. `requiresQuit` + app running → skip and say so         | `everyFlow` (Chrome open: left out of Clean recommended   |
// |                                                           |   and Junk select-all up front, Cleaner refuses it when   |
// |                                                           |   handed it anyway), `CleanerTests` requiresQuit tests,   |
// |                                                           |   `OpenAppsTests`                                          |

/// A fake home full of things Dustpan must never move ("decoys"), next to ordinary junk that it
/// should move (so a flow that silently did nothing can't pass).
struct DecoyHome {
    let h: SweepHarness
    var fixture: FixtureHome { h.fixture }

    /// Never moved by any flow, whatever the user ticks (safety rules 2 and 4).
    static let protectedRoots = [
        "Library/Application Support/Code/CachedData",  // a rule's item that holds an app database
        "Library/Application Support/obsidian",  // app folder with a database and a loose log beside it
        "Library/Application Support/DEVONthink 3",
        "Library/Application Support/com.example.victim",  // an uninstalled app's database
        "Library/Application Support/com.gone.dbapp",  // a deleted app's database (orphan)
        "Library/Application Support/MobileSync",
        "Pictures/Photos Library.photoslibrary",
        "Library/Mobile Documents",
        "Library/Mail",
        "Library/Keychains",
        "Library/Containers/com.apple.Notes",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Group Containers/ABCDE12345.com.apple.foo",
        "Library/CloudStorage",
        "Documents/Project",  // a user folder holding an app database
        "Library/Caches/com.example.linked",  // a link into Documents (the link itself)
        "Library/Logs/com.example.linkedlog",  // same, in Logs
        "Library/Caches/Google",  // a symlinked parent of Chrome's cache rule
    ]
    /// Only reachable through links; never asked for directly, must never change.
    static let linkTargets = ["Documents/Taxes"]
    /// Junk flows (Sweep, Junk screen) must never move these: `.never` rules, a log younger than
    /// its rule allows, and Chrome's cache while Chrome is open (`requiresQuit`).
    static let junkOnly = [
        "Library/Caches/com.spotify.client",
        "Library/Caches/CloudKit",
        "Library/Autosave Information",
        ".ollama/models",
        "Library/Logs/com.example.freshlog",
        "Library/Caches/com.google.Chrome",
    ]
    /// Clean recommended must leave it (changed an hour ago); a user may still tick it on the Junk screen.
    static let sweepOnly = ["Library/Caches/com.example.fresh"]
    /// Ordinary junk the Sweep should move.
    static let recommendedJunk = [
        "Library/Caches/com.example.app", "Library/Caches/com.example.dbcache", "Library/Logs/com.example.sync",
    ]

    static let chromeID = "com.google.Chrome"

    init() throws {
        h = try SweepHarness()
    }

    func build() throws {
        let f = fixture
        let hour = 1.0 / 24
        // Protected: app databases, with ordinary files beside them.
        try f.file("Library/Application Support/Code/CachedData/state.sqlite", bytes: 8_000, ageDays: 60)
        try f.file("Library/Application Support/Code/CachedData/notes.txt", bytes: 3_000, ageDays: 60)
        try f.file("Library/Application Support/obsidian/store.sqlite", bytes: 8_000, ageDays: 60)
        try f.file("Library/Application Support/obsidian/old.log", bytes: 5_000, ageDays: 60)
        try f.file("Library/Application Support/DEVONthink 3/Inbox.dtBase2/DEVONthink-1.sqlite", bytes: 9_000)
        try f.file("Library/Application Support/DEVONthink 3/Inbox.dtBase2/Files.noindex/doc.pdf", bytes: 7_000)
        try f.file("Library/Application Support/com.example.victim/store.sqlite", bytes: 6_000, ageDays: 90)
        try f.file("Library/Application Support/com.example.victim/settings.json", bytes: 1_000, ageDays: 90)
        try f.file("Library/Application Support/com.gone.dbapp/data.sqlite", bytes: 6_000, ageDays: 90)
        try f.file("Library/Application Support/com.gone.dbapp/prefs.json", bytes: 1_000, ageDays: 90)
        try f.file("Library/Application Support/MobileSync/Backup/abc123/Manifest.db", bytes: 9_000, ageDays: 200)
        try f.file("Library/Application Support/MobileSync/Backup/abc123/00/0a1b", bytes: 4_000, ageDays: 200)
        // Photos, iCloud, Mail, Keychains, Apple containers, cloud storage.
        try f.file("Pictures/Photos Library.photoslibrary/database/Photos.sqlite", bytes: 9_000, ageDays: 400)
        try f.file("Pictures/Photos Library.photoslibrary/originals/IMG_0001.heic", bytes: 300_000, ageDays: 400)
        try h.reserve("Pictures/Photos Library.photoslibrary/originals/clip.mov", bytes: 120_000_000, ageDays: 400)
        try f.file("Library/Mobile Documents/com~apple~CloudDocs/Notes.txt", bytes: 2_000, ageDays: 400)
        try f.file("Library/Mail/V10/MailData/Envelope Index", bytes: 9_000, ageDays: 400)
        try f.file("Library/Mail/V10/INBOX.mbox/1.emlx", bytes: 2_000, ageDays: 400)
        try f.file("Library/Keychains/login.keychain-db", bytes: 4_000, ageDays: 400)
        try f.file("Library/Containers/com.apple.Notes/Data/Library/Caches/x.bin", bytes: 4_000, ageDays: 400)
        try f.file("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", bytes: 4_000, ageDays: 400)
        try f.file("Library/Group Containers/ABCDE12345.com.apple.foo/data.bin", bytes: 4_000, ageDays: 400)
        try f.file("Library/CloudStorage/Dropbox/Report.txt", bytes: 4_000, ageDays: 400)
        // A user folder with an app database, a big old file and a copy of a photo in it.
        let photo = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        try f.file("Documents/Project/app.sqlite", bytes: 5_000, ageDays: 400)
        try photo.write(to: f.path("Documents/Project/photo.jpg"))
        try h.reserve("Documents/Project/big.bin", bytes: 120_000_000, ageDays: 400)
        try photo.write(to: f.path("Pictures/Photos Library.photoslibrary/originals/IMG_0001.heic"))
        // Links into Documents, from Caches and Logs, and a symlinked parent.
        try f.file("Documents/Taxes/return.pdf", bytes: 6_000, ageDays: 400)
        try f.symlink("Library/Caches/com.example.linked", to: f.path("Documents/Taxes"))
        try f.symlink("Library/Logs/com.example.linkedlog", to: f.path("Documents/Taxes"))
        try f.file("Library/Caches/com.example.withlink/data.bin", bytes: 5_000, ageDays: 30)
        try f.symlink("Library/Caches/com.example.withlink/docs", to: f.path("Documents/Taxes"))
        try f.file("", bytes: 9_000, ageDays: 30, absolute: f.outside.appendingPathComponent("Google/Chrome/data_0"))
        try f.file(
            "", bytes: 9_000, ageDays: 30, absolute: f.outside.appendingPathComponent("Google/AndroidStudio2024.1/x"))
        try f.symlink("Library/Caches/Google", to: f.outside.appendingPathComponent("Google"))
        // Junk-only decoys: `.never` places, a log changed an hour ago, Chrome's cache (Chrome open).
        try f.file("Library/Caches/com.spotify.client/Storage/offline.bnk", bytes: 20_000, ageDays: 90)
        try f.file("Library/Caches/CloudKit/records.bin", bytes: 5_000, ageDays: 90)
        try f.file("Library/Autosave Information/Unsaved.rtf", bytes: 3_000, ageDays: 90)
        try f.file(".ollama/models/blobs/sha256-1", bytes: 20_000, ageDays: 90)
        try f.file("Library/Logs/com.example.freshlog/now.log", bytes: 3_000, ageDays: hour)
        try f.file("Library/Caches/com.google.Chrome/Default/Cache/data_0", bytes: 20_000, ageDays: 30)
        try f.file("Library/Caches/com.example.fresh/hot.bin", bytes: 6_000, ageDays: hour)
        // Ordinary junk (should go), including a database file inside Caches (allowed there).
        try f.file("Library/Caches/com.example.app/a.bin", bytes: 12_000, ageDays: 30)
        try f.file("Library/Caches/com.example.dbcache/Cache.db", bytes: 12_000, ageDays: 30)
        try f.file("Library/Logs/com.example.sync/sync.log", bytes: 9_000, ageDays: 20)
        try f.file(".cache/zzreview/d.bin", bytes: 8_000, ageDays: 30)
        // An installed app with leftovers, a deleted app's leftover, copies, a big old movie.
        try h.app("Victim", id: "com.example.victim", payload: 40_000)
        try f.file("Library/Caches/com.example.victim/c.bin", bytes: 7_000, ageDays: 40)
        try f.file("Library/Preferences/com.example.victim.plist", bytes: 1_000, ageDays: 40)
        try f.file("Library/Preferences/com.gone.oldapp.plist", bytes: 3_000, ageDays: 90)
        try photo.write(to: f.path("Downloads/photo.jpg").creatingParent())
        try photo.write(to: f.path("Pictures/photo copy.jpg"))
        try h.reserve("Movies/old.mov", bytes: 150_000_000, ageDays: 400)
    }

    /// The whole app on the fake home; Chrome counts as open.
    @MainActor
    func appState(access: Bool) async -> AppState {
        let state = AppState(
            database: h.database, permissions: FakePermissions(flag: AccessFlag(granted: access)),
            home: fixture.url, trashMover: TempTrashMover(trashDirectory: h.trash),
            runningApps: FakeRunningApps(running: [Self.chromeID: "Google Chrome"]), appRoots: [h.apps],
            systemLibrary: h.systemLibrary, signing: FakeSigning(), lastUsed: FakeLastUsed())
        await state.onboarding.load(allowPresentation: false)
        return state
    }

    func url(_ relative: String) -> URL { fixture.path(relative) }

    /// Every entry under the listed places (links not followed): type, size, date and content
    /// hash, or the link's target. Also covers the symlinked parent's real folder outside home.
    func snapshot(_ roots: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for root in roots { Self.fingerprint(url(root).path, into: &result) }
        Self.fingerprint(fixture.outside.appendingPathComponent("Google").path, into: &result)
        return result
    }

    static func fingerprint(_ path: String, into result: inout [String: String]) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            result[path] = "missing"
            return
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            result[path] = "link → " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?")
        case S_IFDIR:
            result[path] = "dir"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                fingerprint(path + "/" + name, into: &result)
            }
        default:
            let digest =
                (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped))
                .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unreadable"
            result[path] = "file \(info.st_size) \(info.st_mtimespec.tv_sec) \(digest)"
        }
    }

    /// Every path at or inside a protected root (for forged requests and the Space map).
    func protectedPaths() -> [URL] {
        var paths: [URL] = []
        for root in Self.protectedRoots {
            var map: [String: String] = [:]
            Self.fingerprint(url(root).path, into: &map)
            paths += map.keys.sorted().map { URL(fileURLWithPath: $0) }
        }
        return paths.filter { !$0.path.hasPrefix(fixture.outside.path) }
    }

    /// At or inside a protected root (not a link target): Dustpan must refuse it even when asked directly.
    func isProtectedPlace(_ path: String) -> Bool {
        Self.protectedRoots.contains { PathTools.isInside(path.lowercased(), root: url($0).path) }
    }

    /// A protected place, a link target, or the symlinked parent's real folder: never listed, never moved.
    func isProtectedDecoy(_ path: String) -> Bool {
        let lower = path.lowercased()
        return (Self.protectedRoots + Self.linkTargets).contains { PathTools.isInside(lower, root: url($0).path) }
            || PathTools.isInside(lower, root: fixture.outside.path)
    }

    func remove() { h.remove() }
}

@Suite("Safety: decoys never move", .serialized)
struct SafetyTests {
    /// Runs every flow that can move something, as a user who ticks everything would, then
    /// sends forged requests for every decoy to every Cleaner API. Nothing protected may move.
    @Test("No decoy moves in any flow", arguments: [true, false])
    @MainActor
    func everyFlow(fullDiskAccess access: Bool) async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        try d.build()
        let all = DecoyHome.protectedRoots + DecoyHome.linkTargets + DecoyHome.junkOnly + DecoyHome.sweepOnly
        let before = d.snapshot(all)
        let state = await d.appState(access: access)
        let rules = try await state.ruleCatalog.rules()
        let neverIDs = Set(rules.filter { $0.risk == .never }.map(\.id))

        // 1. Sweep → Clean recommended.
        await state.sweep.sweep()
        #expect(state.sweep.phase == .results)
        let swept = state.junk.allItems
        #expect(!swept.isEmpty)
        checkPreselection(swept, neverIDs: neverIDs, now: d.fixture.now)
        #expect(swept.allSatisfy { !d.isProtectedDecoy($0.url.path) }, "a protected decoy was listed")
        #expect(!state.sweep.recommendedItems.contains { $0.url.lastPathComponent == "com.example.fresh" })
        await state.sweep.confirmClean()
        let sweepReport = try #require(state.sweep.lastReport)
        let movedNames = Set(sweepReport.moved.map { $0.original.path })
        for junk in DecoyHome.recommendedJunk {
            #expect(movedNames.contains(d.url(junk).path), "\(junk) should have been cleaned")
        }
        // Chrome is open: its cache is left out up front and named, so the Cleaner never sees it.
        #expect(state.sweep.leftOut.contains { $0.app.name == "Google Chrome" })
        #expect(!sweepReport.skipped.contains { $0.reason == .appRunning("Google Chrome") })
        try await checkLogged(sweepReport.moved.map(\.trashed), store: state.cleanupStore, trash: d.h.trash)
        expectUnchanged(before, d.snapshot(all), "Sweep → Clean recommended")

        // 2. Junk screen: tick everything, including `.review` items, and clean.
        await state.junk.scan(hasFullDiskAccess: access)
        checkPreselection(state.junk.allItems, neverIDs: neverIDs, now: d.fixture.now)
        for result in state.junk.results {
            state.junk.focusedCategory = result.category
            state.junk.setAllVisibleSelected(true)
        }
        #expect(state.junk.selectedItems.contains { $0.risk == .review })
        // Select-all skips Chrome's cache (Chrome is open) and says so.
        let chromeItem = try #require(state.junk.allItems.first { state.junk.blocker(for: $0) != nil })
        #expect(!state.junk.isSelected(chromeItem) && state.junk.skippedForOpenApps > 0)
        state.junk.requestClean()
        #expect(state.junk.blockedGroups.isEmpty)
        await state.junk.confirmClean()
        let junkReport = try #require(state.junk.lastReport)
        #expect(!junkReport.skipped.contains { $0.reason == .appRunning("Google Chrome") })
        // Backstop: handed to the Cleaner anyway, it still refuses while Chrome is open.
        let forced = await state.cleaner.clean([chromeItem])
        #expect(forced.moved.isEmpty && forced.skipped.map(\.reason) == [.appRunning("Google Chrome")])
        try await checkLogged(junkReport.moved.map(\.trashed), store: state.cleanupStore, trash: d.h.trash)
        let junkRoots = DecoyHome.protectedRoots + DecoyHome.linkTargets + DecoyHome.junkOnly
        let sweepOnly = DecoyHome.sweepOnly.map { d.url($0).path }
        let junkBefore = before.filter { key, _ in !sweepOnly.contains { PathTools.isInside(key, root: $0) } }
        expectUnchanged(junkBefore, d.snapshot(junkRoots), "Junk select-all")

        // 3. Apps: uninstall with every leftover ticked, then every removable orphan.
        await state.apps.load(hasFullDiskAccess: access)
        let victim = try #require(state.apps.apps.first { $0.bundleID == "com.example.victim" })
        await state.apps.select(victim)
        let leftovers = state.apps.leftovers?.matches ?? []
        #expect(leftovers.allSatisfy { !$0.isRemovable || !d.isProtectedDecoy($0.url.path) })
        for match in leftovers { state.apps.setLeftover(match, selected: true) }
        state.apps.requestUninstall()
        await state.apps.confirmUninstall()
        #expect(state.apps.lastReport?.appRemoved == true)
        await state.apps.loadOrphans(hasFullDiskAccess: access)
        let orphans = state.apps.orphans?.matches ?? []
        #expect(orphans.allSatisfy { !$0.isRemovable || !d.isProtectedDecoy($0.url.path) })
        for match in orphans { state.apps.setOrphan(match, selected: true) }
        state.apps.requestRemoveOrphans()
        await state.apps.confirmRemoveOrphans()
        // The flows really moved things (so "nothing protected moved" means something).
        #expect(!d.h.exists("Library/Caches/com.example.victim"))
        #expect(!d.h.exists("Library/Preferences/com.gone.oldapp.plist"))
        #expect(!FileManager.default.fileExists(atPath: d.h.apps.appendingPathComponent("Victim.app").path))

        // 4. Clutter: every large & old file, then every duplicate (keeping one).
        state.clutter.largeOld.filter = LargeOldFilter(minimumSize: .mb100, age: .months3, kind: nil)
        await state.clutter.largeOld.scan()
        #expect(state.clutter.largeOld.files.allSatisfy { !d.isProtectedDecoy($0.url.path) })
        if access { #expect(state.clutter.largeOld.files.contains { $0.url.lastPathComponent == "old.mov" }) }
        state.clutter.largeOld.setAllVisibleSelected(true)
        state.clutter.largeOld.requestMove()
        await state.clutter.largeOld.confirmMove()
        await state.clutter.duplicates.scan()
        let copies = state.clutter.duplicates.groups.flatMap(\.files)
        #expect(copies.allSatisfy { !d.isProtectedDecoy($0.url.path) })
        if access { #expect(copies.count == 2) }
        state.clutter.duplicates.selectDuplicatesKeepOne()
        state.clutter.duplicates.requestMove()
        await state.clutter.duplicates.confirmMove()
        if access {
            #expect(!d.h.exists("Movies/old.mov"))
            #expect(d.h.exists("Downloads/photo.jpg") != d.h.exists("Pictures/photo copy.jpg"))
        }

        // 5. Space map: Move to Trash, through the model as the UI does it, on every map block
        // inside a protected place. Protected places are single `.protected` blocks the map
        // doesn't offer at all; anything it does offer must be refused by the Cleaner.
        state.spaceMap.start(.home)
        await state.spaceMap.waitForWalk()
        let tree = try #require(state.spaceMap.tree)
        var inside = 0
        var offered = 0
        for index in 0..<UInt32(tree.count) where d.isProtectedPlace(tree.path(index)) {
            inside += 1
            await state.spaceMap.requestTrash([index])
            guard let pending = state.spaceMap.pendingTrash else { continue }
            offered += 1
            // The pre-check (the Cleaner's own checks) must refuse it, with a reason…
            #expect(pending.allowed.isEmpty, "Space map would move \(tree.path(index))")
            #expect(pending.refused.count == 1, "no reason shown for \(tree.path(index))")
            // …and confirming moves nothing.
            await state.spaceMap.confirmTrash()
            #expect(state.spaceMap.lastMove == nil, "Space map moved \(tree.path(index))")
        }
        #expect(inside > 0)
        if access { #expect(offered > 0, "the map offered nothing to try") }

        // 6. Forged requests: every protected path, straight to every Cleaner API.
        let forged = d.protectedPaths()
        #expect(forged.count > 30)
        let ruleIDs = ["cache.apps", "logs.user", "logs.obsidian", "ai.vscode.cacheddata", "cache.chrome"]
        let items = forged.flatMap { url in
            ruleIDs.map { rule in
                ScanItem(
                    id: UUID(), url: url, allocatedSize: 1, modified: .distantPast, category: .userCache,
                    ruleID: rule, risk: .safe, isSelected: true)
            }
        }
        let cleanReport = await state.cleaner.clean(items)
        #expect(cleanReport.moved.isEmpty, "\(cleanReport.moved.map(\.original.path))")
        for url in forged {
            #expect(await state.cleaner.trashUserChosen(url).moved.isEmpty, "Space map moved \(url.path)")
        }
        #expect(await state.cleaner.trashLargeFiles(forged).moved.isEmpty)
        let keeper = d.url("Pictures/photo copy.jpg")
        let removals = forged.map { DuplicateRemoval(url: $0, keeper: keeper, hash: 0, size: 300_000) }
        #expect(await state.cleaner.trashDuplicates(removals).moved.isEmpty)
        let fakeLeftovers = forged.map { url in
            LeftoverMatch(
                appBundleID: "com.gone.dbapp", url: url, reason: .bundleID, confidence: .high, explanation: "",
                folderTitle: "", size: 1, modified: .distantPast, status: .removable)
        }
        #expect(await state.cleaner.removeOrphans(fakeLeftovers).moved.isEmpty)
        try d.h.app("Victim2", id: "com.example.victim", payload: 1_000)
        let victim2 = AppRecord(
            bundleID: "com.example.victim", teamID: nil, name: "Victim2",
            url: d.h.apps.appendingPathComponent("Victim2.app"), version: "1", size: 1, lastUsed: nil)
        let uninstall = await state.cleaner.uninstall(app: victim2, leftovers: fakeLeftovers)
        #expect(!uninstall.moved.contains { d.isProtectedDecoy($0.original.path) })

        // Nothing protected changed, in any flow.
        let protectedRoots = DecoyHome.protectedRoots + DecoyHome.linkTargets
        expectUnchanged(before.filter { key, _ in d.isProtectedDecoy(key) }, d.snapshot(protectedRoots), "all flows")
    }

    /// Scanners never list or pre-select a protected decoy (safety rule 2, "checked by the
    /// scanners"), whatever the access state.
    @Test("Scanners never offer a protected decoy", arguments: [true, false])
    func scannersNeverOfferDecoys(fullDiskAccess access: Bool) async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        try d.build()
        let rules = try await RuleCatalog().rules()
        let items = await JunkScanner(
            rules: rules, home: d.fixture.url, now: d.fixture.now, hasFullDiskAccess: access
        ).scan().flatMap(\.items)
        #expect(!items.isEmpty)
        for item in items {
            #expect(!d.isProtectedDecoy(item.url.path), "listed \(item.url.path)")
            let never = DecoyHome.junkOnly.filter { $0 != "Library/Caches/com.google.Chrome" }
            #expect(
                !never.contains { PathTools.isInside(item.url.path, root: d.url($0).path) }, "listed \(item.url.path)")
        }
        let walker = DiskWalker(home: d.fixture.url, hasFullDiskAccess: { access })
        let tree = try await walker.walk(d.fixture.url)
        for index in 0..<UInt32(tree.count) {
            let path = tree.path(index)
            for root in ["Library/Mail", "Library/Keychains", "Pictures/Photos Library.photoslibrary"] {
                // Protected places are one aggregate block: nothing inside them can be picked.
                #expect(!PathTools.isStrictlyInside(path, root: d.url(root).path), "map lists \(path)")
            }
        }
    }

    /// Safety rule 3 on the bundled catalogue.
    @Test("Recent and .review items are never pre-selected; .never never appears")
    func preselectionRules() async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        try d.build()
        let rules = try await RuleCatalog().rules()
        let items = await JunkScanner(rules: rules, home: d.fixture.url, now: d.fixture.now).scan().flatMap(\.items)
        checkPreselection(items, neverIDs: Set(rules.filter { $0.risk == .never }.map(\.id)), now: d.fixture.now)
        let fresh = try #require(items.first { $0.url.lastPathComponent == "com.example.fresh" })
        #expect(!fresh.isSelected)
        let review = try #require(items.first { $0.url.lastPathComponent == "zzreview" })
        #expect(review.risk == .review && !review.isSelected)
        let neverPaths = rules.filter { $0.risk == .never }.flatMap(\.paths).map {
            PathTools.expandTilde($0, home: d.fixture.url.path).lowercased()
        }
        #expect(
            !items.contains { item in neverPaths.contains { PathTools.isInside(item.url.path.lowercased(), root: $0) } }
        )
    }

    /// Safety rule 1: nothing in the app deletes files except `Cleaner.emptyTrash`.
    @Test("Only Empty Trash deletes permanently (source scan)")
    func onlyEmptyTrashDeletes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var hits: [String] = []
        for folder in ["App", "Core", "Features", "DesignSystem"] {
            let base = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(atPath: base.path)?.compactMap { $0 as? String } ?? []
            for file in files where file.hasSuffix(".swift") && !file.hasPrefix("Debug") {
                let text = try String(contentsOf: base.appendingPathComponent(file), encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where ["removeItem(", "unlink(", "rmdir(", "unlinkat(", "removefile(", "Darwin.remove("].contains(
                    where: line.contains)
                {
                    hits.append("\(folder)/\(file):\(number + 1)")
                }
            }
        }
        #expect(hits.count == 1, "\(hits)")
        #expect(hits.first?.hasPrefix("Core/Cleaning/Cleaner.swift") == true, "\(hits)")
    }

    /// Rule 2 for system places: forged requests for `/usr`, `/System`, `/Library/Apple`, `/bin`
    /// and `/sbin` reach no Trash call, whatever the API.
    @Test("System places are refused by every Cleaner API")
    func systemPlaces() async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        let recorder = RecordingTrashMover(trashDirectory: d.h.trash)
        let rules = try await RuleCatalog().rules()
        let cleaner = Cleaner(
            home: d.fixture.url, trashMover: recorder, runningApps: FakeRunningApps(),
            store: CleanupStore(database: d.h.database), rules: { rules }, hasFullDiskAccess: { true })
        let paths = ["/usr/bin/true", "/System/Library", "/Library/Apple", "/bin", "/sbin", "/usr", "/System"]
            .map { URL(fileURLWithPath: $0) }
        let items = paths.flatMap { url in
            ["cache.apps", "logs.user", "dev.hprof"].map { rule in
                ScanItem(
                    id: UUID(), url: url, allocatedSize: 1, modified: .distantPast, category: .userCache, ruleID: rule,
                    risk: .safe, isSelected: true)
            }
        }
        #expect(await cleaner.clean(items).moved.isEmpty)
        for url in paths {
            let report = await cleaner.trashUserChosen(url)
            #expect(report.skipped.map(\.reason) == [.outsideHome], "\(url.path)")
        }
        #expect(await cleaner.trashLargeFiles(paths).moved.isEmpty)
        let removals = paths.map { DuplicateRemoval(url: $0, keeper: paths[0], hash: 0, size: 1) }
        #expect(await cleaner.trashDuplicates(removals).moved.isEmpty)
        let leftovers = paths.map {
            LeftoverMatch(
                appBundleID: "com.example.x", url: $0, reason: .bundleID, confidence: .high, explanation: "",
                folderTitle: "", size: 1, modified: .distantPast, status: .removable)
        }
        #expect(await cleaner.removeOrphans(leftovers).moved.isEmpty)
        let calculator = AppRecord(
            bundleID: "com.apple.calculator", teamID: nil, name: "Calculator",
            url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), version: "1", size: 1, lastUsed: nil)
        #expect(await cleaner.uninstall(app: calculator, leftovers: leftovers).moved.isEmpty)
        #expect(recorder.takeAsked().isEmpty, "the Trash was asked to take a system path")
    }

    /// Rule 2, MobileSync: protected unless the iOS-backup rule is explicitly selected. There is no
    /// such rule in the catalogue yet (PROGRESS → Deviations, Prompt 3), so MobileSync is always
    /// refused; `ProtectedList(allowMobileSync:)` is the switch that rule will flip.
    @Test("iPhone backups (MobileSync) are always refused: no iOS-backup rule exists")
    func mobileSync() async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        try d.build()
        let rules = try await RuleCatalog().rules()
        #expect(!rules.contains { $0.paths.contains { $0.contains("MobileSync") } }, "an iOS-backup rule exists now")
        let backup = d.url("Library/Application Support/MobileSync/Backup/abc123")
        #expect(ProtectedList(home: d.fixture.url).isProtectedPath(backup.path))
        #expect(!ProtectedList(home: d.fixture.url, allowMobileSync: true).isProtectedPath(backup.path))
        // Even a rule aimed straight at the backups can't clean them while the switch is off.
        let backupRule = CleanerTests.rule(
            "ios.backup", .installers, paths: ["~/Library/Application Support/MobileSync/Backup"], globs: ["*"],
            risk: .review)
        let found = await JunkScanner(rules: [backupRule], home: d.fixture.url, now: d.fixture.now).scan()
        #expect(found.flatMap(\.items).isEmpty)
        let item = ScanItem(
            id: UUID(), url: backup, allocatedSize: 1, modified: .distantPast, category: .installers,
            ruleID: "ios.backup", risk: .review, isSelected: true)
        let cleaner = Cleaner(
            home: d.fixture.url, trashMover: TempTrashMover(trashDirectory: d.h.trash), runningApps: FakeRunningApps(),
            store: CleanupStore(database: d.h.database), rules: { [backupRule] }, hasFullDiskAccess: { true })
        let report = await cleaner.clean([item])
        #expect(report.moved.isEmpty)
        #expect(report.skipped.map(\.reason) == [.protected])
        #expect(d.h.exists("Library/Application Support/MobileSync/Backup/abc123/Manifest.db"))
    }

    /// Rule 1: Empty Trash deletes only after the confirmation, and only what it listed.
    @Test("Empty Trash runs only after a confirmation and deletes exactly what it showed")
    @MainActor
    func emptyTrashNeedsConfirmation() async throws {
        let h = try CleanerTests.Harness()
        defer { h.remove() }
        let fm = FileManager.default
        try h.fixture.file("", bytes: 10_000, absolute: h.trash.appendingPathComponent("old.bin"))
        try h.fixture.file("", bytes: 20_000, absolute: h.trash.appendingPathComponent("folder/inner.bin"))
        let model = JunkModel(catalog: RuleCatalog(), cleaner: h.cleaner([]), store: h.store, home: h.fixture.url)

        await model.confirmEmptyTrash()  // no confirmation shown: nothing happens
        #expect(model.emptiedBytes == nil)
        #expect(fm.fileExists(atPath: h.trash.appendingPathComponent("old.bin").path))

        await model.requestEmptyTrash()
        let shown = try #require(model.trashToEmpty)
        #expect(shown.names == ["folder", "old.bin"])
        #expect(shown.bytes > 0)
        // Something lands in the Trash after the dialog opened: it must stay.
        try h.fixture.file("", bytes: 5_000, absolute: h.trash.appendingPathComponent("later.bin"))
        await model.confirmEmptyTrash()
        #expect(model.emptiedBytes == shown.bytes)
        #expect(model.trashToEmpty == nil)
        #expect(try fm.contentsOfDirectory(atPath: h.trash.path) == ["later.bin"])

        await model.confirmEmptyTrash()  // a second confirm without a new dialog does nothing
        #expect(fm.fileExists(atPath: h.trash.appendingPathComponent("later.bin").path))
    }

    /// `.never` places (unsaved documents, offline music, downloaded models) can't be picked by
    /// hand on the Space map or in Clutter either.
    @Test("Space map and Clutter refuse .never places, with a reason")
    func neverPlacesByHand() async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        try d.build()
        try d.fixture.file(".lmstudio/models/llama.gguf", bytes: 9_000, ageDays: 90)
        try d.fixture.file(".ollama/logs/server.log", bytes: 9_000, ageDays: 90)
        let rules = try await RuleCatalog().rules()
        let cleaner = Cleaner(
            home: d.fixture.url, trashMover: TempTrashMover(trashDirectory: d.h.trash), runningApps: FakeRunningApps(),
            store: CleanupStore(database: d.h.database), rules: { rules }, hasFullDiskAccess: { true }, ownPaths: [])
        for relative in [
            "Library/Autosave Information", "Library/Autosave Information/Unsaved.rtf", ".ollama/models",
            ".ollama/models/blobs/sha256-1", ".ollama", ".lmstudio/models", ".lmstudio/models/llama.gguf",
            "Library/Caches/com.spotify.client", "Library/Caches/CloudKit/records.bin",
        ] {
            let report = await cleaner.trashUserChosen(d.url(relative))
            #expect(report.skipped.map(\.reason) == [.neverTouched], "\(relative): \(report.skipped.map(\.reason))")
        }
        let large = await cleaner.trashLargeFiles([d.url(".lmstudio/models/llama.gguf")])
        #expect(large.skipped.map(\.reason) == [.neverTouched])
        // Next to a `.never` place, but not in it: still the user's choice.
        let log = await cleaner.trashUserChosen(d.url(".ollama/logs/server.log"))
        #expect(log.moved.count == 1)
        // A catalogue that didn't load refuses everything rather than guessing.
        let blind = Cleaner(
            home: d.fixture.url, trashMover: TempTrashMover(trashDirectory: d.h.trash), runningApps: FakeRunningApps(),
            store: CleanupStore(database: d.h.database), rules: { throw CocoaError(.fileReadCorruptFile) },
            hasFullDiskAccess: { true }, ownPaths: [])
        #expect(await blind.trashUserChosen(d.url("Movies/old.mov")).moved.isEmpty)
    }

    /// A stray database file directly in Documents locks that folder's files, with a clear reason.
    @Test("A database file in a folder gives its own reason, not just \"protected\"")
    func databaseFolderReason() async throws {
        let d = try DecoyHome()
        defer { d.remove() }
        try d.build()
        try d.fixture.file("Documents/stray.db", bytes: 4_000)
        try d.fixture.file("Documents/letter.txt", bytes: 4_000)
        let cleaner = Cleaner(
            home: d.fixture.url, trashMover: TempTrashMover(trashDirectory: d.h.trash), runningApps: FakeRunningApps(),
            store: CleanupStore(database: d.h.database), rules: { [] }, hasFullDiskAccess: { true }, ownPaths: [])
        for relative in ["Documents/letter.txt", "Documents/Taxes/return.pdf", "Documents/Project/photo.jpg"] {
            let report = await cleaner.trashUserChosen(d.url(relative))
            #expect(report.skipped.map(\.reason) == [.appDatabaseFolder], "\(relative)")
        }
        #expect(SkipReason.appDatabaseFolder.explanation.contains("database"))
        #expect(d.h.exists("Documents/letter.txt"))
    }

    // MARK: - Helpers

    func checkPreselection(_ items: [ScanItem], neverIDs: Set<String>, now: Date) {
        let weekAgo = now.addingTimeInterval(-JunkScanner.preselectMinimumAge)
        for item in items {
            #expect(!neverIDs.contains(item.ruleID), "a .never rule's item appeared: \(item.url.path)")
            if item.isSelected {
                #expect(item.risk == .safe, "\(item.url.lastPathComponent) is \(item.risk) but pre-selected")
                #expect(item.modified <= weekAgo, "\(item.url.lastPathComponent) changed this week but is pre-selected")
                #expect(!item.detectionOnly)
            }
        }
    }

    /// Safety rule 1: every moved item is in the (temp) Trash and has a log row pointing at it.
    func checkLogged(_ trashed: [URL], store: CleanupStore, trash: URL) async throws {
        #expect(!trashed.isEmpty)
        let logged = Set(try await store.logs().map(\.trashPath))
        for url in trashed {
            #expect(PathTools.isInside(url.path, root: trash.path))
            #expect(Cleaner.linkState(url.path) != .missing)
            #expect(logged.contains(url.path))
        }
    }

    func expectUnchanged(
        _ before: [String: String], _ after: [String: String], _ flow: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        #expect(changed.isEmpty, "\(flow) changed decoys: \(changed.prefix(10))", sourceLocation: sourceLocation)
    }
}
