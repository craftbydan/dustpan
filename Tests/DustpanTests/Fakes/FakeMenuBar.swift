import Foundation
import UserNotifications
import os

@testable import Dustpan

/// A fake clock for `SystemMonitor`: every sleep is recorded and parks until `advance()`.
/// Cancelled sleeps throw, like `Task.sleep`.
final class FakeClock: Sendable {
    private struct State {
        var durations: [Duration] = []
        var waiting: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
        var nextID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var durations: [Duration] { state.withLock { $0.durations } }
    var parked: Int { state.withLock { $0.waiting.count } }

    var sleep: SystemMonitor.Sleep {
        { [self] duration in try await self.park(duration) }
    }

    private func park(_ duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            state.durations.append(duration)
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = Task.isCancelled
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    state.withLock { $0.waiting.append((id, continuation)) }
                }
            }
        } onCancel: {
            let match = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiting.remove(at: index).continuation
            }
            match?.resume(throwing: CancellationError())
        }
    }

    /// Ends every parked sleep.
    func advance() {
        let all = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            defer { state.waiting = [] }
            return state.waiting.map(\.continuation)
        }
        for continuation in all { continuation.resume() }
    }

    /// Waits (in real time, briefly) until `count` sleeps have been requested.
    func waitForSleeps(_ count: Int) async {
        for _ in 0..<500 where durations.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A sampler that records which scope each call asked for.
final class FakeSampler: SystemSampling, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: (scopes: [SampleScope](), primes: 0, resets: 0))

    var scopes: [SampleScope] { calls.withLock { $0.scopes } }
    var primes: Int { calls.withLock { $0.primes } }
    var resets: Int { calls.withLock { $0.resets } }

    func sample(_ scope: SampleScope) -> SystemSample {
        calls.withLock { $0.scopes.append(scope) }
        var sample = SystemSample(
            date: Date(), disk: DiskSpace(availableBytes: 50_000_000_000, totalBytes: 500_000_000_000))
        if scope == .full { sample.cpu = 0.1 }
        return sample
    }

    func prime() { calls.withLock { $0.primes += 1 } }
    func reset() { calls.withLock { $0.resets += 1 } }
}

/// A login item that only remembers a flag (never touches `SMAppService`).
@MainActor
final class FakeLoginItem: LoginItemControlling {
    var isEnabled = false
    private(set) var changes: [Bool] = []

    func setEnabled(_ enabled: Bool) {
        changes.append(enabled)
        isEnabled = enabled
    }
}

/// A notification center that never asks macOS for anything.
final class FakeNotificationCenter: NotificationScheduling, Sendable {
    private struct State {
        var permission: NotificationPermission
        var answer: Bool
        var requests = 0
        var added: [UNNotificationRequest] = []
        var removed: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(permission: NotificationPermission = .notDetermined, answer: Bool = true) {
        state = OSAllocatedUnfairLock(uncheckedState: State(permission: permission, answer: answer))
    }

    var permissionRequests: Int { state.withLock { $0.requests } }
    var added: [UNNotificationRequest] { state.withLockUnchecked { $0.added } }
    var removed: [String] { state.withLock { $0.removed } }

    func permission() async -> NotificationPermission { state.withLock { $0.permission } }

    func requestPermission() async -> Bool {
        state.withLock { state in
            state.requests += 1
            state.permission = state.answer ? .allowed : .denied
            return state.answer
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        state.withLockUnchecked { $0.added.append(request) }
    }

    func removePending(_ identifiers: [String]) async {
        state.withLock { $0.removed += identifiers }
    }
}

/// A clock for `LowDiskAlert` that tests move by hand.
final class ManualDate: Sendable {
    private let value: OSAllocatedUnfairLock<Date>
    init(_ date: Date) { value = OSAllocatedUnfairLock(initialState: date) }
    var now: Date { value.withLock { $0 } }
    func move(by seconds: TimeInterval) { value.withLock { $0 += seconds } }
}
