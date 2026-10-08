import Foundation
import os

@testable import Dustpan

/// A Trash that is just a temp folder. Never the real `~/.Trash`.
struct TempTrashMover: TrashMover {
    let trashDirectory: URL

    func trash(_ url: URL) throws -> URL {
        let fm = FileManager.default
        var target = trashDirectory.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = trashDirectory.appendingPathComponent("\(url.lastPathComponent) \(counter)")
            counter += 1
        }
        try fm.moveItem(at: url, to: target)
        return target
    }
}

/// Pretends the listed bundle IDs are running.
struct FakeRunningApps: RunningAppsChecking {
    var running: [String: String] = [:]

    func runningAppName(bundleID: String) -> String? { running[bundleID] }
}
