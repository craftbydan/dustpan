import SwiftUI

/// The screens in the sidebar, in order.
enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case sweep, junk, apps, spaceMap, clutter, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sweep: "Sweep"
        case .junk: "Junk"
        case .apps: "Apps"
        case .spaceMap: "Space map"
        case .clutter: "Clutter"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var tone: Tone {
        switch self {
        case .sweep: .sweep
        case .junk: .dev
        case .apps: .apps
        case .spaceMap: .spaceMap
        case .clutter: .clutter
        case .history: .history
        case .settings: .settings
        }
    }

    /// Sections above the divider do the work; the ones below look after it.
    static let tools: [AppSection] = [.sweep, .junk, .apps, .spaceMap, .clutter]
    static let housekeeping: [AppSection] = [.history, .settings]
}
