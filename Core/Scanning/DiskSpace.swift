import Foundation

/// Free and total capacity of the startup volume.
struct DiskSpace: Sendable, Equatable {
    /// Space available for important usage (counts purgeable space macOS can reclaim).
    let availableBytes: Int64
    let totalBytes: Int64

    var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }

    /// "214 GB free of 494 GB".
    var summary: String {
        let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(free) free of \(total)"
    }

    /// Reads the volume containing `url` (default: the startup disk). Runs off the main actor.
    @concurrent
    static func read(for url: URL = URL(fileURLWithPath: "/")) async throws -> DiskSpace {
        assertNotMainThread()
        return try readNow(for: url)
    }

    /// The same read, synchronously (for callers already off the main actor, e.g. `SystemMonitor`).
    static func readNow(for url: URL = URL(fileURLWithPath: "/")) throws -> DiskSpace {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else { throw DustpanError.diskSpaceUnavailable }
        return DiskSpace(availableBytes: available, totalBytes: Int64(total))
    }
}
