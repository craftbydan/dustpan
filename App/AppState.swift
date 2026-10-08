import AppKit
import Foundation
import Observation
import os

/// What just happened to the space on disk (see `AppState.spaceChanged`).
enum SpaceChange: Sendable, Equatable {
    /// Items went to the Trash (no space is freed until the Trash is emptied).
    case movedToTrash
    /// Items came back out of the Trash (Undo, Put back).
    case putBack
    /// Empty Trash deleted items for good.
    case emptiedTrash
}

/// Root of the object graph. Holds the services that feature models use.
/// Services are added here as later prompts introduce them.
@Observable
@MainActor
final class AppState {
    /// For SwiftUI previews only. The app creates its own instance in `DustpanApp`.
    static let shared = AppState()

    let database: AppDatabase?
    /// The bundled junk rules (`rules.json`), loaded and validated on first use.
    let ruleCatalog: RuleCatalog
    /// Full Disk Access checks. The only permission Dustpan looks at.
    let permissions: any PermissionsChecking
    /// Small settings in the `setting` table (in memory when there is no database).
    let settings: SettingsStore
    /// First-run steps and Full Disk Access state, shared by the shell and its banner.
    let onboarding: OnboardingModel
    /// The cleanup log and ignore list.
    let cleanupStore: CleanupStore
    /// The only thing that moves files (to the Trash) or deletes them (Empty Trash).
    let cleaner: Cleaner
    /// Which apps junk waits on (`requiresQuit`) are open, kept current from NSWorkspace; shared by
    /// the Junk and Sweep screens. The Cleaner still checks for itself when it moves anything.
    let runningApps: RunningApps
    /// The home folder scans look in (a temp folder in DEBUG demo runs).
    let home: URL
    /// The Junk screen's state; kept here so results survive switching sections.
    let junk: JunkModel
    let history: HistoryModel
    /// The Apps screen's state (installed apps, leftovers, uninstall).
    let apps: AppsModel
    /// The Apps screen's Updates tab (read-only checks; only when the tab opens).
    let updates: UpdatesModel
    /// The Space map's state (disk walk, treemap, Move to Trash).
    let spaceMap: SpaceMapModel
    /// The Clutter screen's state (Large & old, Duplicates).
    let clutter: ClutterModel
    /// The Quick Look panel's controller (Clutter's space bar).
    let quickLook = QuickLook()
    /// The Sweep screen's state (one scan of everything, "Clean recommended").
    let sweep: SweepModel
    /// Free space on the startup disk: one model for the sidebar footer and the Sweep.
    let disk: DiskSpaceModel
    /// How many times something was moved to the Trash, put back, or the Trash emptied (tests).
    private(set) var spaceChanges = 0
    /// The refresh started by the last `spaceChanged` / `refreshSpace` (tests await it).
    private(set) var spaceRefresh: Task<Void, Never>?

    /// Menu-bar, reminder and low-disk settings (Prompt 13).
    let settingsModel: SettingsModel
    /// The menu-bar item's state; its `SystemMonitor` samples every 60 s (2 s with the popover open).
    let menuBar: MenuBarModel
    /// Opens a new main window (set by a SwiftUI view that has `openWindow`).
    var windowOpener: (@MainActor () -> Void)?

    /// The section shown in the window.
    var section: AppSection = AppState.initialSection

    /// A non-fatal start-up problem, shown later as a quiet banner.
    private(set) var startupIssue: DustpanError?

