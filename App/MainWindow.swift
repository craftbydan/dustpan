import AppKit
import SwiftUI

/// The main window's AppKit side: finding it, bringing it forward, and the Dock icon.
///
/// With the menu-bar item on, closing the main window keeps Dustpan running in the menu bar and
/// hides its Dock icon (activation policy `.accessory`); opening the window again (popover,
/// notification) brings the Dock icon back. With the item off nothing changes: Dustpan behaves
/// like any app, and ⌘Q / Quit always quit.
@MainActor
enum MainWindow {
    static let sceneID = "main"
    /// Windows that host `RootView` (registered by `MainWindowTracker`).
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    static func register(_ window: NSWindow) {
        windows.add(window)
    }

    static var openWindows: [NSWindow] {
        windows.allObjects.filter { $0.isVisible || $0.isMiniaturized }
    }

    static func present(opener: (@MainActor () -> Void)?) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if let window = openWindows.first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
        NSApp.activate()
    }

    /// A main window is closing: with the menu-bar item on and no other main window left,
    /// tuck the app into the menu bar.
    static func windowWillClose(_ window: NSWindow, menuBarOn: Bool) {
        guard windows.contains(window), menuBarOn else { return }
        if openWindows.allSatisfy({ $0 === window }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Hides every main window (launched at login with the menu-bar item on).
    static func closeAllForMenuBar() {
        for window in openWindows { window.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// The menu-bar item went away: Dustpan must not be left with no window and no Dock icon.
    static func menuBarTurnedOff(opener: (@MainActor () -> Void)?) {
        guard NSApp.activationPolicy() != .regular else { return }
        present(opener: opener)
    }
}

/// Registers the window it's placed in as a main window.
struct MainWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackerView { TrackerView() }
    func updateNSView(_ nsView: TrackerView, context: Context) {}

    final class TrackerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.register(window) }
        }
    }
}
