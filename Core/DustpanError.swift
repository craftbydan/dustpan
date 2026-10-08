import Foundation

/// Every error Dustpan surfaces to the user.
enum DustpanError: LocalizedError, Equatable {
    case databaseUnavailable
    case diskSpaceUnavailable
    /// The bundled cleaning rules failed to load or validate. The detail is for logs only.
    case rulesInvalid(String)
    /// The Trash folder couldn't be read (usually: no Full Disk Access).
    case trashUnreadable
    /// Empty Trash removed nothing.
    case trashNotEmptied
    /// Items moved to the Trash but the history entry couldn't be written.
    case cleanupNotLogged
    /// Some items couldn't be put back (detail is the count).
    case putBackFailed(Int)
    /// The ignore list couldn't be saved.
    case ignoreNotSaved
    /// An app asked to quit before uninstalling is still open (detail: its name).
    case appDidNotQuit(String)
    /// Space map: the Cleaner refused to move something (detail: its plain-words reason).
    case notMoved(String)
    /// Duplicates: a chosen folder is outside the home folder, in ~/Library or in the Trash.
    case folderNotAllowed
    /// Sweep: some modules couldn't finish (detail: their tile names).
    case sweepPartly([String])

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            "Dustpan couldn't open its history file, so cleanups won't be logged this session."
        case .diskSpaceUnavailable:
            "Dustpan couldn't read how much space is free on this Mac."
        case .rulesInvalid:
            "Dustpan's cleaning rules didn't load, so it can't look for junk right now."
        case .trashUnreadable:
            "Dustpan can't look inside the Trash without Full Disk Access. You can empty it from Finder."
        case .trashNotEmptied:
            "macOS didn't let Dustpan empty the Trash. You can empty it from Finder."
        case .cleanupNotLogged:
            "Everything went to the Trash, but History couldn't record it. You can still put things back from Finder's Trash."
        case .putBackFailed(let count):
            count == 1
                ? "1 item couldn't be put back. History shows why."
                : "\(count) items couldn't be put back. History shows why."
        case .ignoreNotSaved:
            "Dustpan couldn't save that to the ignore list."
        case .appDidNotQuit(let name):
            "\(name) is still open. Save your work there, quit it, then try again."
        case .notMoved(let reason):
            "Not moved. \(reason)"
        case .folderNotAllowed:
            "Dustpan looks for duplicates only in your own folders: inside your home folder, but not in Library or the Trash."
        case .sweepPartly(let names):
            "\(ListFormatter.localizedString(byJoining: names)) couldn't be checked this time. The rest of the Sweep is complete."
        }
    }
}
