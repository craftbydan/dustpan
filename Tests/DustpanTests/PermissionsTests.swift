import Foundation
import Testing
import os

@testable import Dustpan

@Suite("Permissions")
struct PermissionsTests {
    @Test("Deep link is the Full Disk Access pane")
    func deepLink() {
        #expect(
            Permissions.fullDiskAccessSettingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    @Test("Real poller defaults to 1.5 s")
    func defaultInterval() {
        #expect(Permissions().pollInterval == .milliseconds(1500))
    }

    @Test("Paths that need Full Disk Access are recognised, wildcards included")
    func accessPaths() {
        for path in [
            "~/.Trash", "~/Downloads", "~/Desktop", "~/Library/Containers/com.docker.docker/Data/vms",
            "~/Library/Containers/*/Data/Library/Caches", "~/library/safari", "~/Library/*/com.example",
            "~/Library/Application Support/Code/CachedData", "~/Library/Application Support/Google/Chrome/*/GPUCache",
            "~/Library/CloudStorage/Dropbox", "~/Library/Group Containers/x.group",
        ] {
            #expect(FullDiskAccessPaths.requiresAccess(path), "\(path)")
        }
        for path in [
            "~", "~/Library/Caches", "~/Library/Logs", "~/.cache/uv", "~/Library/Developer/Xcode/DerivedData",
            "~/Library", "~/Library/Caches/com.spotify.client", "~/Library/Caches/Google/Chrome",
        ] {
            #expect(!FullDiskAccessPaths.requiresAccess(path), "\(path)")
        }
    }

    @Test("waitForFullDiskAccess yields the current value, then the change, then finishes")
    func pollingStream() async {
        let flag = AccessFlag()
        let permissions = Permissions(pollInterval: .milliseconds(20), check: { flag.granted })
        var seen: [Bool] = []
        for await value in permissions.waitForFullDiskAccess() {
            seen.append(value)
            if seen.count == 1 { flag.granted = true }
        }
        #expect(seen == [false, true])
    }

    @Test("Polling stops when the consumer is cancelled")
    func pollingStopsOnCancel() async {
        let checks = AccessFlag()
        let counter = Counter()
        let permissions = Permissions(
            pollInterval: .milliseconds(10),
            check: {
                counter.increment()
                return checks.granted
            })
        let task = Task {
            for await _ in permissions.waitForFullDiskAccess() {}
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await task.value
        try? await Task.sleep(for: .milliseconds(50))
        let afterCancel = counter.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == afterCancel)
    }
}

final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