    init(
        database: AppDatabase?, startupIssue: DustpanError? = nil,
        permissions: any PermissionsChecking = Permissions(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        trashMover: (any TrashMover)? = nil,
        runningApps: any RunningAppsChecking = WorkspaceRunningApps(),
        appRoots: [URL]? = nil,
        systemLibrary: URL = URL(fileURLWithPath: "/Library", isDirectory: true),
        signing: any CodeSigningReading = SecCodeSigningReader(),
        lastUsed: any LastUsedReading = SpotlightLastUsed(),
        quitter: any AppQuitting = WorkspaceAppQuitter(),
        loginItem: any LoginItemControlling = LaunchAtLoginItem(),
        notifications: any NotificationScheduling = SystemNotificationCenter(),
        monitor: SystemMonitor? = nil,
        updateChecker: UpdateChecker? = nil,
        urlOpener: any URLOpening = WorkspaceURLOpener(),
        diskReader: DiskSpaceModel.Reader? = nil,
        forceMenuBar: Bool = false
    ) {
        self.database = database
        self.startupIssue = startupIssue
        self.permissions = permissions
        self.home = home
        let settings = SettingsStore(database: database)
        let catalog = RuleCatalog()
        let store = CleanupStore(database: database)
        let roots = appRoots ?? AppScanner.defaultRoots(home: home)
        // A demo (fake) app folder isn't indexed by Spotlight; only the real folders are queried.
        let appScanner = AppScanner(roots: roots, useSpotlight: appRoots == nil, signing: signing, lastUsed: lastUsed)
        let appContext = AppCleaningContext(
            appRoots: roots, systemLibrary: systemLibrary, signing: signing,
            installedApps: { await appScanner.identities() }, isKnownApp: { LaunchServicesApps.isKnown($0) },
            knownAppPath: { LaunchServicesApps.path(for: $0) })
        let cleaner = Cleaner(
            home: home, trashMover: trashMover, runningApps: runningApps, store: store,
            rules: { try await catalog.rules() }, hasFullDiskAccess: { permissions.hasFullDiskAccess() },
            appContext: appContext)
        self.settings = settings
        self.disk = diskReader.map { DiskSpaceModel(read: $0) } ?? DiskSpaceModel()
        self.settingsModel = SettingsModel(
            store: settings, loginItem: loginItem, notifications: notifications, forceMenuBar: forceMenuBar)
        self.menuBar = MenuBarModel(
            monitor: monitor ?? SystemMonitor(),
            lowDisk: LowDiskAlert(settings: settings, notifications: notifications))
        self.ruleCatalog = catalog
        self.cleanupStore = store
        self.cleaner = cleaner
        self.onboarding = OnboardingModel(permissions: permissions, settings: settings, catalog: catalog)
        let running = RunningApps(checker: runningApps, quitter: quitter)
        self.runningApps = running
        self.junk = JunkModel(catalog: catalog, cleaner: cleaner, store: store, home: home, runningApps: running)
        self.history = HistoryModel(cleaner: cleaner, home: home)
        self.apps = AppsModel(
            scanner: appScanner, cleaner: cleaner, home: home, systemLibrary: systemLibrary, runningApps: runningApps,
            quitter: quitter)
        self.updates = UpdatesModel(checker: updateChecker ?? UpdateChecker(), opener: urlOpener)
        let walker = DiskWalker(home: home, hasFullDiskAccess: { permissions.hasFullDiskAccess() })
        self.spaceMap = SpaceMapModel(
            walker: walker, cleaner: cleaner, store: store, home: home, runningApps: running, settings: settings)
        // A demo (fake) home isn't indexed by Spotlight; only the real home is queried.
        let largeOld = LargeOldFinder(
            home: home, hasFullDiskAccess: { permissions.hasFullDiskAccess() },
            index: appRoots == nil ? SpotlightLargeFiles() : nil)
        let duplicates = DuplicateFinder(home: home, hasFullDiskAccess: { permissions.hasFullDiskAccess() })
        self.clutter = ClutterModel(
            largeOld: LargeOldModel(finder: largeOld, cleaner: cleaner, home: home),
            duplicates: DuplicatesModel(finder: duplicates, cleaner: cleaner, home: home))

        // The Sweep runs the same scanners, with the same settings, as the feature screens.
        let coordinator = ScanCoordinator(scanners: [
            JunkSweepScanner(catalog: catalog, store: store, home: home),
            OrphanSweepScanner(scanner: appScanner, home: home, systemLibrary: systemLibrary),
            UnusedAppsSweepScanner(scanner: appScanner),
            DownloadsDuplicatesSweepScanner(finder: duplicates, home: home),
            LargeOldSweepScanner(finder: largeOld),
        ])
        let onboarding = self.onboarding
        self.sweep = SweepModel(
            coordinator: coordinator, cleaner: cleaner, settings: settings,
            hasFullDiskAccess: { onboarding.hasFullDiskAccess }, runningApps: running)
        sweep.handoff = SweepModel.Handoff(
            finished: { [weak self] outcome, access in await self?.adoptSweep(outcome, hasFullDiskAccess: access) },
            cleaned: { [weak self] ids in self?.junk.forget(ids) })
        settingsModel.menuBarTurnedOff = { [weak self] in MainWindow.menuBarTurnedOff(opener: self?.windowOpener) }

        // Every completed move to the Trash, put back or Empty Trash reports here.
        let changed: (SpaceChange) -> Void = { [weak self] change in self?.spaceChanged(change) }
        junk.spaceChanged = changed
        sweep.spaceChanged = changed
        history.spaceChanged = changed
        apps.spaceChanged = changed
        spaceMap.spaceChanged = changed
        clutter.largeOld.spaceChanged = changed
        clutter.duplicates.spaceChanged = changed
        // Finder can delete what was put in the Trash with the user's password; Dustpan can't.
        let trashFolder = cleaner.trashDirectory
        junk.openTrashInFinder = { NSWorkspace.shared.open(trashFolder) }
    }

    // MARK: - Disk space and the Trash

    /// Something was moved to the Trash, put back, or the Trash was emptied: re-reads free space
    /// and re-measures the Trash (Junk's Trash tile). Moving to the Trash frees nothing until the
    /// Trash is emptied, so the Trash tile is what grows; the disk bar moves after Empty Trash.
    func spaceChanged(_ change: SpaceChange) {
        spaceChanges += 1
        junk.noteSpaceChange(change)
        refreshSpace()
        // APFS can report freed space a moment late.
        if change == .emptiedTrash { disk.refreshAgain() }
    }

    /// Re-reads free space and the Trash's size (off the main actor). Also runs when the app
    /// becomes active, since the user may have emptied the Trash in Finder. Never on a timer.
    func refreshSpace() {
        let disk = disk
        let junk = junk
        spaceRefresh = Task {
            await disk.refresh()
            await junk.refreshTrash()
        }
    }

    // MARK: - Menu bar and notifications

    /// Brings the main window forward (opening one if none is left) on the Sweep screen.
    /// `start`: also starts a Sweep ("Sweep now" in the popover) when nothing else is running.
    func showSweep(start: Bool) {
        section = .sweep
        MainWindow.present(opener: windowOpener)
        guard start, onboarding.isLoaded, !onboarding.isPresented, !sweep.isScanning, !sweep.isCleaning else {
            return
        }
        sweep.start()
    }

    /// A clicked Dustpan notification: open the window on the screen it points at.
    func handleNotification(identifier: String) {
        guard let target = DustpanNotification.section(for: identifier) else { return }
        section = target
        MainWindow.present(opener: windowOpener)
    }

    func setShowInMenuBar(_ on: Bool) async {
        await settingsModel.setShowInMenuBar(on)
    }

    /// Hands a Sweep's findings to the feature screens that are free to take them, so "Review →"
    /// shows the same list without looking again.
    func adoptSweep(_ outcome: SweepOutcome, hasFullDiskAccess: Bool) async {
        for (module, finding) in outcome.findings {
            switch (module, finding) {
            case (.junk, .junk(let output)) where junk.canAdopt:
                junk.adopt(output, hasFullDiskAccess: hasFullDiskAccess)
                await junk.refreshTrashKept()
            case (.orphans, .orphans(let scan)) where apps.canAdopt:
                apps.adopt(orphans: scan, hasFullDiskAccess: hasFullDiskAccess)
            case (.unusedApps, .apps(let records)) where apps.canAdopt:
                await apps.adopt(apps: records, hasFullDiskAccess: hasFullDiskAccess)
            case (.duplicates, .duplicates(let scan)) where clutter.duplicates.canAdopt:
                clutter.duplicates.adopt(scan, folder: home.appendingPathComponent("Downloads", isDirectory: true))
            case (.largeOld, .largeOld(let scan)) where clutter.largeOld.canAdopt:
                clutter.largeOld.adopt(scan)
            default:
                break
            }
        }
    }

    /// "Review →" on a Sweep tile: opens that feature screen, set to what the tile counted.
    func review(_ module: SweepModule) {
        switch module {
        case .junk:
            section = .junk
        case .orphans:
            apps.tab = .leftovers
            section = .apps
        case .unusedApps:
            apps.tab = .installed
            apps.sort = .lastUsed
            section = .apps
        case .duplicates:
            clutter.tab = .duplicates
            section = .clutter
        case .largeOld:
            clutter.tab = .largeOld
            clutter.largeOld.filter = .sweep
            section = .clutter
        }
    }

    /// "Review safe items" on the Sweep: opens Junk with the Safe filter on, focused on the category
    /// with the most safe bytes. Nothing is ticked for the user.
    func reviewSafeJunk() {
        junk.riskFilter = .safe
        junk.searchText = ""
        let bySafeBytes = junk.results.map { result in
            (
                result.category,
                result.items.filter { $0.risk == .safe && !$0.detectionOnly }
                    .reduce(Int64(0)) { $0 + $1.allocatedSize }
            )
        }
        if let best = bySafeBytes.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) { junk.focusedCategory = best.0 }
        section = .junk
    }

