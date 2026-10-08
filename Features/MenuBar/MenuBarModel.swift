import Foundation
import Observation

/// State for the menu-bar item: the free-space label, the popover's gauges, and the open/closed
/// state that sets `SystemMonitor`'s cadence (2 s open, 60 s closed).
@Observable
@MainActor
final class MenuBarModel {
    /// Latest values. Disk is refreshed by every sample; the gauges only by full (open) samples.
    private(set) var disk: DiskSpace?
    private(set) var cpu: Double?
    private(set) var memory: MemoryReading?
    private(set) var battery: BatteryReading?
    private(set) var network: NetworkRate?
    /// True once a full sample came in (the battery reader has run at least once).
    private(set) var hasFullSample = false
    /// The compact menu-bar text, e.g. "214 GB". Only reassigned when it changes, so the label
    /// redraws at most once a minute while the popover is closed.
    private(set) var label = "—"

    /// Bound to MenuBarExtraAccess. Opening or closing switches the monitor's cadence.
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            let open = isPresented
            let monitor = monitor
            Task { await monitor.setPopoverOpen(open) }
        }
    }

    private let monitor: SystemMonitor
    private let lowDisk: LowDiskAlert
    private var consumer: Task<Void, Never>?

    init(monitor: SystemMonitor, lowDisk: LowDiskAlert) {
        self.monitor = monitor
        self.lowDisk = lowDisk
    }

    /// Starts sampling. Runs for the life of the app (closed cadence: one disk read a minute).
    func start() {
        guard consumer == nil else { return }
        let monitor = monitor
        let stream = monitor.samples
        consumer = Task { [weak self] in
            await monitor.start()
            for await sample in stream {
                guard let self else { return }
                await self.apply(sample)
            }
        }
    }

    func apply(_ sample: SystemSample) async {
        if let disk = sample.disk {
            if self.disk != disk { self.disk = disk }
            let text = Self.compact(disk.availableBytes)
            if text != label { label = text }
        }
        if sample.cpu != nil || sample.memory != nil || sample.network != nil {
            cpu = sample.cpu ?? cpu
            memory = sample.memory ?? memory
            network = sample.network ?? network
            battery = sample.battery
            hasFullSample = true
        }
        if let disk = sample.disk {
            await lowDisk.check(availableBytes: disk.availableBytes)
        }
    }

    /// Whole units for the menu bar ("214 GB", "1 TB"), still `ByteCountFormatter(.file)`.
    static func compact(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }

    #if DEBUG
        /// Made-up values for the snapshot of the popover (a laptop on battery, disk under 10 GB).
        func debugShowDemo() {
            disk = DiskSpace(availableBytes: 8_400_000_000, totalBytes: 494_380_000_000)
            label = Self.compact(8_400_000_000)
            cpu = 0.23
            memory = MemoryReading(totalBytes: 17_179_869_184, usedBytes: 11_800_000_000, pressure: .normal)
            battery = BatteryReading(level: 0.76, isCharging: false, isOnPower: false, healthPercent: 91, cycles: 214)
            network = NetworkRate(bytesInPerSecond: 1_240_000, bytesOutPerSecond: 48_000)
            hasFullSample = true
        }
    #endif
}
