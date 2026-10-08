import AppKit
import Foundation
import Observation

/// Asks a running app to quit (never forces). Injected so tests can pretend.
protocol AppQuitting: Sendable {
    /// Sends a polite quit to every copy of the app and waits a little. True once none is running.
    @MainActor func quit(bundleID: String) async -> Bool
}

struct WorkspaceAppQuitter: AppQuitting {
    @MainActor func quit(bundleID: String) async -> Bool {
        // `terminate()` only: the same as choosing Quit from the app's menu. Never `forceTerminate()`.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        // Up to ~10 s: the app may show its own "save changes?" dialog first.
        for _ in 0..<40 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// An open app that some junk waits on: the item's rule has `requiresQuit` and the app is running.
struct BlockingApp: Hashable, Sendable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Which of the apps junk rules wait on (`requiresQuit`) are open right now, kept current by
/// NSWorkspace's launch/terminate notifications, so the Junk and Sweep screens can say so before
/// cleaning. One instance, shared through `AppState`. The Cleaner still checks for itself at
/// clean time (CLAUDE.md safety rule 5); this is only the early warning.
@Observable
@MainActor
final class RunningApps {
    /// Bundle ID → display name, for watched apps that are open now.
    private(set) var running: [String: String] = [:]
    /// Apps Dustpan has asked to quit and is waiting on.
    private(set) var quitting: Set<String> = []
    /// Bundle IDs some found item waits on.
    private(set) var watched: Set<String> = []

    @ObservationIgnored private let checker: any RunningAppsChecking
    @ObservationIgnored private let quitter: any AppQuitting
    @ObservationIgnored private var handlers: [@MainActor (_ launched: Set<String>) -> Void] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    init(checker: any RunningAppsChecking, quitter: any AppQuitting, observeWorkspace: Bool = true) {
        self.checker = checker
        self.quitter = quitter
        guard observeWorkspace else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let bundleID = app?.bundleIdentifier
                    MainActor.assumeIsolated { self?.appChanged(bundleID: bundleID) }
                })
        }
    }

    /// Nothing is ever running and nothing is watched from the system (previews, tests).
    static func idle() -> RunningApps {
        RunningApps(checker: NothingRunning(), quitter: NothingRunning(), observeWorkspace: false)
    }

    // MARK: - Reading

    func name(of bundleID: String) -> String? { running[bundleID] }

    /// The open app `item` waits on, if any (its rule has `requiresQuit` and the app is running).
    /// A `requiresQuit` rule without a bundle ID counts as blocked, as in the Cleaner.
    func blocker(for item: ScanItem, rules: [String: Rule]) -> BlockingApp? {
        guard let rule = rules[item.ruleID], rule.requiresQuit else { return nil }
        guard let bundleID = rule.appBundleID else { return BlockingApp(bundleID: "", name: rule.title) }
        return running[bundleID].map { BlockingApp(bundleID: bundleID, name: $0) }
    }

    /// The bundle IDs a set of results waits on.
    static func bundleIDs(of items: [ScanItem], rules: [String: Rule]) -> Set<String> {
        Set(items.compactMap { item in rules[item.ruleID].flatMap { $0.requiresQuit ? $0.appBundleID : nil } })
    }

    // MARK: - Watching

    /// Called after `running` changes, with the bundle IDs that just opened.
    func observe(_ handler: @escaping @MainActor (_ launched: Set<String>) -> Void) {
        handlers.append(handler)
    }

    /// Starts following these apps (adds to the set) and reads their state now.
    func watch(_ bundleIDs: Set<String>) {
        let new = bundleIDs.subtracting(watched)
        guard !new.isEmpty else { return }
        watched.formUnion(new)
        refresh(new)
    }

    /// Reads every watched app's state again (e.g. right before a confirmation).
    func refresh() { refresh(watched) }

    /// An app launched or quit (NSWorkspace notification; tests call it directly).
    func appChanged(bundleID: String?) {
        guard let bundleID, watched.contains(bundleID) else { return }
        refresh([bundleID])
    }

    private func refresh(_ bundleIDs: Set<String>) {
        var next = running
        for id in bundleIDs {
            next[id] = checker.runningAppName(bundleID: id)
        }
        guard next != running else { return }
        let launched = Set(next.keys).subtracting(running.keys)
        running = next
        for handler in handlers { handler(launched) }
    }

    // MARK: - Quitting

    /// Asks the app to quit politely (never forced) and waits up to ~10 s. True once it's closed.
    @discardableResult
    func quit(_ app: BlockingApp) async -> Bool {
        guard !app.bundleID.isEmpty else { return false }
        guard !quitting.contains(app.bundleID) else { return false }
        quitting.insert(app.bundleID)
        defer { quitting.remove(app.bundleID) }
        _ = await quitter.quit(bundleID: app.bundleID)
        refresh([app.bundleID])
        return running[app.bundleID] == nil
    }
}

/// Nothing is open; quitting succeeds at once. For `RunningApps.idle()`.
private struct NothingRunning: RunningAppsChecking, AppQuitting {
    func runningAppName(bundleID: String) -> String? { nil }
    @MainActor func quit(bundleID: String) async -> Bool { true }
}
