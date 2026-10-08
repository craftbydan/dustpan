#if DEBUG
    import AppKit
    import Foundation
    import os

    /// DEBUG only. With `-junkDemo YES` the app works on a made-up home folder, Trash and history
    /// in a temp folder, so the Junk and History screens can be shown (and cleaned) without
    /// touching the real ones. The temp folder is removed when the app quits.
    @MainActor
    enum DebugDemo {
        struct Demo {
            let base: URL
            let home: URL
            let database: AppDatabase
            let trashMover: any TrashMover
            /// Pretends Chrome is open; "quitting" it only flips a flag (never a real app).
            let runningApps: DemoRunningApps
            /// A made-up app folder (Apps screen) and a made-up `/Library`.
            let appRoots: [URL]
            let systemLibrary: URL
        }

        private static var observer: NSObjectProtocol?
        /// The running demo's pretend app list (snapshot flows open and close "Chrome").
        private(set) static var current: DemoRunningApps?
        /// The demo's temp folder (DEBUG snapshot flows may only change things inside it).
        private(set) static var base: URL?
        /// The demo "installed for all users" app and its folder, made read-only (555) so the
        /// user can't move it; unlocked again before the demo folder is removed.
        private(set) static var lockedPaths: [URL] = []

        static func makeIfRequested() -> Demo? {
            guard UserDefaults.standard.bool(forKey: "junkDemo") else { return nil }
            do {
                return try make()
            } catch {
                Logger(subsystem: "app.dustpan", category: "debug")
                    .error("Demo home failed: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }

        private static func make() throws -> Demo {
            let fm = FileManager.default
            let raw = fm.temporaryDirectory.appendingPathComponent(
                "DustpanDemo-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: raw, withIntermediateDirectories: true)
            let base = URL(fileURLWithPath: PathTools.canonical(raw.path) ?? raw.path, isDirectory: true)
            let home = base.appendingPathComponent("home", isDirectory: true)
            let trash = home.appendingPathComponent(".Trash", isDirectory: true)
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)

            let mb = 1_048_576
            let files: [(String, Int, Double)] = [
                ("Library/Caches/com.tinyspeck.slackmacgap/Cache/data_1", 38 * mb, 21),
                ("Library/Caches/com.tinyspeck.slackmacgap/Cache/data_2", 9 * mb, 21),
                ("Library/Caches/com.figma.Desktop/fonts/cache.bin", 22 * mb, 40),
                ("Library/Caches/com.google.Chrome/Default/Cache/data_0", 31 * mb, 12),
                ("Library/Caches/com.spotify.client/Browser/cache.bin", 6 * mb, 30),
                ("Library/Caches/com.apple.Safari/WebKitCache/blob", 14 * mb, 25),
                ("Library/Caches/com.example.notes/Thumbnails/t1", 3 * mb, 2),
                ("Library/Caches/com.microsoft.VSCode.ShipIt/update.zip", 41 * mb, 26),
                ("Library/Caches/Homebrew/downloads/node--22.9.0.bottle.tar.gz", 27 * mb, 33),
                ("Library/Logs/DiagnosticReports/Finder-2026-09-01.ips", 1 * mb, 36),
                ("Library/Logs/com.example.sync/sync.log", 4 * mb, 18),
                ("Library/Saved Application State/com.apple.Preview.savedState/windows.plist", mb / 2, 50),
                ("Library/Developer/Xcode/DerivedData/Dustpan-bqkzwx/Build/Intermediates/a.o", 64 * mb, 15),
                ("Library/Developer/Xcode/DerivedData/Recipes-akdjeh/Build/Intermediates/b.o", 18 * mb, 60),
                (".npm/_cacache/content-v2/sha512/ab/cd", 12 * mb, 22),
                (".cache/uv/wheels-v1/torch.whl", 29 * mb, 45),
                ("Downloads/Figma-Installer.dmg", 17 * mb, 30),
                (".Trash/old-notes.zip", 5 * mb, 9),
            ]
            for (relative, bytes, ageDays) in files {
                try write(home.appendingPathComponent(relative), bytes: bytes, ageDays: ageDays)
            }

            let defaults = UserDefaults.standard
            // `-snapshotLayoutAudit YES` shows every screen, so it gets every extra.
            let audit = defaults.bool(forKey: "snapshotLayoutAudit")
            if defaults.bool(forKey: "snapshotSpaceMap") || audit { try addSpaceMapContent(home: home) }
            let sweepExtras = defaults.bool(forKey: "snapshotSweep") || audit
            if defaults.bool(forKey: "snapshotClutter") || sweepExtras { try DemoClutter.add(home: home) }
            if sweepExtras { try DemoClutter.addSweepExtras(home: home) }
            let (appRoots, systemLibrary) = try makeApps(base: base, home: home)
            if defaults.bool(forKey: "snapshotTrashFinder") { try addFinderOnlyTrash(trash) }

            // Earlier cleanups, so History has something to show.
            let database = try AppDatabase.inMemory()
            let now = Date()
            let inTrash = trash.appendingPathComponent("com.example.mail.preview")
            try write(inTrash.appendingPathComponent("p.bin"), bytes: 8 * mb, ageDays: 3)
            try database.dbQueue.write { db in
                var rows = [
                    CleanupLog(
                        id: nil, date: now.addingTimeInterval(-86_400 - 3_600),
                        originalPath: home.appendingPathComponent("Library/Caches/com.example.mail.preview").path,
                        trashPath: inTrash.path, bytes: Int64(8 * mb), ruleID: "cache.apps", restoredAt: nil),
                    CleanupLog(
                        id: nil, date: now.addingTimeInterval(-86_400 - 3_000),
                        originalPath: home.appendingPathComponent("Library/Logs/com.example.backup").path,
                        trashPath: trash.appendingPathComponent("com.example.backup").path, bytes: Int64(3 * mb),
                        ruleID: "logs.user", restoredAt: now.addingTimeInterval(-86_400)),
                    CleanupLog(
                        id: nil, date: now.addingTimeInterval(-4 * 86_400),
                        originalPath: home.appendingPathComponent("Library/Caches/com.example.music").path,
                        trashPath: trash.appendingPathComponent("com.example.music").path, bytes: Int64(212 * mb),
                        ruleID: "cache.apps", restoredAt: nil),
                ]
                for index in rows.indices { try rows[index].insert(db) }
            }

            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in
                MainActor.assumeIsolated {
                    DebugDemo.unlockAdminApp()
                    DebugDemo.unlockTrash()
                }
                try? FileManager.default.removeItem(at: base)
            }
            self.base = base
            let running = DemoRunningApps()
            current = running
            return Demo(
                base: base, home: home, database: database, trashMover: FolderTrashMover(trashDirectory: trash),
                runningApps: running, appRoots: appRoots, systemLibrary: systemLibrary)
        }

        /// Made-up apps (fictional names, `Info.plist` only, no code) with leftovers, plus leftovers
        /// of apps that are "gone", for the Apps screen.
        private static func makeApps(base: URL, home: URL) throws -> ([URL], URL) {
            let applications = base.appendingPathComponent("Applications", isDirectory: true)
            let systemLibrary = base.appendingPathComponent("SystemLibrary", isDirectory: true)
            let mb = 1_048_576
            for app in DemoApps.all {
                let folder =
                    app.folder.map { applications.appendingPathComponent($0, isDirectory: true) } ?? applications
                let bundle = folder.appendingPathComponent("\(app.name).app", isDirectory: true)
                let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "CFBundleIdentifier": app.bundleID, "CFBundleName": app.name,
                    "CFBundleShortVersionString": app.version, "CFBundlePackageType": "APPL",
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: contents.appendingPathComponent("Info.plist"))
                try write(
                    contents.appendingPathComponent("Resources/payload.bin"), bytes: app.megabytes * mb, ageDays: 90)
            }
            let leftovers: [(String, Int, Double)] = [
                ("Library/Caches/com.inkwell.Inkwell/Cache/blob", 46 * mb, 12),
                ("Library/Preferences/com.inkwell.Inkwell.plist", 1, 3),
                ("Library/Application Support/Inkwell/brushes/set.bin", 18 * mb, 40),
                ("Library/Saved Application State/com.inkwell.Inkwell.savedState/windows.plist", mb / 4, 20),
                ("Library/Containers/com.inkwell.Inkwell.ShareExtension/Data/tmp.bin", 2 * mb, 30),
                ("Library/Logs/Inkwell Sync/sync.log", 3 * mb, 25),
                ("Library/Application Support/com.inkwell.Inkwell/library.sqlite", 9 * mb, 2),
                ("Library/Caches/com.example.Notes/thumbs.bin", 7 * mb, 15),
                ("Library/Preferences/com.example.Notes.plist", 1, 15),
                // Leftovers of apps that are gone.
                ("Library/Caches/com.oldvendor.Sketcher/render/cache.bin", 128 * mb, 240),
                ("Library/Preferences/com.oldvendor.Sketcher.plist", 1, 240),
                ("Library/Application Support/net.gonesoft.Timekeeper/state.json", 3 * mb, 400),
                ("Library/HTTPStorages/io.vanished.Reader/httpstorages.bin", mb, 120),
                ("Library/Logs/org.formerapp.Syncer/sync.log", 6 * mb, 75),
                ("Library/Saved Application State/dev.retired.Tracer.savedState/data.data", mb / 2, 300),
                ("Library/Caches/com.freshvendor.Recent/new.bin", 4 * mb, 5),
                // "Huddle", installed for all users (read-only bundle): 14 leftovers.
                ("Library/Caches/com.huddle.Huddle/Cache/data_1", 61 * mb, 9),
                ("Library/Caches/com.huddle.Huddle.ShipIt/update.zip", 38 * mb, 20),
                ("Library/Preferences/com.huddle.Huddle.plist", 1, 9),
                ("Library/Preferences/com.huddle.Huddle.helper.plist", 1, 9),
                ("Library/Application Support/Huddle/IndexedDB/blob.bin", 22 * mb, 9),
                ("Library/Containers/com.huddle.Huddle.launcher/Data/tmp.bin", 1 * mb, 30),
                ("Library/Saved Application State/com.huddle.Huddle.savedState/windows.plist", mb / 4, 9),
                ("Library/Logs/Huddle/main.log", 5 * mb, 9),
                ("Library/HTTPStorages/com.huddle.Huddle/store.bin", mb / 2, 9),
                ("Library/WebKit/com.huddle.Huddle/WebsiteData/blob", 3 * mb, 9),
                ("Library/Group Containers/HUDDLE1234.com.huddle.shared/settings.json", mb / 8, 9),
                ("Library/Cookies/com.huddle.Huddle.binarycookies", mb / 16, 9),
                ("Library/Caches/com.huddle.Huddle.Notifications/n.bin", 2 * mb, 9),
                ("Library/Logs/Huddle Meetings/meet.log", 1 * mb, 9),
            ]
            for (relative, bytes, ageDays) in leftovers {
                try write(home.appendingPathComponent(relative), bytes: bytes, ageDays: ageDays)
            }
            try write(
                systemLibrary.appendingPathComponent("LaunchDaemons/com.inkwell.Inkwell.updater.plist"), bytes: 1,
                ageDays: 60)
            // Lock "Huddle" and its folder like a bundle installed for all users.
            let shared = applications.appendingPathComponent("Shared Apps", isDirectory: true)
            lockedPaths = [shared.appendingPathComponent("Huddle.app"), shared]
            for url in lockedPaths {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
            }
            return ([applications], systemLibrary)
        }

        /// Demo Trash entries only Finder could delete (`-snapshotTrashFinder YES`): an app "put
        /// there with the password" (folders chmod 555, as a stand-in for root-owned) and a locked
        /// file (`uchg`). Only inside the demo's temp Trash; undone before the demo folder goes.
        private(set) static var trashReadOnly: [URL] = []
        private(set) static var trashLocked: [URL] = []

        private static func addFinderOnlyTrash(_ trash: URL) throws {
            let mb = 1_048_576
            let teams = trash.appendingPathComponent("Microsoft Teams.app", isDirectory: true)
            try write(teams.appendingPathComponent("Contents/MacOS/Teams"), bytes: 96 * mb, ageDays: 0)
            try write(
                teams.appendingPathComponent("Contents/Frameworks/Core.framework/Core"), bytes: 54 * mb, ageDays: 0)
            let locked = trash.appendingPathComponent("Tax return 2024.pdf")
            try write(locked, bytes: 2 * mb, ageDays: 40)
            trashReadOnly = [
                teams.appendingPathComponent("Contents/MacOS"), teams.appendingPathComponent("Contents/Frameworks"),
                teams.appendingPathComponent("Contents"), teams,
            ]
            for url in trashReadOnly {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
            }
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
            trashLocked = [locked]
        }

        static func unlockTrash() {
            for url in trashLocked {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
            }
            for url in trashReadOnly.reversed() {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }

        static func unlockAdminApp() {
            for url in lockedPaths {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }

        /// DEBUG snapshots: "drag Huddle to the Trash in Finder" — deletes the demo bundle (only
        /// inside the demo's temp folder).
        static func simulateFinderRemovalOfAdminApp() {
            guard let base, let bundle = lockedPaths.first,
                PathTools.isStrictlyInside(bundle.path, root: base.path)
            else { return }
            unlockAdminApp()
            try? FileManager.default.removeItem(at: bundle)
        }

        /// Extra made-up folders for the Space map screenshots (`-snapshotSpaceMap YES`).
        private static func addSpaceMapContent(home: URL) throws {
            let kb = 1_024
            let mb = 1_048_576
            var files: [(String, Int)] = [
                ("Projects/film-edit/renders/final-cut-v3.mov", 96 * mb),
                ("Projects/film-edit/renders/rough-cut.mov", 54 * mb),
                ("Projects/film-edit/footage/day1.mov", 71 * mb),
                ("Projects/dustpan-site/build/site.zip", 12 * mb),
                ("Projects/dustpan-site/design/hero.psd", 28 * mb),
                ("Projects/dustpan-site/local-db/store.sqlite", 9 * mb),
                ("Movies/Holiday 2025/beach.mov", 62 * mb),
                ("Movies/Holiday 2025/harbour.mov", 33 * mb),
                ("Music/Demos/song-sketch.aiff", 24 * mb),
                ("Documents/Taxes/2025-return.pdf", 3 * mb),
                ("Documents/Book draft/chapter-1.docx", 2 * mb),
                ("Documents/Book draft/chapter-2.docx", 2 * mb),
                ("Documents/Scans/passport-scan.pdf", 6 * mb),
                ("Pictures/Scans/old-photo-1.heic", 9 * mb),
                ("Pictures/Scans/old-photo-2.heic", 7 * mb),
                ("Desktop/Screenshot 2026-09-30.png", 4 * mb),
                ("Downloads/Archive-2024.zip", 44 * mb),
            ]
            for i in 0..<60 {
                let package = ["react", "vite", "esbuild", "typescript", "lodash", "postcss"][i % 6]
                files.append(("Projects/dustpan-site/node_modules/\(package)/dist/chunk-\(i).js", (40 + i * 7) * kb))
            }
            for i in 0..<24 {
                files.append(("Projects/dustpan-site/src/components/Block\(i).tsx", (8 + i) * kb))
                files.append(("Projects/dustpan-site/public/images/shot-\(i).png", (300 + i * 40) * kb))
            }
            for (relative, bytes) in files {
                try write(home.appendingPathComponent(relative), bytes: bytes, ageDays: 20)
            }
        }

        private static func write(_ url: URL, bytes: Int, ageDays: Double) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
        }
    }

    /// DEBUG demo: "trashes" by moving into a folder, like Finder does (adds a number on clashes).
    struct FolderTrashMover: TrashMover {
        let trashDirectory: URL

        func trash(_ url: URL) throws -> URL {
            let fm = FileManager.default
            var target = trashDirectory.appendingPathComponent(url.lastPathComponent)
            var counter = 2
            while fm.fileExists(atPath: target.path) {
                target = trashDirectory.appendingPathComponent("\(url.lastPathComponent) \(counter)")
                counter += 1
            }
            try fm.moveItem(at: url, to: target)
            return target
        }
    }

    /// DEBUG demo apps (fictional).
    enum DemoApps {
        struct App {
            let name: String
            let bundleID: String
            let version: String
            let megabytes: Int
            let lastUsedDaysAgo: Double?
            let teamID: String?
            /// A sub-folder of the demo app folder, e.g. "Shared Apps".
            var folder: String?
        }

        static let all: [App] = [
            App(
                name: "Huddle", bundleID: "com.huddle.Huddle", version: "25.31", megabytes: 1_120,
                lastUsedDaysAgo: 2, teamID: "HUDDLE1234", folder: "Shared Apps"),
            App(
                name: "Inkwell", bundleID: "com.inkwell.Inkwell", version: "4.2.1", megabytes: 412,
                lastUsedDaysAgo: 230,
                teamID: "INKW3LL123"),
            App(
                name: "Tidepool", bundleID: "io.tidepool.Tidepool", version: "2.0", megabytes: 188, lastUsedDaysAgo: 1,
                teamID: "TIDEP00L45"),
            App(
                name: "Orbit Notes", bundleID: "com.example.Notes", version: "11.3", megabytes: 96, lastUsedDaysAgo: 3,
                teamID: "EXAMPLE123"),
            App(
                name: "Quarry", bundleID: "dev.quarry.Quarry", version: "0.9.4", megabytes: 1_310,
                lastUsedDaysAgo: 400, teamID: "QUARRY0001"),
            App(
                name: "Lumen", bundleID: "app.lumen.Lumen", version: "1.7", megabytes: 54, lastUsedDaysAgo: 12,
                teamID: nil),
            App(
                name: "Paperboat", bundleID: "com.paperboat.mac", version: "3.1.0", megabytes: 233,
                lastUsedDaysAgo: nil, teamID: "PAPERB0AT9"),
        ]

        static func app(at url: URL) -> App? {
            all.first { "\($0.name).app" == url.lastPathComponent }
        }
    }

    struct DemoSigning: CodeSigningReading {
        func signing(of appURL: URL) -> SigningInfo {
            SigningInfo(teamID: DemoApps.app(at: appURL)?.teamID, isApple: false)
        }
    }

    struct DemoLastUsed: LastUsedReading {
        func lastUsed(_ appURL: URL) -> Date? {
            DemoApps.app(at: appURL)?.lastUsedDaysAgo.map { Date().addingTimeInterval(-$0 * 86_400) }
        }
    }

    /// DEBUG demo: pretends Google Chrome is open, so its cache shows up as waiting on it.
    /// "Quitting" only flips the pretend flag: the demo never asks a real app to quit.
    final class DemoRunningApps: RunningAppsChecking, AppQuitting, Sendable {
        static let chromeID = "com.google.Chrome"
        private let open = OSAllocatedUnfairLock(initialState: [chromeID: "Google Chrome"])

        func runningAppName(bundleID: String) -> String? { open.withLock { $0[bundleID] } }

        /// Snapshot flows: pretend Chrome opened or quit (call `RunningApps.refresh()` after).
        func setChromeOpen(_ isOpen: Bool) {
            open.withLock { $0[Self.chromeID] = isOpen ? "Google Chrome" : nil }
        }

        @MainActor func quit(bundleID: String) async -> Bool {
            open.withLock { _ = $0.removeValue(forKey: bundleID) }
            return true
        }
    }
#endif
