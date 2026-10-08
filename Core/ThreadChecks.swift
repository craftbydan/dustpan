import Darwin

/// DEBUG-only guard for file-system entry points: scanning, measuring and cleaning must never
/// run on the main thread (CLAUDE.md "Don't run scans or cleaning on the main actor"). In a
/// DEBUG build (the app, `make test`) a call from the main thread stops at an assertion, so
/// main-thread I/O shows up as a failing test instead of a janky UI. Release builds compile it
/// away.
///
/// `pthread_main_np()` instead of `Thread.isMainThread`, which is unavailable in async code.
@inline(__always)
func assertNotMainThread(_ what: StaticString = #function, file: StaticString = #fileID, line: UInt = #line) {
    #if DEBUG
        if pthread_main_np() != 0 {
            assertionFailure("File I/O on the main thread: \(what)", file: file, line: line)
        }
    #endif
}
