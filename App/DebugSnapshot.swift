#if DEBUG
    import AppKit
    import SwiftUI

    /// DEBUG only. With `-snapshotDir <path>`, the app walks through every sidebar section
    /// (driving the same selection the sidebar rows set), writes a PNG of its own window for
    /// each, then quits. Needs no screen-recording permission because it draws its own views.
    /// With `-designPreview YES` as well, it writes the full design sheet instead.
    /// With `-onboardingStep 1|2|3` it writes that onboarding step (`onboarding-step<n>-…`);
    /// with `-snapshotBanner YES` it writes the shell with the Full Disk Access banner
    /// (`banner-…`; add `-forceNoAccess YES` if this Mac has granted access).
    @MainActor
    enum DebugSnapshot {
        static var directory: URL? {
            UserDefaults.standard.string(forKey: "snapshotDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        }

        static var onboardingStep: OnboardingModel.Step? {
            OnboardingModel.Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep"))
        }

        static var bannerOnly: Bool { UserDefaults.standard.bool(forKey: "snapshotBanner") }

        /// `-snapshotJunkFlow YES` (use with `-junkDemo YES`): scan → list → confirm → clean →
        /// result → list after the clean → History, one PNG each (`junk-list-…`, `junk-confirm-…`,
        /// `junk-result-…`, `junk-after-clean-…`, `history-…`).
        static var junkFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotJunkFlow") }

        static func walkJunkFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) { writeKeyWindow(to: directory.appendingPathComponent("\(name)-\(suffix).png")) }
            try? await Task.sleep(for: .seconds(1.2))
            let junk = appState.junk
            appState.section = .junk
            try? await Task.sleep(for: .milliseconds(500))
            snap("junk-start")
            await junk.scan(hasFullDiskAccess: appState.onboarding.hasFullDiskAccess)
            if junk.result(for: .userCache) != nil { junk.focusedCategory = .userCache }
            try? await Task.sleep(for: .milliseconds(800))
            snap("junk-list")
            junk.requestClean()
            try? await Task.sleep(for: .milliseconds(600))
            snap("junk-confirm")
            await junk.confirmClean()
            try? await Task.sleep(for: .milliseconds(1_500))
            snap("junk-result")
            // Back on the list: the Trash tile has grown and the bottom bar says how to get the space.
            await appState.spaceRefresh?.value
            junk.dismissResult()
            if junk.result(for: .trash) != nil { junk.focusedCategory = .trash }
            try? await Task.sleep(for: .milliseconds(800))
            snap("junk-after-clean")
            appState.section = .history
            try? await Task.sleep(for: .milliseconds(1_000))
            snap("history")
            NSApp.terminate(nil)
        }

        /// `-snapshotApps YES` (use with `-junkDemo YES`): Apps screen — installed list, an app's
        /// detail with leftovers, the uninstall confirmation, the Leftovers tab and the result
        /// (`apps-installed-…`, `apps-detail-…`, `apps-confirm-…`, `apps-leftovers-…`, `apps-result-…`).
        static var appsFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotApps") }

        static func walkAppsFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) { writeKeyWindow(to: directory.appendingPathComponent("\(name)-\(suffix).png")) }
            let apps = appState.apps
            let access = appState.permissions.hasFullDiskAccess()
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .apps
            try? await Task.sleep(for: .milliseconds(500))
            snap("apps-start")
            await apps.load(hasFullDiskAccess: access)
            try? await Task.sleep(for: .milliseconds(800))
            snap("apps-installed")
            await apps.debugSelect(bundleID: "com.inkwell.Inkwell")
            try? await Task.sleep(for: .milliseconds(800))
            snap("apps-detail")
            apps.requestUninstall()
            try? await Task.sleep(for: .milliseconds(600))
            snap("apps-confirm")
            apps.isConfirmingUninstall = false
            apps.tab = .leftovers
            await apps.loadOrphans(hasFullDiskAccess: access)
            apps.debugSelectFirstOrphan()
            try? await Task.sleep(for: .milliseconds(800))
            snap("apps-leftovers")
            apps.tab = .installed
            await apps.confirmUninstall()
            try? await Task.sleep(for: .milliseconds(1_500))
            snap("apps-result")
            NSApp.terminate(nil)
        }

        /// `-snapshotSpaceMap YES` (use with `-junkDemo YES`, which then adds made-up project, movie
        /// and document folders; add `-snapshotWindowWidth 900|1080`): the start screen, the
        /// first-run hint with the empty selection bar, a hovered block's trash button, a selected
        /// block, a multi-selection, the confirmation with a refused item (a folder holding an app
        /// database) and the result (`spacemap-start`, `-hint-empty`, `-hover-trash`, `-selected`,
        /// `-multi`, `-confirm-refused`, `-moved`, each `-<width>-<appearance>.png`).
        static var spaceMapFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotSpaceMap") }

        static func walkSpaceMapFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) async {
                await applyWindowSize()
                writeKeyWindow(to: directory.appendingPathComponent("\(name)\(sizeSuffix)-\(suffix).png"))
            }
            func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
            let map = appState.spaceMap
            await pause(1_200)
            appState.section = .spaceMap
            await pause(500)
            await snap("spacemap-start")
            map.start(.home)
            await map.waitForWalk()
            map.debugResetHint()
            await pause(900)
            // First run: the hint line and the empty selection bar with a disabled Move to Trash.
            await snap("spacemap-hint-empty")
            // Pointer on a block: hover card and the corner trash button.
            map.debugHover = map.entries.first(where: { $0.name == "Projects" })?.node
            await pause(600)
            await snap("spacemap-hover-trash")
            map.debugHover = nil
            map.debugDrill(["Projects", "dustpan-site"])
            await pause(900)
            map.debugSelect(["build"])
            await pause(500)
            await snap("spacemap-selected")
            map.debugSelect(["node_modules", "local-db"])
            await pause(500)
            await snap("spacemap-multi")
            await map.requestTrashSelection()
            await pause(700)
            await snap("spacemap-confirm-refused")
            await map.confirmTrash()
            await pause(1_200)
            await snap("spacemap-moved")
            NSApp.terminate(nil)
        }

        /// `-snapshotClutter YES` (use with `-junkDemo YES -forceAccess YES`, which then adds made-up
        /// big files, photos and documents): Large & old empty state, list (two ticked, one
        /// focused) and confirmation; Duplicates cards, after "Select duplicates, keep one", the
        /// confirmation and the result (`clutter-start-…`, `largeold-list-…`, `largeold-confirm-…`,
        /// `duplicates-cards-…`, `duplicates-selected-…`, `duplicates-confirm-…`, `duplicates-moved-…`).
        static var clutterFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotClutter") }

        static func walkClutterFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) { writeKeyWindow(to: directory.appendingPathComponent("\(name)-\(suffix).png")) }
            let clutter = appState.clutter
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .clutter
            try? await Task.sleep(for: .milliseconds(500))
            snap("clutter-start")
            let largeOld = clutter.largeOld
            await largeOld.scan()
            for file in largeOld.visibleFiles.prefix(3).dropFirst() { largeOld.setSelected(file, true) }
            largeOld.focusedID = largeOld.visibleFiles.first?.id
            try? await Task.sleep(for: .milliseconds(800))
            snap("largeold-list")
            largeOld.requestMove()
            try? await Task.sleep(for: .milliseconds(600))
            snap("largeold-confirm")
            largeOld.isConfirming = false
            clutter.tab = .duplicates
            let duplicates = clutter.duplicates
            await duplicates.scan()
            // Thumbnails arrive asynchronously.
            try? await Task.sleep(for: .milliseconds(2_500))
            snap("duplicates-cards")
            duplicates.selectDuplicatesKeepOne()
            try? await Task.sleep(for: .milliseconds(600))
            snap("duplicates-selected")
            duplicates.requestMove()
            try? await Task.sleep(for: .milliseconds(600))
            snap("duplicates-confirm")
            await duplicates.confirmMove()
            try? await Task.sleep(for: .milliseconds(1_500))
            snap("duplicates-moved")
            NSApp.terminate(nil)
        }

        /// `-snapshotSweep YES` (use with `-junkDemo YES`, plus `-forceAccess YES` for the Downloads
        /// tile): Sweep idle, scanning (a made-up moment, so it doesn't depend on timing), results,
        /// the "Clean recommended" confirmation, the celebration, and Large & old opened from its
        /// tile (`sweep-idle-…`, `sweep-scanning-…`, `sweep-results-…`, `sweep-confirm-…`,
        /// `sweep-celebration-…`, `sweep-review-largeold-…`; `-noaccess` is added without access).
        static var sweepFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotSweep") }

        static func walkSweepFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            let access = appState.permissions.hasFullDiskAccess() ? "" : "-noaccess"
            func snap(_ name: String) {
                writeKeyWindow(to: directory.appendingPathComponent("\(name)\(access)-\(suffix).png"))
            }
            let sweep = appState.sweep
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .sweep
            try? await Task.sleep(for: .milliseconds(700))
            snap("sweep-idle")
            sweep.debugShow(
                phase: .scanning,
                states: [
                    .junk: .finished, .orphans: .finished, .unusedApps: .running(nil), .duplicates: .running(0.42),
                    .largeOld: .waiting,
                ])
            try? await Task.sleep(for: .milliseconds(700))
            snap("sweep-scanning")
            sweep.debugShow(phase: .idle, states: [:])
            await sweep.sweep()
            try? await Task.sleep(for: .milliseconds(900))
            snap("sweep-results")
            sweep.requestClean()
            try? await Task.sleep(for: .milliseconds(600))
            snap("sweep-confirm")
            await sweep.confirmClean()
            try? await Task.sleep(for: .milliseconds(1_500))
            snap("sweep-celebration")
            appState.review(.largeOld)
            try? await Task.sleep(for: .milliseconds(900))
            snap("sweep-review-largeold")
            NSApp.terminate(nil)
        }

        /// `-snapshotOpenApps YES` (use with `-junkDemo YES -forceAccess YES`; the demo pretends Google
        /// Chrome is open, and "quitting" it only flips that pretend flag): the Junk list filtered to
        /// Safe with Chrome's row blocked, select-all skipping it, the "Quit Chrome?" prompt, the
        /// confirmation listing a blocked item, the "unticked" banner, the calm "Nothing moved this
        /// time" result, and the Sweep's left-out line (`junk-filter-safe-…`, `junk-select-all-…`,
        /// `junk-quit-prompt-…`, `junk-confirm-blocked-…`, `junk-unticked-…`, `junk-nothing-moved-…`,
        /// `sweep-left-out-…`).
        static var openAppsFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotOpenApps") }

        static func walkOpenAppsFlow(appState: AppState) async {
            guard let directory, let demo = DebugDemo.current else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) async {
                await applyWindowSize()
                writeKeyWindow(to: directory.appendingPathComponent("\(name)\(sizeSuffix)-\(suffix).png"))
            }
            func pause(_ ms: Int = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }
            let junk = appState.junk
            let running = appState.runningApps
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .junk
            await junk.scan(hasFullDiskAccess: appState.permissions.hasFullDiskAccess())
            junk.focusedCategory = .userCache
            junk.riskFilter = .safe
            await pause(900)
            await snap("junk-filter-safe")
            junk.setAllVisibleSelected(true)
            await pause()
            await snap("junk-select-all")
            guard let chrome = junk.allItems.first(where: { junk.blocker(for: $0) != nil }),
                let app = junk.blocker(for: chrome)
            else { return NSApp.terminate(nil) }
            junk.requestQuit(app)
            await pause()
            await snap("junk-quit-prompt")
            junk.quitPrompt = nil

            // Ticked while Chrome was closed; Chrome opens before the confirmation.
            demo.setChromeOpen(false)
            running.refresh()
            junk.setSelected(chrome, true)
            demo.setChromeOpen(true)
            junk.requestClean()
            await pause()
            await snap("junk-confirm-blocked")
            junk.cancelClean()
            await pause()
            await snap("junk-unticked")
            junk.dismissUnticked()

            // The Cleaner's backstop: the screen hasn't heard Chrome opened.
            demo.setChromeOpen(false)
            running.refresh()
            junk.debugSelectOnly([chrome.id])
            demo.setChromeOpen(true)
            await junk.confirmClean()
            await pause(1_200)
            await snap("junk-nothing-moved")
            junk.dismissResult()
            running.refresh()
            // The widest list header: the Trash, with its Empty Trash button.
            if junk.result(for: .trash) != nil {
                junk.riskFilter = .all
                junk.focusedCategory = .trash
                await pause()
                await snap("junk-trash")
            }

            appState.section = .sweep
            await appState.sweep.sweep()
            await pause(900)
            await snap("sweep-left-out")
            NSApp.terminate(nil)
        }

        /// `-snapshotUpdates YES` (use with `-junkDemo YES`): the Apps screen's Updates tab with made-up
        /// results for the demo apps (no network): checking, the list, every section open, offline
        /// (`updates-checking-…`, `updates-list-…`, `updates-all-…`, `updates-offline-…`).
        static var updatesFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotUpdates") }

        static func walkUpdatesFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) { writeKeyWindow(to: directory.appendingPathComponent("\(name)-\(suffix).png")) }
            let apps = appState.apps
            let updates = appState.updates
            try? await Task.sleep(for: .seconds(1.2))
            await apps.load(hasFullDiskAccess: appState.permissions.hasFullDiskAccess())
            // A recent result first, so opening the tab doesn't start a real check.
            updates.debugShow(DebugUpdates.demoReport(apps: apps.apps))
            updates.debugShowChecking(done: 4, total: 6)
            apps.tab = .updates
            appState.section = .apps
            try? await Task.sleep(for: .milliseconds(900))
            snap("updates-checking")
            updates.debugShowChecking(done: 0, total: 0)
            try? await Task.sleep(for: .milliseconds(700))
            snap("updates-list")
            updates.showCantCheck = true
            updates.showUpToDate = true
            try? await Task.sleep(for: .milliseconds(700))
            snap("updates-all")
            updates.debugShow(DebugUpdates.demoReport(apps: apps.apps, offline: true))
            try? await Task.sleep(for: .milliseconds(700))
            snap("updates-offline")
            NSApp.terminate(nil)
        }

        /// `-snapshotMenuBar YES`: the Settings screen (as saved, then with every switch shown on —
        /// in memory only, nothing registered or requested), and the menu-bar popover drawn in a plain
        /// window with this Mac's live readings and with made-up ones (`settings-…`, `settings-on-…`,
        /// `popover-live-…`, `popover-demo-…`).
        static var menuBarFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotMenuBar") }

        static func walkMenuBarFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .settings
            try? await Task.sleep(for: .milliseconds(700))
            writeKeyWindow(to: directory.appendingPathComponent("settings-\(suffix).png"))
            appState.settingsModel.debugShowAllOn()
            try? await Task.sleep(for: .milliseconds(500))
            writeKeyWindow(to: directory.appendingPathComponent("settings-on-\(suffix).png"))

            // Live: open cadence (the popover's own), wait for a full sample.
            let menuBar = appState.menuBar
            menuBar.start()
            menuBar.isPresented = true
            for _ in 0..<40 where !menuBar.hasFullSample { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(2.2))
            await writePopover(appState: appState, to: directory.appendingPathComponent("popover-live-\(suffix).png"))
            menuBar.isPresented = false
            menuBar.debugShowDemo()
            await writePopover(appState: appState, to: directory.appendingPathComponent("popover-demo-\(suffix).png"))
            NSApp.terminate(nil)
        }

        private static func writePopover(appState: AppState, to url: URL) async {
            let popover = MenuBarPopover(
                model: appState.menuBar, thresholdBytes: appState.settingsModel.lowDiskThresholdBytes,
                sweepNow: {}, openDustpan: {}, quit: {})
            let host = NSHostingView(rootView: popover)
            host.frame.size = host.fittingSize
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil)
        }

        /// `-snapshotUninstallAdmin YES` (use with `-junkDemo YES -forceAccess YES`, optionally
        /// `-snapshotWindowWidth 900`): an app installed for all users (demo "Huddle", read-only) —
        /// the list with its badge, the detail with "Show in Finder", the grouped result of a
        /// refused uninstall, and the "is gone — remove its leftovers?" prompt after the demo bundle
        /// is deleted as if from Finder (`admin-installed…`, `admin-detail…`, `admin-result…`,
        /// `admin-gone…`, `admin-gone-result…`).
        /// `-snapshotTrashFinder YES` (with `-junkDemo YES -forceAccess YES [-snapshotWindowWidth 900|1080]`):
        /// a demo Trash holding entries only Finder can delete. Captures the Trash tile, the mixed
        /// confirmation, the note after Empty Trash, and the Finder-only confirmation
        /// (`trash-tile-…`, `trash-confirm-mixed-…`, `trash-result-left-…`, `trash-confirm-finder-only-…`).
        /// Empty Trash only ever touches the demo's temp Trash.
        static var trashFinderFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotTrashFinder") }

        static func walkTrashFinderFlow(appState: AppState) async {
            guard let directory, let base = DebugDemo.base,
                PathTools.isStrictlyInside(appState.cleaner.trashDirectory.path, root: base.path)
            else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) async {
                await applyWindowSize()
                try? await Task.sleep(for: .milliseconds(400))
                writeKeyWindow(to: directory.appendingPathComponent("\(name)\(sizeSuffix)-\(suffix).png"))
            }
            let junk = appState.junk
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .junk
            await junk.scan(hasFullDiskAccess: appState.onboarding.hasFullDiskAccess)
            junk.focusedCategory = .trash
            await snap("trash-tile")
            await junk.requestEmptyTrash()
            await snap("trash-confirm-mixed")
            await junk.confirmEmptyTrash()
            await appState.spaceRefresh?.value
            await snap("trash-result-left")
            await junk.requestEmptyTrash()
            await snap("trash-confirm-finder-only")
            NSApp.terminate(nil)
        }

        static var uninstallAdminFlow: Bool { UserDefaults.standard.bool(forKey: "snapshotUninstallAdmin") }

        static func walkUninstallAdminFlow(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) async {
                await applyWindowSize()
                try? await Task.sleep(for: .milliseconds(400))
                writeKeyWindow(to: directory.appendingPathComponent("\(name)\(sizeSuffix)-\(suffix).png"))
            }
            let apps = appState.apps
            let access = appState.permissions.hasFullDiskAccess()
            try? await Task.sleep(for: .seconds(1.2))
            appState.section = .apps
            await apps.load(hasFullDiskAccess: access)
            await snap("admin-installed")
            await apps.debugSelect(bundleID: "com.huddle.Huddle")
            try? await Task.sleep(for: .milliseconds(600))
            await snap("admin-detail")
            await apps.debugForceUninstall()
            await snap("admin-result")
            guard let huddle = apps.lastUninstallApp else { return }
            apps.dismissResult()
            apps.debugWatchForRemoval(huddle)
            DebugDemo.simulateFinderRemovalOfAdminApp()
            await apps.checkForRemovedApps()
            await snap("admin-gone")
            await apps.confirmGoneLeftovers()
            await snap("admin-gone-result")
            NSApp.terminate(nil)
        }

        static var appearanceSuffix: String {
            NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        }

        static func walkSections(select: (AppSection) -> Void) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1))
            for section in AppSection.allCases {
                select(section)
                try? await Task.sleep(for: .milliseconds(700))
                writeKeyWindow(to: directory.appendingPathComponent("\(section.rawValue)-\(appearanceSuffix).png"))
            }
            NSApp.terminate(nil)
        }

        // MARK: Window size

        /// `-snapshotWindowWidth 900` (and optionally `-snapshotWindowHeight 600`).
        static var windowWidth: Double { UserDefaults.standard.double(forKey: "snapshotWindowWidth") }

        /// "-900" when a width is set, so file names say which size they show.
        static var sizeSuffix: String { windowWidth > 0 ? "-\(Int(windowWidth))" : "" }

        /// Resizes the window (re-asserted before every snap: SwiftUI may restore the scene's default
        /// size meanwhile), never below its real minimum (SwiftUI derives it from the content and
        /// AppKit would undo a smaller frame), then lets it lay out.
        static func applyWindowSize() async {
            let width = windowWidth
            guard width > 0 else { return }
            let height = UserDefaults.standard.double(forKey: "snapshotWindowHeight")
            func apply() {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
                let content = NSSize(
                    width: max(width, window.contentMinSize.width),
                    height: max(height > 0 ? height : Metric.windowDefault.height, window.contentMinSize.height))
                let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
                guard window.frame.size != frame.size else { return }
                window.setFrame(NSRect(origin: window.frame.origin, size: frame.size), display: true, animate: false)
            }
            apply()
            try? await Task.sleep(for: .milliseconds(300))
            apply()
            NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.layoutIfNeeded()
        }

        // MARK: Layout audit

        /// `-snapshotLayoutAudit YES` (use with `-junkDemo YES -forceAccess YES`, which then adds every
        /// demo extra, and `-snapshotWindowWidth <w>`): every screen in turn, for checking nothing
        /// overflows at that width. Sweep idle/scanning/results/confirm/celebration/after, Junk, Apps
        /// (installed, detail, leftovers, updates), Space map, Clutter (Large & old, Duplicates),
        /// History, Settings (`audit-<screen>-<width>-<appearance>.png`).
        static var layoutAudit: Bool { UserDefaults.standard.bool(forKey: "snapshotLayoutAudit") }

        static func walkLayoutAudit(appState: AppState) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = appearanceSuffix
            func snap(_ name: String) async {
                await applyWindowSize()
                writeKeyWindow(to: directory.appendingPathComponent("audit-\(name)\(sizeSuffix)-\(suffix).png"))
            }
            func pause(_ ms: Int = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }
            let access = appState.permissions.hasFullDiskAccess()
            try? await Task.sleep(for: .seconds(1.2))

            let sweep = appState.sweep
            appState.section = .sweep
            await pause()
            await snap("sweep-idle")
            sweep.debugShow(
                phase: .scanning,
                states: [
                    .junk: .finished, .orphans: .finished, .unusedApps: .running(nil), .duplicates: .running(0.42),
                    .largeOld: .waiting,
                ])
            await pause()
            await snap("sweep-scanning")
            sweep.debugShow(phase: .idle, states: [:])
            await sweep.sweep()
            await pause(900)
            await snap("sweep-results")
            sweep.requestClean()
            await pause()
            await snap("sweep-confirm")
            await sweep.confirmClean()
            await pause(1_500)
            await snap("sweep-celebration")
            sweep.dismissResult()
            await pause()
            await snap("sweep-after-clean")

            appState.section = .junk
            await pause()
            await snap("junk")

            let apps = appState.apps
            appState.section = .apps
            apps.tab = .installed
            await apps.load(hasFullDiskAccess: access)
            await pause(800)
            await snap("apps-installed")
            await apps.debugSelect(bundleID: "com.inkwell.Inkwell")
            await pause(800)
            await snap("apps-detail")
            apps.tab = .leftovers
            await apps.loadOrphans(hasFullDiskAccess: access)
            apps.debugSelectFirstOrphan()
            await pause(800)
            await snap("apps-leftovers")
            appState.updates.debugShow(DebugUpdates.demoReport(apps: apps.apps))
            apps.tab = .updates
            await pause(900)
            await snap("apps-updates")
            apps.tab = .installed

            let map = appState.spaceMap
            appState.section = .spaceMap
            map.start(.home)
            await map.waitForWalk()
            await pause(900)
            await snap("spacemap")

            let clutter = appState.clutter
            appState.section = .clutter
            clutter.tab = .largeOld
            clutter.largeOld.filter = .sweep
            await clutter.largeOld.scan()
            await pause(800)
            await snap("clutter-largeold")
            clutter.tab = .duplicates
            await clutter.duplicates.scan()
            await pause(2_500)
            await snap("clutter-duplicates")

            appState.section = .history
            await pause(1_000)
            await snap("history")
            appState.section = .settings
            await pause(800)
            await snap("settings")
            NSApp.terminate(nil)
        }

        static func writeOnboarding(step: OnboardingModel.Step) async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.2))
            await applyWindowSize()
            writeKeyWindow(
                to: directory.appendingPathComponent(
                    "onboarding-step\(step.rawValue)\(sizeSuffix)-\(appearanceSuffix).png"))
            NSApp.terminate(nil)
        }

        static func writeBanner() async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.2))
            writeKeyWindow(to: directory.appendingPathComponent("banner-\(appearanceSuffix).png"))
            NSApp.terminate(nil)
        }

        static func writeDesignSheet() async {
            guard let directory else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1))
            let renderer = ImageRenderer(
                content: HStack(alignment: .top, spacing: 0) {
                    DesignSheet().environment(\.colorScheme, .light)
                    DesignSheet().environment(\.colorScheme, .dark)
                }
            )
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            {
                try? png.write(to: directory.appendingPathComponent("design-preview.png"))
            }
            writeKeyWindow(to: directory.appendingPathComponent("design-preview-window-\(appearanceSuffix).png"))
            NSApp.terminate(nil)
        }

        private static func writeKeyWindow(to url: URL) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
