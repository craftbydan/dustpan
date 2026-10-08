import MenuBarExtraAccess
import SwiftUI

@main
struct DustpanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var appState: AppState { appDelegate.appState }

    init() {
        _ = FontRegistry.isRegistered
        #if DEBUG
            // `-appearance light|dark` forces an appearance (for screenshots).
            switch UserDefaults.standard.string(forKey: "appearance") {
            case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        #endif
    }

    var body: some Scene {
        WindowGroup("Dustpan", id: MainWindow.sceneID) {
            mainContent
                .frame(minWidth: Metric.windowMin.width, minHeight: Metric.windowMin.height)
                .background(MainWindowTracker())
                .environment(appState)
                .modifier(WindowOpenerCapture(appState: appState))
        }
        .defaultSize(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
        .windowStyle(.hiddenTitleBar)
        .commands { SweepCommands(appState: appState) }
        #if DEBUG
            .commands { DebugCommands() }
        #endif

        menuBarExtra

        #if DEBUG
            Window("Design Preview", id: DebugCommands.designPreviewID) {
                DesignPreview()
                    .frame(minWidth: Metric.windowMin.width, minHeight: Metric.windowMin.height)
            }
        #endif
    }

    /// The optional menu-bar item (Settings › Show in menu bar). Off by default; when it's off
    /// the item isn't inserted and nothing but the 60 s free-space read runs.
    private var menuBarExtra: some Scene {
        let appState = appState
        let settings = appState.settingsModel
        let menuBar = appState.menuBar
        return MenuBarExtra(
            isInserted: Binding(
                get: { settings.showInMenuBar },
                set: { on in
                    // Removed by ⌘-dragging it out of the menu bar: treat it as turning the setting off.
                    if !on { Task { await appState.setShowInMenuBar(false) } }
                })
        ) {
            MenuBarPopover(
                model: menuBar,
                thresholdBytes: settings.lowDiskThresholdBytes,
                sweepNow: {
                    menuBar.isPresented = false
                    appState.showSweep(start: true)
                },
                openDustpan: {
                    menuBar.isPresented = false
                    appState.showSweep(start: false)
                },
                quit: { NSApp.terminate(nil) }
            )
            .modifier(WindowOpenerCapture(appState: appState))
        } label: {
            MenuBarLabel(model: menuBar)
                .modifier(WindowOpenerCapture(appState: appState))
        }
        .menuBarExtraAccess(isPresented: Binding(get: { menuBar.isPresented }, set: { menuBar.isPresented = $0 }))
        .menuBarExtraStyle(.window)
    }

    @ViewBuilder
    private var mainContent: some View {
        #if DEBUG
            // `-designPreview YES` shows the design sheet instead of the app (for screenshots).
            if UserDefaults.standard.bool(forKey: "designPreview") {
                DesignPreview()
                    .task { if DebugSnapshot.directory != nil { await DebugSnapshot.writeDesignSheet() } }
            } else {
                RootView()
            }
        #else
            RootView()
        #endif
    }
}

/// Gives `AppState` a way to open a fresh main window from anywhere (popover, notification),
/// using the first SwiftUI view that appears.
private struct WindowOpenerCapture: ViewModifier {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard appState.windowOpener == nil else { return }
            let openWindow = openWindow
            appState.windowOpener = { openWindow(id: MainWindow.sceneID) }
        }
    }
}

/// ⌘R starts a Sweep from anywhere in the window (Esc stops it, from the Sweep screen).
private struct SweepCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Sweep") {
                appState.section = .sweep
                appState.sweep.start()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState.sweep.isScanning || appState.sweep.isCleaning || appState.onboarding.isPresented)
        }
    }
}

#if DEBUG
    private struct DebugCommands: Commands {
        static let designPreviewID = "design-preview"
        @Environment(\.openWindow) private var openWindow

        var body: some Commands {
            CommandMenu("Debug") {
                Button("Design Preview") { openWindow(id: Self.designPreviewID) }
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            }
        }
    }
#endif