    /// Opens the real database in Application Support, except when hosted by a test runner.
    convenience init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            self.init(database: nil)
            return
        }
        var permissions: any PermissionsChecking = Permissions()
        #if DEBUG
            // `-forceNoAccess YES` acts as if Full Disk Access is off (screenshots of the banner).
            if UserDefaults.standard.bool(forKey: "forceNoAccess") { permissions = Permissions(check: { false }) }
            // `-forceAccess YES` (demo screenshots only, with `-junkDemo`): act as if access is on, so the
            // made-up home's guarded folders are shown. The demo home is a temp folder.
            if UserDefaults.standard.bool(forKey: "forceAccess"), UserDefaults.standard.bool(forKey: "junkDemo") {
                permissions = Permissions(check: { true })
            }
            // `-junkDemo YES`: a made-up home folder, Trash and history in a temp folder (screenshots).
            if let demo = DebugDemo.makeIfRequested() {
                self.init(
                    database: demo.database, permissions: permissions, home: demo.home, trashMover: demo.trashMover,
                    runningApps: demo.runningApps, appRoots: demo.appRoots, systemLibrary: demo.systemLibrary,
                    signing: DemoSigning(), lastUsed: DemoLastUsed(), quitter: demo.runningApps,
                    forceMenuBar: Self.forceMenuBar)
                return
            }
        #endif
        do {
            self.init(
                database: try AppDatabase.openDefault(), permissions: permissions, forceMenuBar: Self.forceMenuBar)
        } catch {
            Logger(subsystem: "app.dustpan", category: "app")
                .error("Database could not be opened: \(error.localizedDescription, privacy: .private)")
            self.init(
                database: nil, startupIssue: error as? DustpanError ?? .databaseUnavailable, permissions: permissions,
                forceMenuBar: Self.forceMenuBar)
        }
    }

    /// DEBUG `-forceMenuBar YES` shows the menu-bar item for one run without saving the setting.
    private static var forceMenuBar: Bool {
        #if DEBUG
            UserDefaults.standard.bool(forKey: "forceMenuBar")
        #else
            false
        #endif
    }

    /// DEBUG builds accept `-startSection <id>` so screenshots can open any screen.
    private static var initialSection: AppSection {
        #if DEBUG
            if let raw = UserDefaults.standard.string(forKey: "startSection"),
                let section = AppSection(rawValue: raw)
            {
                return section
            }
        #endif
        return .sweep
    }
}
