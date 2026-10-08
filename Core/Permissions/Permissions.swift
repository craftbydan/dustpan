import AppKit
import Foundation
import PermissionsKit
import os

/// What the app needs to know about Full Disk Access. Dustpan asks for no other permission.
/// `Permissions` is the real one; tests pass a fake.
protocol PermissionsChecking: Sendable {
    /// Whether Dustpan can read folders macOS guards with Full Disk Access. Quick (a few file
    /// opens), safe from any thread.
    func hasFullDiskAccess() -> Bool

    /// Polls `hasFullDiskAccess()` and yields the current value first, then each change.
    /// Finishes once access is on. Polling stops when the consumer stops iterating (task
    /// cancelled), so callers only iterate while the onboarding is visible.
    func waitForFullDiskAccess() -> AsyncStream<Bool>

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    @MainActor func openFullDiskAccessSettings()

    /// Shows Dustpan.app selected in Finder, ready to drag into the Full Disk Access list.
    @MainActor func revealAppInFinder()
}

/// The real checker, backed by PermissionsKit (MIT; see THIRD_PARTY_NOTICES.md).
///
/// There is no API to request Full Disk Access: an app detects it and sends the user to
/// System Settings. PermissionsKit detects it by trying to open files only readable with
/// access (Safari bookmarks, the user TCC database, Time Machine prefs).
struct Permissions: PermissionsChecking {
    /// `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    /// How often `waitForFullDiskAccess()` checks. 1.5 s keeps the "done" flip under 2 s.
    let pollInterval: Duration
    private let check: @Sendable () -> Bool

    init(pollInterval: Duration = .milliseconds(1500), check: (@Sendable () -> Bool)? = nil) {
        self.pollInterval = pollInterval
        self.check = check ?? { PermissionsKit.authorizationStatus(for: .fullDiskAccess) == .authorized }
    }

    func hasFullDiskAccess() -> Bool { check() }

    func waitForFullDiskAccess() -> AsyncStream<Bool> {
        let check = check
        let interval = pollInterval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task.detached(priority: .utility) {
                var last: Bool?
                while !Task.isCancelled {
                    let granted = check()
                    if granted != last {
                        continuation.yield(granted)
                        last = granted
                    }
                    if granted { break }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor func openFullDiskAccessSettings() {
        guard let url = Self.fullDiskAccessSettingsURL else { return }
        if !NSWorkspace.shared.open(url) {
            Logger(subsystem: "app.dustpan", category: "permissions")
                .error("Could not open the Full Disk Access settings pane")
        }
    }

    @MainActor func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}

/// Places in the home folder that macOS guards with Full Disk Access, its per-folder prompts
/// (Desktop, Documents, Downloads) or its "access data from other apps" check (App Data:
/// other apps' Application Support folders and containers). A rule reaching into one of these
/// must set `needsFullDiskAccess`, so it never runs — and never triggers a macOS prompt —
/// without access. `~/Library/Caches` is not here: it can be read without a prompt.
enum FullDiskAccessPaths {
    static let roots: [String] = [
        "~/.Trash",
        "~/Desktop",
        "~/Documents",
        "~/Downloads",
        "~/Library/Application Support",
        "~/Library/Containers",
        "~/Library/Group Containers",
        "~/Library/CloudStorage",
        "~/Library/Mobile Documents",
        "~/Library/Safari",
        "~/Library/Mail",
        "~/Library/Messages",
        "~/Library/Cookies",
        "~/Library/Calendars",
        "~/Library/Reminders",
        "~/Library/HomeKit",
        "~/Library/Suggestions",
        "~/Library/IdentityServices",
        "~/Library/Metadata/CoreSpotlight",
        // Apple Music / iTunes data (Media & Apple Music privacy check).
        "~/Library/iTunes",
    ]

    /// Extra places the Space map's disk walker never opens without access, on top of `roots`:
    /// media folders (macOS may guard them per folder) and `~/Library` folders that hold
    /// personal data behind its privacy checks. Not used to validate rules (no rule reaches them).
    static let walkerExtraRoots: [String] = [
        "~/Pictures",
        "~/Movies",
        "~/Music",
        "~/Library/Photos",
        "~/Library/Accounts",
        "~/Library/Application Scripts",
        "~/Library/Assistant",
        "~/Library/Autosave Information",
        "~/Library/Biome",
        "~/Library/Daemon Containers",
        "~/Library/DuetExpertCenter",
        "~/Library/IntelligencePlatform",
        "~/Library/PersonalizationPortrait",
        "~/Library/Sharing",
        "~/Library/Shortcuts",
        "~/Library/StatusKit",
        "~/Library/Trial",
        "~/Library/Weather",
    ]

    /// Every folder the disk walker skips without Full Disk Access.
    static var walkerRoots: [String] { roots + walkerExtraRoots }

    /// Without Full Disk Access, the only `~/Library` folders Dustpan opens (Space map) or moves
    /// things out of (Space map's Move to Trash). Everything else directly in `~/Library` is
    /// mostly macOS's own data behind privacy checks.
    static let libraryAllowlist: Set<String> = [
        "caches", "developer", "logs", "fonts", "preferences", "saved application state", "launchagents",
        "python", "input methods", "services", "spelling", "audio", "google", "httpstorages", "webkit",
        "keyboard layouts", "screen savers", "sounds", "colorpickers", "colors", "preferencepanes", "quicklook",
        "internet plug-ins", "printers", "org.swift.swiftpm", "pnpm", "unity", "jupyter",
    ]

    /// Whether, without Full Disk Access, Dustpan must not open or act on `path` (absolute):
    /// inside a `walkerRoots` folder, or inside `~/Library` but under a folder that isn't on the
    /// allow-list or is named `com.apple.*` (Xcode's `com.apple.dt.*` caches excepted). Shared by
    /// the disk walker and `Cleaner.trashUserChosen`. Text only; touches no file.
    static func isGuardedWithoutAccess(_ path: String, home: String) -> Bool {
        let lower = path.lowercased()
        let homeLower = home.lowercased()
        let guarded = walkerRoots.contains { root in
            PathTools.isInside(lower, root: PathTools.expandTilde(root, home: homeLower).lowercased())
        }
        if guarded { return true }
        let library = homeLower + "/library"
        guard PathTools.isStrictlyInside(lower, root: library) else { return false }
        var parent = library
        for name in PathTools.components(String(lower.dropFirst(library.count))) {
            if isGuardedInLibrary(name: name, parent: parent, library: library) { return true }
            parent += "/" + name
        }
        return false
    }

    /// The `~/Library` part of `isGuardedWithoutAccess` for one child folder (all lowercased).
    static func isGuardedInLibrary(name: String, parent: String, library: String) -> Bool {
        let lower = name.lowercased()
        if parent == library && !libraryAllowlist.contains(lower) { return true }
        return lower.hasPrefix("com.apple.") && !lower.hasPrefix("com.apple.dt.")
    }

    /// Whether a rule path (with `~`, wildcards allowed) could reach into one of `roots`.
    /// A wildcard component counts as matching (conservative).
    static func requiresAccess(_ rulePath: String) -> Bool {
        let path = PathTools.components(rulePath)
        return roots.contains { root in
            let prefix = PathTools.components(root)
            guard path.count >= prefix.count else { return false }
            return zip(path, prefix).allSatisfy { ruleComponent, rootComponent in
                PathTools.fnmatch(ruleComponent, rootComponent)
            }
        }
    }
}
