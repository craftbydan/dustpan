import Foundation
import os

/// What a sample reads: everything while the popover is open, only the disk otherwise.
enum SampleScope: Sendable, Equatable {
    case diskOnly
    case full
}

/// Takes one sample. Synchronous: `SystemMonitor` calls it from its own executor, off the main actor.
protocol SystemSampling: AnyObject {
    func sample(_ scope: SampleScope) -> SystemSample
    /// Takes a baseline for the delta readers (CPU, network) without reporting anything.
    func prime()
    /// Forgets the delta readers' baselines (they'd be stale by the next open).
    func reset()
}

/// The real readers (see `SystemReaders.swift`).
final class LiveSystemSampler: SystemSampling {
    private let cpu = CPUReader()
    private let memory = MemoryReader()
    private let network = NetworkReader()
    private let volume: URL
    private let logger = Logger(subsystem: "app.dustpan", category: "monitor")

    init(volume: URL = URL(fileURLWithPath: "/")) {
        self.volume = volume
    }

    func sample(_ scope: SampleScope) -> SystemSample {
        assertNotMainThread()
        var sample = SystemSample(date: Date())
        do {
            sample.disk = try DiskSpace.readNow(for: volume)
        } catch {
            logger.error("Free space read failed: \(error.localizedDescription, privacy: .private)")
        }
        guard scope == .full else { return sample }
        sample.cpu = cpu.read()
        sample.memory = memory.read()
        sample.battery = BatteryReader.read()
        sample.network = network.read()
        return sample
    }

    func prime() {
        _ = cpu.read()
        _ = network.read()
    }

    func reset() {
        cpu.reset()
        network.reset()
    }
}

/// Samples the system for the menu-bar item.
///
/// Popover closed: one disk-only sample every 60 s (the label and the low-disk check), with a
/// generous timer tolerance so macOS can batch the wake-up. Popover open: a full sample every 2 s.
/// Opening takes a CPU/network baseline, waits `warmUp`, then reports, so the gauges fill quickly.
actor SystemMonitor {
    static let openInterval: Duration = .seconds(2)
    static let closedInterval: Duration = .seconds(60)
    static let warmUp: Duration = .milliseconds(500)

    /// Sleeps for a duration; throws when the task is cancelled. Injected so tests drive time.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let liveSleep: Sleep = { duration in
        let tolerance: Duration = duration >= closedInterval ? .seconds(10) : .milliseconds(200)
        try await Task.sleep(for: duration, tolerance: tolerance)
    }

    nonisolated let samples: AsyncStream<SystemSample>
    private let continuation: AsyncStream<SystemSample>.Continuation
    private let sampler: any SystemSampling
    private let sleep: Sleep
    private(set) var isOpen = false
    private var loop: Task<Void, Never>?
    private var generation = 0

    init(sampler: sending any SystemSampling = LiveSystemSampler(), sleep: @escaping Sleep = SystemMonitor.liveSleep) {
        self.sampler = sampler
        self.sleep = sleep
        (samples, continuation) = AsyncStream.makeStream(of: SystemSample.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts sampling (closed cadence until told otherwise). Safe to call more than once.
    func start() {
        guard loop == nil else { return }
        restart()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        generation += 1
    }

    /// The popover opened or closed: switch cadence and sample straight away.
    func setPopoverOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if !open { sampler.reset() }
        if loop != nil { restart() }
    }

    private func restart() {
        loop?.cancel()
        generation += 1
        let current = generation
        loop = Task { [weak self] in await self?.run(generation: current) }
    }

    private func run(generation current: Int) async {
        do {
            if isOpen {
                sampler.prime()
                try await sleep(Self.warmUp)
            }
            while !Task.isCancelled, current == generation {
                let open = isOpen
                let sample = sampler.sample(open ? .full : .diskOnly)
                guard !Task.isCancelled, current == generation else { return }
                continuation.yield(sample)
                try await sleep(open ? Self.openInterval : Self.closedInterval)
            }
        } catch {
            // Cancelled: a newer loop (or stop) took over.
        }
    }
}
