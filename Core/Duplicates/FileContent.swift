import Darwin
import Foundation

/// What `lstat` says about one path. Reading it never opens the file, so it never makes a
/// cloud placeholder download.
struct FileFacts: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    /// Logical length in bytes.
    let size: Int64
    /// Bytes allocated on disk (`st_blocks` × 512).
    let allocated: Int64
    let flags: UInt32
    let linkCount: UInt16
    let modified: Date
    let created: Date
    let isRegularFile: Bool
    let isSymlink: Bool

    /// `SF_DATALESS` (sys/stat.h): the file's data lives in the cloud, and reading it would
    /// download it.
    static let datalessFlag: UInt32 = 0x4000_0000

    var isDataless: Bool { flags & Self.datalessFlag != 0 }

    /// `lstat` of `path`; nil when it doesn't exist.
    static func read(_ path: String) -> FileFacts? {
        assertNotMainThread()
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileFacts(info)
    }

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = Int64(info.st_size)
        allocated = Int64(info.st_blocks) * 512
        flags = info.st_flags
        linkCount = info.st_nlink
        modified = Self.date(info.st_mtimespec)
        created = Self.date(info.st_birthtimespec)
        let type = info.st_mode & S_IFMT
        isRegularFile = type == S_IFREG
        isSymlink = type == S_IFLNK
    }

    /// One file on disk: device and inode.
    struct FileID: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    var fileID: FileID { FileID(device: device, inode: inode) }

    /// Same file on disk (same device and inode): hard links of one file are not duplicates.
    func isSameFile(as other: FileFacts) -> Bool { fileID == other.fileID }

    /// Same file, same length, same modification time: nothing changed since `other` was read.
    func isUnchanged(since other: FileFacts) -> Bool {
        isSameFile(as: other) && size == other.size && modified == other.modified && isRegularFile
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

/// Whether a file is only a placeholder for something stored in iCloud Drive or another cloud
/// provider. Injected so tests can pretend.
protocol CloudStatusChecking: Sendable {
    /// True when the file's content isn't fully on this Mac. Must not read the file.
    func isCloudOnly(_ url: URL, facts: FileFacts) -> Bool
}

/// The real check: the dataless flag from `lstat`, then (for iCloud items) the downloading
/// status. Neither reads the file's content, so neither starts a download.
struct SystemCloudStatus: CloudStatusChecking {
    func isCloudOnly(_ url: URL, facts: FileFacts) -> Bool {
        if facts.isDataless { return true }
        guard
            let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ]),
            values.isUbiquitousItem == true
        else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }
}

/// Reads file contents for duplicate checks. Every open uses `O_NOFOLLOW_ANY` (no link
/// anywhere on the path; the stricter form of `O_NOFOLLOW`, which it can't be combined with) and is re-checked with `fstat` against the facts seen earlier (same
/// file, same length, still a regular file, not a cloud placeholder) before a byte is read.
enum FileContent {
    /// Size of the first and last samples.
    static let sampleSize = 16 * 1_024
    /// Read buffer for full hashes and comparisons.
    static let bufferSize = 1 << 20

    /// Opens `path` read-only, or nil when it isn't the file `expected` describes.
    static func open(_ path: String, expected: FileFacts) -> Int32? {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            return nil
        }
        let now = FileFacts(info)
        guard now.isRegularFile, now.isSameFile(as: expected), now.size == expected.size, !now.isDataless else {
            close(fd)
            return nil
        }
        // Big sequential reads that won't be needed again: keep them out of the file cache.
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }

    /// XXH3 of `length` bytes at `offset` (clamped to the file), or nil when unreadable.
    static func sampleHash(_ path: String, facts: FileFacts, fromEnd: Bool) -> UInt64? {
        guard let fd = open(path, expected: facts) else { return nil }
        defer { close(fd) }
        let length = Int(min(Int64(sampleSize), facts.size))
        let offset = fromEnd ? facts.size - Int64(length) : 0
        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes { readFully(fd, into: $0, at: offset) }
        guard read == length else { return nil }
        return buffer.withUnsafeBytes { XXHash.hash64($0) }
    }

    /// Streaming XXH3 of the whole file in 1 MB reads. Throws `CancellationError` when the task
    /// is cancelled; nil when the file can't be read in full.
    static func fullHash(_ path: String, facts: FileFacts) throws -> UInt64? {
        guard let fd = open(path, expected: facts) else { return nil }
        defer { close(fd) }
        let stream = XXHash.Stream()
        guard stream.isValid else { return nil }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var offset: Int64 = 0
        while offset < facts.size {
            try Task.checkCancellation()
            let want = Int(min(Int64(bufferSize), facts.size - offset))
            let got = readFully(fd, into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<want]), at: offset)
            guard got == want else { return nil }
            stream.update(UnsafeRawBufferPointer(rebasing: buffer[0..<got]))
            offset += Int64(got)
        }
        return stream.digest()
    }

    /// Reads `a` and `b` side by side: true only when they are byte-for-byte the same and their
    /// XXH3 equals `expectedHash`. Used by the Cleaner right before trashing a duplicate.
    static func isIdentical(
        _ a: String, _ aFacts: FileFacts, to b: String, _ bFacts: FileFacts, expectedHash: UInt64
    )
        -> Bool
    {
        guard aFacts.size == bFacts.size, let fa = open(a, expected: aFacts) else { return false }
        defer { close(fa) }
        guard let fb = open(b, expected: bFacts) else { return false }
        defer { close(fb) }
        let stream = XXHash.Stream()
        guard stream.isValid else { return false }
        let bufA = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
        let bufB = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer {
            bufA.deallocate()
            bufB.deallocate()
        }
        var offset: Int64 = 0
        while offset < aFacts.size {
            let want = Int(min(Int64(bufferSize), aFacts.size - offset))
            let sliceA = UnsafeMutableRawBufferPointer(rebasing: bufA[0..<want])
            let sliceB = UnsafeMutableRawBufferPointer(rebasing: bufB[0..<want])
            guard readFully(fa, into: sliceA, at: offset) == want, readFully(fb, into: sliceB, at: offset) == want,
                memcmp(sliceA.baseAddress, sliceB.baseAddress, want) == 0
            else { return false }
            stream.update(UnsafeRawBufferPointer(sliceA))
            offset += Int64(want)
        }
        // Nothing was appended since: both still end where they ended.
        var extra: UInt8 = 0
        guard pread(fa, &extra, 1, off_t(offset)) == 0, pread(fb, &extra, 1, off_t(offset)) == 0 else { return false }
        return stream.digest() == expectedHash
    }

    /// `pread` until `buffer` is full or the file ends (retries on EINTR). Returns bytes read,
    /// or -1 on error.
    private static func readFully(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        var total = 0
        while total < buffer.count {
            let n = pread(fd, base + total, buffer.count - total, off_t(offset) + off_t(total))
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if n == 0 { break }
            total += n
        }
        return total
    }
}
