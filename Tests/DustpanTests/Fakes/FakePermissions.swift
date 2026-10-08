import Foundation
import os

@testable import Dustpan

/// Thread-safe switch standing in for the Full Disk Access state.
final class AccessFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (granted: false, opened: 0, revealed: 0))

    init(granted: Bool = false) { state.withLock { $0.granted = granted } }

    var granted: Bool {
        get { state.withLock { $0.granted } }
        set { state.withLock { $0.granted = newValue } }
    }
    var settingsOpened: Int { state.withLock { $0.opened } }
    var revealed: Int { state.withLock { $0.revealed } }
    func noteOpened() { state.withLock { $0.opened += 1 } }
    func noteRevealed() { state.withLock { $0.revealed += 1 } }
}

/// A `PermissionsChecking` that never touches System Settings or the real TCC state.
/// Polling uses the real `Permissions` loop with an injected check.
struct FakePermissions: PermissionsChecking {
    let flag: AccessFlag
    var pollInterval: Duration = .milliseconds(20)

    func hasFullDiskAccess() -> Bool { flag.granted }

    func waitForFullDiskAccess() -> AsyncStream<Bool> {
        let flag = flag
        return Permissions(pollInterval: pollInterval, check: { flag.granted }).waitForFullDiskAccess()
    }

    @MainActor func openFullDiskAccessSettings() { flag.noteOpened() }
    @MainActor func revealAppInFinder() { flag.noteRevealed() }
}
