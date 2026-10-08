import Foundation
import Testing

@testable import Dustpan

@Suite("Onboarding")
@MainActor
struct OnboardingModelTests {
    private func model(
        granted: Bool = false, completed: Bool = false, limited: Bool = false, poll: Duration = .milliseconds(20)
    ) async -> (OnboardingModel, AccessFlag, SettingsStore) {
        let flag = AccessFlag(granted: granted)
        let settings = SettingsStore(database: nil)
        if completed { await settings.set(true, for: .onboardingCompleted) }
        if limited { await settings.set(true, for: .limitedScanChosen) }
        let model = OnboardingModel(
            permissions: FakePermissions(flag: flag, pollInterval: poll), settings: settings)
        return (model, flag, settings)
    }

    @Test("First launch shows step 1")
    func firstLaunch() async {
        let (model, _, _) = await model()
        await model.load()
        #expect(model.isLoaded)
        #expect(model.isPresented)
        #expect(model.step == .welcome)
        #expect(!model.showsBanner)
    }

    @Test("Later launch without access shows the access step")
    func missingAccessAtLaunch() async {
        let (model, _, _) = await model(completed: true)
        await model.load()
        #expect(model.isPresented)
        #expect(model.step == .access)
    }

    @Test("Limited scan is remembered: no steps at launch, quiet banner instead")
    func limitedRemembered() async {
        let (model, _, _) = await model(completed: true, limited: true)
        await model.load()
        #expect(!model.isPresented)
        #expect(model.showsBanner)
        model.showAccessSteps()
        #expect(model.isPresented)
        #expect(model.step == .access)
    }

    @Test("Launch with access after completing: no steps, no banner")
    func grantedLaunch() async {
        let (model, _, _) = await model(granted: true, completed: true)
        await model.load()
        #expect(!model.isPresented)
        #expect(!model.showsBanner)
    }

    @Test("Continue with limited scan closes the steps and saves the choice")
    func continueLimited() async {
        let (model, flag, settings) = await model()
        await model.load()
        model.next()
        #expect(model.step == .access)
        model.openSettings()
        model.revealApp()
        #expect(flag.settingsOpened == 1)
        #expect(flag.revealed == 1)
        await model.continueWithLimitedScan()
        #expect(!model.isPresented)
        #expect(model.showsBanner)
        #expect(await settings.bool(.limitedScanChosen))
        #expect(await settings.bool(.onboardingCompleted))
    }

    @Test("Step 1 goes straight to done when access is already on; finish clears limited")
    func nextWithAccess() async {
        let (model, _, settings) = await model(granted: true, limited: true)
        await model.load()
        model.next()
        #expect(model.step == .done)
        await model.finish()
        #expect(!model.isPresented)
        #expect(await settings.bool(.onboardingCompleted))
        #expect(await settings.bool(.limitedScanChosen) == false)
    }

    @Test("Access granted while on step 2 flips to done within 2 s (real 1.5 s poll interval)")
    func flipsWithinTwoSeconds() async throws {
        let (model, flag, _) = await model(poll: Permissions().pollInterval)
        await model.load()
        model.next()
        #expect(model.step == .access)

        let watcher = Task { await model.watchForAccess() }
        defer { watcher.cancel() }
        // Let the first poll see "no access", then grant it just after.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.step == .access)
        flag.granted = true
        let granted = ContinuousClock.now

        while model.step != .done, ContinuousClock.now - granted < .seconds(3) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let elapsed = ContinuousClock.now - granted
        #expect(model.step == .done)
        #expect(model.hasFullDiskAccess)
        #expect(elapsed < .seconds(2), "flipped after \(elapsed)")
    }

    @Test("Watching stops when the steps go away (task cancelled)")
    func watchCancels() async throws {
        let (model, flag, _) = await model()
        await model.load()
        model.next()
        let watcher = Task { await model.watchForAccess() }
        try await Task.sleep(for: .milliseconds(60))
        watcher.cancel()
        await watcher.value
        flag.granted = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.step == .access)
        #expect(!model.hasFullDiskAccess)
    }
}
