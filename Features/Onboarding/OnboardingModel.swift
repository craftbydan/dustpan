import Foundation
import Observation
import os

/// First-run steps and Full Disk Access state for the whole app.
///
/// - Shown on first launch, and at any launch where access is missing — unless the user chose
///   "Continue with limited scan", which is remembered.
/// - While visible, it polls for access (via `watchForAccess()`, cancelled with the view) and
///   moves from the access step to "done" as soon as access is on, with no relaunch.
/// - When access is missing and the steps are hidden, the shell shows a quiet banner that
///   reopens them (`showAccessSteps()`).
@Observable
@MainActor
final class OnboardingModel {
    enum Step: Int, CaseIterable, Sendable {
        case welcome = 1
        case access = 2
        case done = 3
    }

    private(set) var step: Step = .welcome
    private(set) var isPresented = false
    private(set) var hasFullDiskAccess = false
    /// True once `load()` has decided what to show; the shell waits for it.
    private(set) var isLoaded = false
    /// Junk categories with at least one rule that needs Full Disk Access.
    private(set) var accessCategories: [JunkCategory] = []

    /// The quiet "limited scan" banner in the shell.
    var showsBanner: Bool { isLoaded && !hasFullDiskAccess && !isPresented }

    private let permissions: any PermissionsChecking
    private let settings: SettingsStore
    private let catalog: RuleCatalog?
    private let logger = Logger(subsystem: "app.dustpan", category: "onboarding")

    init(permissions: any PermissionsChecking, settings: SettingsStore, catalog: RuleCatalog? = nil) {
        self.permissions = permissions
        self.settings = settings
        self.catalog = catalog
    }

    /// Reads settings and the current access state, then decides whether to show the steps.
    /// `allowPresentation: false` keeps them hidden (DEBUG screenshot runs).
    func load(allowPresentation: Bool = true) async {
        hasFullDiskAccess = await checkAccess()
        let completed = await settings.bool(.onboardingCompleted)
        let limited = await settings.bool(.limitedScanChosen)
        if allowPresentation {
            if !completed {
                step = .welcome
                isPresented = true
            } else if !hasFullDiskAccess && !limited {
                step = .access
                isPresented = true
            }
        }
        if let catalog, let rules = try? await catalog.rules() {
            accessCategories = Set(rules.filter(\.needsFullDiskAccess).map(\.category)).sorted()
        }
        isLoaded = true
        logger.info(
            "Launch: access \(self.hasFullDiskAccess, privacy: .public), steps shown \(self.isPresented, privacy: .public)"
        )
    }

    /// Step 1 → step 2, or straight to "done" if access is already on.
    func next() {
        switch step {
        case .welcome: step = hasFullDiskAccess ? .done : .access
        case .access: step = hasFullDiskAccess ? .done : .access
        case .done: break
        }
    }

    func back() {
        if step == .access { step = .welcome }
    }

    func openSettings() {
        permissions.openFullDiskAccessSettings()
    }

    func revealApp() {
        permissions.revealAppInFinder()
    }

    /// "Continue with limited scan": remembered, so the steps don't come back at launch.
    func continueWithLimitedScan() async {
        await settings.set(true, for: .limitedScanChosen)
        await settings.set(true, for: .onboardingCompleted)
        isPresented = false
    }

    /// "Done" step's button.
    func finish() async {
        await settings.set(true, for: .onboardingCompleted)
        await settings.set(false, for: .limitedScanChosen)
        isPresented = false
    }

    /// From the banner: back to the access step (or "done" if access arrived meanwhile).
    func showAccessSteps() {
        step = hasFullDiskAccess ? .done : .access
        isPresented = true
    }

    /// Polls for access until it is on or the calling task is cancelled. Call only while the
    /// steps are visible (the view runs it in `.task`, which SwiftUI cancels on disappear).
    func watchForAccess() async {
        for await granted in permissions.waitForFullDiskAccess() {
            apply(granted: granted)
        }
    }

    /// One-off re-check, e.g. when the app becomes active again.
    func refreshAccess() async {
        apply(granted: await checkAccess())
    }

    private func apply(granted: Bool) {
        if granted != hasFullDiskAccess {
            logger.info("Full Disk Access is now \(granted ? "on" : "off", privacy: .public)")
        }
        hasFullDiskAccess = granted
        if granted && step == .access { step = .done }
    }

    private func checkAccess() async -> Bool {
        let permissions = permissions
        return await Task.detached(priority: .userInitiated) { permissions.hasFullDiskAccess() }.value
    }

    #if DEBUG
        /// DEBUG screenshots: show a given step.
        func debugPresent(_ step: Step) {
            self.step = step
            isPresented = true
            isLoaded = true
        }

        /// DEBUG: forget the first-run choices (`-resetOnboarding YES`).
        func debugReset() async {
            for key in SettingsStore.Key.allCases { await settings.remove(key) }
        }
    #endif
}
