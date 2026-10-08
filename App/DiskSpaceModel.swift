import Foundation
import Observation
import os

/// Free-space figure for the startup disk. One instance, owned by `AppState`, feeds both the
/// sidebar footer and the Sweep's disk bar. Refreshed on events only (start, app becomes active,
/// something moved to or out of the Trash, Empty Trash); never on a timer.
@Observable
@MainActor
final class DiskSpaceModel {
    typealias Reader = @Sendable () async throws -> DiskSpace

    private(set) var space: DiskSpace?
    private(set) var failed = false
    /// How many reads were started (tests check that the space-changed signal reaches here).
    private(set) var refreshCount = 0

    private let read: Reader
    private var settleTask: Task<Void, Never>?

    init(read: @escaping Reader = { try await DiskSpace.read() }) {
        self.read = read
    }

    func refresh() async {
        refreshCount += 1
        do {
            space = try await read()
            failed = false
        } catch {
            failed = true
            Logger(subsystem: "app.dustpan", category: "shell")
                .error("Free space read failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// APFS can report freed space a moment late (e.g. after Empty Trash): reads once more after
    /// `delay`. A newer call replaces a pending one.
    func refreshAgain(after delay: Duration = .seconds(2)) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}
