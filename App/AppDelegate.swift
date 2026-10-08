import AppKit
import LaunchAtLogin
@preconcurrency import UserNotifications

/// Owns the app's state and handles what only an app delegate can: launch (login item, menu-bar
/// start-up), clicked notifications, and the Dock icon when the main window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appState = AppState()
    private var closeObserver: (any NSObjectProtocol)?

    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        // Checked here, as LaunchAtLogin requires. DEBUG `-simulateLoginLaunch YES` takes the same path.
        var launchedAtLogin = LaunchAtLogin.wasLaunchedAtLogin
        #if DEBUG
            if UserDefaults.standard.bool(forKey: "simulateLoginLaunch") { launchedAtLogin = true }
        #endif
        UNUserNotificationCenter.current().delegate = self

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                MainWindow.windowWillClose(window, menuBarOn: self?.appState.settingsModel.showInMenuBar ?? false)
            }
        }

        let appState = appState
        Task {
            await appState.settingsModel.load()
            appState.menuBar.start()
            if launchedAtLogin, appState.settingsModel.showInMenuBar {
                MainWindow.closeAllForMenuBar()
            }
        }
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, MainWindow.openWindows.isEmpty {
            MainWindow.present(opener: appState.windowOpener)
            return false
        }
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run { appState.handleNotification(identifier: identifier) }
    }

    /// Show Dustpan's notifications even while Dustpan is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
