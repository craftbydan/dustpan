import Foundation
import os

/// The five things a Sweep looks at, in the order the tiles show them.
enum SweepModule: String, CaseIterable, Identifiable, Sendable, Codable {
    case junk, orphans, unusedApps, duplicates, largeOld

    var id: String { rawValue }

    /// Tile label.
    var title: String {
        switch self {
        case .junk: "Junk"
        case .orphans: "Old app leftovers"
        case .unusedApps: "Unused apps"
        case .duplicates: "Copies in Downloads"
        case .largeOld: "Large & old files"
        }
    }

    /// The checklist line while scanning.
    var checklistTitle: String {
        switch self {
        case .junk: "Caches, logs and build files"
        case .orphans: "Files of apps that are gone"
        case .unusedApps: "Apps not opened in 6 months"
        case .duplicates: "Copies in Downloads"
        case .largeOld: "Files over 1 GB untouched for a year"
        }
    }
}

/// What one module found.
enum SweepFinding: Sendable {
    case junk(JunkScanOutput)
    case orphans(LeftoverScan)
    /// Every installed app; the tile counts the unused ones (`AppRecord.unusedBytes`).
    case apps([AppRecord])
    case duplicates(DuplicateScan)
    case largeOld(LargeOldScan)
    /// The module didn't look because it needs Full Disk Access.
    case needsAccess

    /// The tile's figure. Each case uses the same computation as its feature screen.
    func bytes(now: Date) -> Int64 {
        switch self {
        case .junk(let output): output.totalBytes
        case .orphans(let scan): scan.removableBytes
        case .apps(let apps): AppRecord.unusedBytes(apps, now: now)
        case .duplicates(let scan): scan.reclaimableBytes
        case .largeOld(let scan): LargeOldFilter.bytes(LargeOldFilter.sweep.matching(scan.files, now: now))
        case .needsAccess: 0
        }
    }

    /// How many things the tile is about.
    func count(now: Date) -> Int {
        switch self {
        case .junk(let output): output.results.reduce(0) { $0 + $1.items.count }
        case .orphans(let scan): scan.removable.count
        case .apps(let apps): apps.filter { $0.isUnused(now: now) }.count
        case .duplicates(let scan): scan.groups.reduce(0) { $0 + $1.files.count - 1 }
        case .largeOld(let scan): LargeOldFilter.sweep.matching(scan.files, now: now).count
        case .needsAccess: 0
        }
    }
}

/// Where a module is.
enum SweepModuleState: Sendable, Equatable {
    case waiting
    /// Fraction done, when the module can tell.
    case running(Double?)
    case finished
    case needsAccess
    /// It stopped with a problem; the rest of the Sweep goes on.
    case failed(String)
    case cancelled

    var isDone: Bool {
        switch self {
        case .waiting, .running: false
        case .finished, .needsAccess, .failed, .cancelled: true
        }
    }
}

struct SweepEvent: Sendable, Equatable {
    let module: SweepModule
    let state: SweepModuleState
}

/// One module of a Sweep. Real ones wrap the feature scanners; tests use mocks.
///
/// `run` must return (or throw) soon after its task is cancelled: every scanner it calls checks
/// `Task.isCancelled` at least every thousand or so files.
protocol SweepScanner: Sendable {
    var module: SweepModule { get }
    func run(hasFullDiskAccess: Bool, progress: @escaping @Sendable (Double?) -> Void) async throws -> SweepFinding
}

/// What a Sweep produced.
struct SweepOutcome: Sendable {
    var findings: [SweepModule: SweepFinding] = [:]
    var states: [SweepModule: SweepModuleState] = [:]
    var seconds: [SweepModule: TimeInterval] = [:]
    var wasCancelled = false
    var totalSeconds: TimeInterval = 0
}

/// Runs every module at once (`withTaskGroup`), streams each module's state, and stops them
/// all when its task is cancelled. A module that fails is reported and the others carry on.
actor ScanCoordinator {
    private let scanners: [any SweepScanner]
    private let logger = Logger(subsystem: "app.dustpan", category: "sweep")

    init(scanners: [any SweepScanner]) {
        self.scanners = scanners
    }

    var modules: [SweepModule] { scanners.map(\.module) }

    /// Runs the Sweep. Cancel the calling task to stop every module; the outcome then has
    /// `wasCancelled` set and no findings for the modules that hadn't finished.
    /// `only` limits the run to some modules (e.g. Junk again after an Undo).
    func sweep(
        hasFullDiskAccess: Bool, only: Set<SweepModule>? = nil, events: AsyncStream<SweepEvent>.Continuation? = nil
    ) async -> SweepOutcome {
        defer { events?.finish() }
        let started = ContinuousClock.now
        var outcome = SweepOutcome()
        let scanners = scanners.filter { only?.contains($0.module) ?? true }
        for scanner in scanners {
            outcome.states[scanner.module] = .waiting
            events?.yield(SweepEvent(module: scanner.module, state: .waiting))
        }
        await withTaskGroup(of: (SweepModule, SweepModuleState, SweepFinding?, TimeInterval).self) { group in
            for scanner in scanners {
                group.addTask {
                    await Self.runModule(scanner, hasFullDiskAccess: hasFullDiskAccess, events: events)
                }
            }
            for await (module, state, finding, seconds) in group {
                outcome.states[module] = state
                outcome.seconds[module] = seconds
                if let finding { outcome.findings[module] = finding }
            }
        }
        outcome.wasCancelled = Task.isCancelled
        if outcome.wasCancelled {
            // A cancelled Sweep keeps nothing: partial results would understate the tiles.
            outcome.findings = [:]
        }
        outcome.totalSeconds = Self.seconds(since: started)
        logger.info(
            """
            Sweep \(outcome.wasCancelled ? "cancelled" : "finished", privacy: .public) in \
            \(outcome.totalSeconds, privacy: .public) s
            """)
        return outcome
    }

    private static func runModule(
        _ scanner: any SweepScanner, hasFullDiskAccess: Bool, events: AsyncStream<SweepEvent>.Continuation?
    ) async -> (SweepModule, SweepModuleState, SweepFinding?, TimeInterval) {
        let module = scanner.module
        let started = ContinuousClock.now
        events?.yield(SweepEvent(module: module, state: .running(nil)))
        let state: SweepModuleState
        var finding: SweepFinding?
        do {
            let found = try await scanner.run(hasFullDiskAccess: hasFullDiskAccess) { fraction in
                events?.yield(SweepEvent(module: module, state: .running(fraction)))
            }
            try Task.checkCancellation()
            if case .needsAccess = found {
                state = .needsAccess
            } else {
                state = .finished
                finding = found
            }
        } catch is CancellationError {
            state = .cancelled
        } catch {
            state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            if !Task.isCancelled {
                Logger(subsystem: "app.dustpan", category: "sweep")
                    .error(
                        "Sweep module \(module.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .private)"
                    )
            }
        }
        events?.yield(SweepEvent(module: module, state: state))
        return (module, state, finding, seconds(since: started))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
