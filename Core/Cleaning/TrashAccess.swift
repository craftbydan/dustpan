import Darwin
import Foundation

/// Why an entry in the Trash stays when Dustpan empties it.
enum TrashBlocker: Sendable, Equatable {
    /// Owned by another user or not writable by this one, e.g. an app installed for all users
    /// that Finder put in the Trash with the user's password. Only Finder can delete it.
    case needsFinder
    /// Locked (`uchg`/`schg` or append-only), on the entry or something inside it.
    case locked
    /// macOS refused the delete although the entry looked deletable.
    case failed
}

/// One top-level Trash entry that is (or was) left in the Trash.
struct TrashLeftEntry: Sendable, Equatable {
    let name: String
    let bytes: Int64
    let reason: TrashBlocker
}

/// Decides, before anything is deleted, whether this user can remove a Trash entry completely.
/// An entry Dustpan can't remove whole is never started on, so nothing is left half-deleted.
///
/// Cheap: `lstat`/`access` only, no reads. A file needs the Trash folder writable and must be
/// owned by or writable for this user. A folder must, at every level, be writable and searchable
/// (its children are unlinked from it), carry no lock flag, and obey the sticky bit. The walk is
/// bounded; past `walkLimit` entries it fails closed (`needsFinder`).
enum TrashAccess {
    static let walkLimit = 20_000
    private static let lockFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)

    /// nil when this user can delete `path` (a direct child of `trash`) completely.
    static func blocker(of path: String, inTrash trash: String, uid: uid_t = getuid()) -> TrashBlocker? {
        assertNotMainThread()
        var parent = stat()
        var info = stat()
        guard lstat(trash, &parent) == 0, lstat(path, &info) == 0 else { return .needsFinder }
        if info.st_flags & lockFlags != 0 { return .locked }
        guard parent.st_flags & lockFlags == 0, access(trash, W_OK | X_OK) == 0,
            mayUnlink(child: info, from: parent, uid: uid)
        else { return .needsFinder }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { return nil }  // the link itself goes; its target is never touched
        if info.st_uid != uid && access(path, W_OK) != 0 { return .needsFinder }
        guard type == S_IFDIR else { return nil }
        return folderBlocker(path, info: info, uid: uid)
    }

    /// Walks a folder (no links followed) and returns the first reason its contents can't all go.
    private static func folderBlocker(_ root: String, info: stat, uid: uid_t) -> TrashBlocker? {
        var pending: [(path: String, info: stat)] = [(root, info)]
        var visited = 0
        while let next = pending.popLast() {
            let (folder, folderInfo) = (next.path, next.info)
            if folderInfo.st_flags & lockFlags != 0 { return .locked }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
                return .needsFinder
            }
            guard !names.isEmpty else { continue }
            // Unlinking children needs write + search on the folder itself.
            guard access(folder, W_OK | X_OK) == 0 else { return .needsFinder }
            for name in names {
                visited += 1
                if visited > walkLimit { return .needsFinder }
                let path = folder + "/" + name
                var child = stat()
                guard lstat(path, &child) == 0 else { continue }
                if child.st_flags & lockFlags != 0 { return .locked }
                guard mayUnlink(child: child, from: folderInfo, uid: uid) else { return .needsFinder }
                if child.st_mode & S_IFMT == S_IFDIR { pending.append((path, child)) }
            }
        }
        return nil
    }

    /// The sticky bit: in a sticky folder only the owner of the child or of the folder may unlink.
    private static func mayUnlink(child: stat, from folder: stat, uid: uid_t) -> Bool {
        guard folder.st_mode & S_ISVTX != 0 else { return true }
        return uid == 0 || child.st_uid == uid || folder.st_uid == uid
    }
}
