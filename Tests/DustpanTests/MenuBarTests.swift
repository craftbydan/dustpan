import Foundation
import Testing
import UserNotifications

@testable import Dustpan

/// Prompt 13: menu-bar gauge, settings, weekly reminder, low-disk alert. Every test uses fakes
/// for the login item and the notification center: nothing here registers a login item, asks
/// for notification permission or schedules a real notification.
@Suite("Menu bar & reminders")
struct MenuBarTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DustpanTests-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Sampling cadence

    @Test("Closed: a disk-only sample every 60 s; open: warm-up, then a full sample every 2 s")
    func cadence() async throws {
        let clock = FakeClock()
        let sampler = FakeSampler()
        let monitor = SystemMonitor(sampler: sampler, sleep: clock.sleep)
        var received = monitor.samples.makeAsyncIterator()

        await monitor.start()
        await clock.waitForSleeps(1)
        #expect(sampler.scopes == [.diskOnly])
        #expect(clock.durations == [.seconds(60)])
        #expect(await received.next()?.cpu == nil)

        clock.advance()
        await clock.waitForSleeps(2)
        #expect(sampler.scopes == [.diskOnly, .diskOnly])
        #expect(clock.durations == [.seconds(60), .seconds(60)])

        // Opening cancels the 60 s wait at once: baseline, 0.5 s warm-up, then full samples every 2 s.
        await monitor.setPopoverOpen(true)
        await clock.waitForSleeps(3)
        #expect(sampler.primes == 1)
        #expect(clock.durations.last == SystemMonitor.warmUp)
        clock.advance()
        await clock.waitForSleeps(4)
        #expect(sampler.scopes.last == .full)
        #expect(clock.durations.last == .seconds(2))
        clock.advance()
        await clock.waitForSleeps(5)
        #expect(sampler.scopes.suffix(2) == [.full, .full])
        #expect(clock.durations.last == .seconds(2))

        // Closing: delta readers forgotten, back to disk-only every 60 s.
        await monitor.setPopoverOpen(false)
        await clock.waitForSleeps(6)
        #expect(sampler.resets == 1)
        #expect(sampler.scopes.last == .diskOnly)
        #expect(clock.durations.last == .seconds(60))
        #expect(!clock.durations.dropFirst(5).contains { $0 < .seconds(60) })

        await monitor.stop()
        #expect(clock.parked == 0)
        let total = sampler.scopes.count
        clock.advance()
        try await Task.sleep(for: .milliseconds(50))
        #expect(sampler.scopes.count == total)
    }

    @Test("Never wakes more than once a minute while the popover stays closed")
    func closedNeverFast() async {
        let clock = FakeClock()
        let sampler = FakeSampler()
        let monitor = SystemMonitor(sampler: sampler, sleep: clock.sleep)
        await monitor.start()
        for round in 1...5 {
            await clock.waitForSleeps(round)
            clock.advance()
        }
        await clock.waitForSleeps(6)
        await monitor.stop()
        #expect(clock.durations.allSatisfy { $0 == .seconds(60) })
        #expect(sampler.scopes.allSatisfy { $0 == .diskOnly })
        #expect(sampler.primes == 0)
    }

    // MARK: - Real readers (read-only, no prompts)

    @Test("Readers return sane values on this Mac")
    func liveReaders() async throws {
        let cpu = CPUReader()
        #expect(cpu.read() == nil)  // a baseline first
        var busy = 0.0
        for _ in 0..<200_000 { busy += Double.random(in: 0...1) }
        try await Task.sleep(for: .milliseconds(250))
        let share = try #require(cpu.read())
        #expect((0...1).contains(share))
        #expect(busy > 0)

        let memory = try #require(MemoryReader().read())
        #expect(memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.usedBytes > 0)
        #expect(memory.usedBytes <= memory.totalBytes)
        #expect((0...1).contains(memory.usedFraction))

        if let battery = BatteryReader.read() {
            #expect((0...1).contains(battery.level))
            if let health = battery.healthPercent { #expect((1...100).contains(health)) }
            if let cycles = battery.cycles { #expect(cycles >= 0) }
        }

        let network = NetworkReader()
        #expect(network.read() == nil)
        try await Task.sleep(for: .milliseconds(200))
        let rate = try #require(network.read())
        #expect(rate.bytesInPerSecond >= 0)
        #expect(rate.bytesOutPerSecond >= 0)

        let sampler = LiveSystemSampler()
        let closed = await Task.detached { sampler.sample(.diskOnly) }.value
        let disk = try #require(closed.disk)
        #expect(disk.availableBytes > 0)
        #expect(disk.availableBytes <= disk.totalBytes)
        #expect(closed.cpu == nil)
        #expect(closed.memory == nil)
        #expect(closed.network == nil)
    }

    @Test("CPU share from tick deltas, wrapping counters included")
    func cpuMath() {
        let stride = Int(CPU_STATE_MAX)
        var before = [Int32](repeating: 0, count: stride * 2)
        var after = before
        // Core 0: 30 user, 10 system, 60 idle. Core 1: counters wrap; 50 user, 50 idle.
        after[Int(CPU_STATE_USER)] = 30
        after[Int(CPU_STATE_SYSTEM)] = 10
        after[Int(CPU_STATE_IDLE)] = 60
        before[stride + Int(CPU_STATE_USER)] = Int32(bitPattern: UInt32.max - 9)
        after[stride + Int(CPU_STATE_USER)] = 40
        after[stride + Int(CPU_STATE_IDLE)] = 50
        let share = CPUReader.busyShare(previous: before, current: after, cpus: 2)
        #expect(share == 0.45)
        #expect(CPUReader.busyShare(previous: before, current: before, cpus: 2) == nil)
    }

    @Test("Network counters: a wrap is counted, a reset skips that interface")
    func networkCounters() {
        #expect(NetworkReader.counterDelta(old: 1_000, new: 5_000) == 4_000)
        #expect(NetworkReader.counterDelta(old: 7, new: 7) == 0)
        // Wrapped from near the top: 10 bytes before the wrap + 20 after.
        #expect(NetworkReader.counterDelta(old: UInt32.max - 9, new: 20) == 30)
        // Went down from the lower half: the interface was reset, not a 4 GB burst.
        #expect(NetworkReader.counterDelta(old: 1_000_000, new: 500) == nil)
    }

    @Test("Gauge text: numeric zero rates, RAM in memory units")
    @MainActor
    func gaugeFormatting() {
        #expect(MenuBarPopover.rate(0) == "0 KB/s")
        #expect(!MenuBarPopover.rate(0).localizedCaseInsensitiveContains("zero"))
        #expect(MenuBarPopover.rate(1_240_000) == "1.2 MB/s")
        #expect(MenuBarPopover.memory(8_589_934_592) == "8 GB")
        #expect(MenuBarPopover.memory(17_179_869_184) == "16 GB")
    }

    // MARK: - Settings

    @Test("Settings are off by default and survive reopening the database")
    @MainActor
    func settingsPersist() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let login = FakeLoginItem()
        let center = FakeNotificationCenter(permission: .allowed)
        let model = SettingsModel(
            store: SettingsStore(database: try AppDatabase(directory: dir)), loginItem: login, notifications: center)
        await model.load()
        #expect(!model.showInMenuBar)
        #expect(!model.launchAtLogin)
        #expect(!model.reminderOn)
        #expect(!model.lowDiskAlertOn)
        #expect(model.lowDiskThresholdGB == 10)
        #expect(model.lowDiskThresholdBytes == 10_000_000_000)

        await model.setShowInMenuBar(true)
        await model.setLaunchAtLogin(true)
        await model.setReminderOn(true)
        await model.setReminderWeekday(6)
        await model.setReminderTime(hour: 18, minute: 45)
        await model.setLowDiskAlertOn(true)
        await model.setLowDiskThreshold(gigabytes: 25)

        let reopened = SettingsModel(
            store: SettingsStore(database: try AppDatabase(directory: dir)), loginItem: login, notifications: center)
        await reopened.load()
        #expect(reopened.showInMenuBar)
        #expect(reopened.launchAtLogin)
        #expect(reopened.reminderOn)
        #expect(reopened.reminderWeekday == 6)
        #expect(reopened.reminderHour == 18)
        #expect(reopened.reminderMinute == 45)
        #expect(reopened.lowDiskAlertOn)
        #expect(reopened.lowDiskThresholdGB == 25)

        // The login item removed in System Settings: the switch follows the real state.
        login.isEnabled = false
        let third = SettingsModel(
            store: SettingsStore(database: try AppDatabase(directory: dir)), loginItem: login, notifications: center)
        await third.load()
        #expect(!third.launchAtLogin)
    }

    @Test("Turning the menu-bar item off also turns the login item off")
    @MainActor
    func menuBarOffRemovesLoginItem() async {
        let login = FakeLoginItem()
        let model = SettingsModel(
            store: SettingsStore(database: nil), loginItem: login, notifications: FakeNotificationCenter())
        var turnedOff = 0
        model.menuBarTurnedOff = { turnedOff += 1 }
        await model.load()

        // Launch at login is only offered with the item on.
        await model.setLaunchAtLogin(true)
        #expect(!login.isEnabled)
        #expect(login.changes.isEmpty)

        await model.setShowInMenuBar(true)
        await model.setLaunchAtLogin(true)
        #expect(login.isEnabled)
        #expect(model.launchAtLogin)

        await model.setShowInMenuBar(false)
        #expect(!model.showInMenuBar)
        #expect(!login.isEnabled)
        #expect(!model.launchAtLogin)
        #expect(login.changes == [true, false])
        #expect(turnedOff == 1)
    }

    @Test("A login item left on while the menu-bar item is off is removed at launch")
    @MainActor
    func strayLoginItem() async {
        let login = FakeLoginItem()
        login.isEnabled = true
        let model = SettingsModel(
            store: SettingsStore(database: nil), loginItem: login, notifications: FakeNotificationCenter())
        await model.load()
        #expect(!login.isEnabled)
        #expect(login.changes == [false])
        #expect(!model.launchAtLogin)

        // With the item on, a registered login item is kept.
        let kept = FakeLoginItem()
        kept.isEnabled = true
        let forced = SettingsModel(
            store: SettingsStore(database: nil), loginItem: kept, notifications: FakeNotificationCenter(),
            forceMenuBar: true)
        await forced.load()
        #expect(kept.isEnabled)
        #expect(kept.changes.isEmpty)
    }

    @Test("Forcing the menu bar (DEBUG) saves nothing")
    @MainActor
    func forcedMenuBar() async {
        let store = SettingsStore(database: nil)
        let model = SettingsModel(
            store: store, loginItem: FakeLoginItem(), notifications: FakeNotificationCenter(), forceMenuBar: true)
        await model.load()
        #expect(model.showInMenuBar)
        #expect(await store.string(.menuBarEnabled) == nil)
    }

    // MARK: - Reminders

    @Test("The weekly reminder: calendar trigger, repeating, exact copy, opens Sweep")
    @MainActor
    func weeklyReminder() async throws {
        let center = FakeNotificationCenter(permission: .notDetermined, answer: true)
        let model = SettingsModel(
            store: SettingsStore(database: nil), loginItem: FakeLoginItem(), notifications: center)
        await model.load()
        #expect(center.permissionRequests == 0)  // loading never asks
        #expect(center.added.isEmpty)

        await model.setReminderOn(true)
        #expect(center.permissionRequests == 1)
        await model.setReminderWeekday(4)
        await model.setReminderTime(hour: 9, minute: 30)

        let request = try #require(center.added.last)
        #expect(request.identifier == DustpanNotification.weeklyID)
        #expect(request.content.body == "It's been a week. Want to see what's piled up?")
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.weekday == 4)
        #expect(trigger.dateComponents.hour == 9)
        #expect(trigger.dateComponents.minute == 30)
        #expect(trigger.dateComponents.day == nil)
        // Every change replaced the one pending request (same identifier).
        #expect(Set(center.added.map(\.identifier)) == [DustpanNotification.weeklyID])
        #expect(DustpanNotification.section(for: request.identifier) == .sweep)
        #expect(DustpanNotification.section(for: "something.else") == nil)

        await model.setReminderOn(false)
        #expect(center.removed == [DustpanNotification.weeklyID])
        #expect(center.permissionRequests == 1)
    }

    @Test("Notifications refused: the reminder stays off and Settings says why")
    @MainActor
    func reminderRefused() async {
        let center = FakeNotificationCenter(permission: .notDetermined, answer: false)
        let model = SettingsModel(
            store: SettingsStore(database: nil), loginItem: FakeLoginItem(), notifications: center)
        await model.load()
        await model.setReminderOn(true)
        #expect(!model.reminderOn)
        #expect(model.notificationsBlocked)
        #expect(center.added.isEmpty)
        await model.setLowDiskAlertOn(true)
        #expect(!model.lowDiskAlertOn)
        #expect(center.permissionRequests == 1)  // macOS asks once; after that it's System Settings
    }

    // MARK: - Low disk

    @Test("Low-disk alert: only when on and below the threshold, at most once a day")
    func lowDiskRateLimit() async throws {
        let store = SettingsStore(database: nil)
        let center = FakeNotificationCenter(permission: .allowed)
        let clock = ManualDate(Date(timeIntervalSince1970: 1_800_000_000))
        let alert = LowDiskAlert(settings: store, notifications: center, now: { clock.now })
        let low: Int64 = 4_000_000_000

        #expect(await alert.check(availableBytes: low) == false)  // off by default
        await store.set(true, for: .lowDiskEnabled)

        #expect(await alert.check(availableBytes: 50_000_000_000) == false)  // above 10 GB
        #expect(await alert.check(availableBytes: low))
        clock.move(by: 60)
        #expect(await alert.check(availableBytes: low) == false)
        clock.move(by: 22 * 3600)
        #expect(await alert.check(availableBytes: low) == false)
        clock.move(by: 2 * 3600)
        #expect(await alert.check(availableBytes: low))
        #expect(center.added.count == 2)
        let request = try #require(center.added.first)
        #expect(request.identifier == DustpanNotification.lowDiskID)
        #expect(request.trigger == nil)
        #expect(request.content.body.contains("4 GB"))
        #expect(DustpanNotification.section(for: request.identifier) == .sweep)

        // A higher threshold counts at once; permission off means silence (and no prompt).
        await store.set(60, for: .lowDiskThresholdGB)
        clock.move(by: 25 * 3600)
        let denied = FakeNotificationCenter(permission: .denied)
        let quiet = LowDiskAlert(settings: store, notifications: denied, now: { clock.now })
        #expect(await quiet.check(availableBytes: 50_000_000_000) == false)
        #expect(denied.permissionRequests == 0)
        #expect(await alert.check(availableBytes: 50_000_000_000))
    }

    @Test("The menu-bar label is compact and only changes with the free space")
    @MainActor
    func label() async {
        let model = MenuBarModel(
            monitor: SystemMonitor(sampler: FakeSampler(), sleep: FakeClock().sleep),
            lowDisk: LowDiskAlert(settings: SettingsStore(database: nil), notifications: FakeNotificationCenter()))
        #expect(MenuBarModel.compact(214_321_000_000) == "214 GB")
        let disk = DiskSpace(availableBytes: 214_321_000_000, totalBytes: 494_000_000_000)
        await model.apply(SystemSample(date: Date(), disk: disk))
        #expect(model.label == "214 GB")
        #expect(model.cpu == nil)
        #expect(!model.hasFullSample)
        await model.apply(
            SystemSample(
                date: Date(), disk: disk, cpu: 0.3,
                memory: MemoryReading(totalBytes: 100, usedBytes: 50, pressure: .warning)))
        #expect(model.cpu == 0.3)
        #expect(model.memory?.pressure == .warning)
        #expect(model.hasFullSample)
        #expect(model.battery == nil)
    }
}
