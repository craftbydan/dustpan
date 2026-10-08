import LaunchAtLogin

/// The "Launch at login" switch, behind a protocol so tests never register a real login item.
@MainActor
protocol LoginItemControlling {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool)
}

/// The real login item, through LaunchAtLogin-Modern (`SMAppService.mainApp`).
@MainActor
struct LaunchAtLoginItem: LoginItemControlling {
    var isEnabled: Bool { LaunchAtLogin.isEnabled }

    func setEnabled(_ enabled: Bool) {
        guard LaunchAtLogin.isEnabled != enabled else { return }
        LaunchAtLogin.isEnabled = enabled
    }
}
