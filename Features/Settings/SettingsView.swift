import SwiftUI

/// Settings: the menu-bar item, launch at login, a weekly reminder and the low-disk alert.
/// Everything starts off; nothing runs in the background unless it's turned on here.
struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.settingsModel
        Screen(title: "Settings", tone: .settings) {
            VStack(alignment: .leading, spacing: Space.l) {
                if model.notificationsBlocked {
                    QuietBanner(
                        systemImage: "bell.slash",
                        message: "Notifications for Dustpan are turned off, so reminders can't show.",
                        actionTitle: "Open Notification settings",
                        action: Self.openNotificationSettings)
                }
                menuBarCard(model)
                reminderCard(model)
                lowDiskCard(model)
                aboutCard
            }
            .frame(maxWidth: Metric.settingsMaxWidth, alignment: .leading)
        }
    }

    // MARK: - Cards

    private func menuBarCard(_ model: SettingsModel) -> some View {
        SettingsCard(title: "Menu bar", tone: .settings) {
            SettingsRow(
                title: "Show in menu bar",
                detail: "Free space at a glance, with CPU, memory, battery and network when you click it.",
                isOn: binding(model.showInMenuBar) { await appState.setShowInMenuBar($0) })
            SettingsDivider()
            SettingsRow(
                title: "Launch at login",
                detail: model.showInMenuBar
                    ? "Starts quietly in the menu bar when you log in."
                    : "Turn on the menu-bar item first.",
                isOn: binding(model.launchAtLogin) { await model.setLaunchAtLogin($0) }
            )
            .disabled(!model.showInMenuBar)
        }
    }

    private func reminderCard(_ model: SettingsModel) -> some View {
        SettingsCard(title: "Weekly reminder", tone: .sweep) {
            SettingsRow(
                title: "Remind me once a week",
                detail: "A short note to run a Sweep. Clicking it opens Dustpan on Sweep.",
                isOn: binding(model.reminderOn) { await model.setReminderOn($0) })
            SettingsDivider()
            HStack(spacing: Space.m) {
                Text("When").textStyle(.body)
                Spacer(minLength: Space.s)
                Picker("Day", selection: intBinding(model.reminderWeekday) { await model.setReminderWeekday($0) }) {
                    ForEach(Self.weekdays, id: \.number) { day in
                        Text(day.name).tag(day.number)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Reminder day")
                DatePicker(
                    "Time", selection: timeBinding(model), displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Reminder time")
            }
            .disabled(!model.reminderOn)
            .opacity(model.reminderOn ? 1 : Fade.disabled)
        }
    }

    private func lowDiskCard(_ model: SettingsModel) -> some View {
        SettingsCard(title: "Low disk", tone: .apps) {
            SettingsRow(
                title: "Tell me when space runs low",
                detail: Self.lowDiskDetail(model),
                isOn: binding(model.lowDiskAlertOn) { await model.setLowDiskAlertOn($0) })
            SettingsDivider()
            HStack(spacing: Space.m) {
                Text("Alert under").textStyle(.body)
                Spacer(minLength: Space.s)
                Text(ByteFormat.string(model.lowDiskThresholdBytes))
                    .font(Typo.label.monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Stepper(
                    "Alert under",
                    value: intBinding(model.lowDiskThresholdGB) { await model.setLowDiskThreshold(gigabytes: $0) },
                    in: SettingsModel.thresholdRange, step: SettingsModel.thresholdStep
                )
                .labelsHidden()
                .accessibilityLabel("Low-disk threshold")
                .accessibilityValue(ByteFormat.string(model.lowDiskThresholdBytes))
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var aboutCard: some View {
        SettingsCard(title: "About Dustpan", tone: .history) {
            Text("Version \(Self.version). Free, under the MIT License.").textStyle(.body)
            Text(Self.warranty).textStyle(.caption).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                InkButton("Licence", systemImage: "doc.text", kind: .secondary, size: .small) {
                    Self.openBundledText("LICENSE", ext: nil)
                }
                InkButton("Credits", systemImage: "heart", kind: .secondary, size: .small) {
                    Self.openBundledText("THIRD_PARTY_NOTICES", ext: "md")
                }
                InkButton("Rule sources", systemImage: "list.bullet", kind: .secondary, size: .small) {
                    Self.openBundledText("RULES_ATTRIBUTION", ext: "md")
                }
            }
        }
    }

    static let warranty =
        "Dustpan is provided as is, without warranty of any kind. It moves files to the Trash so you can put them back, but keep a backup of anything you can't lose."

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    /// Opens a licence text shipped inside the app in TextEdit (plain text, whatever opens `.md`).
    private static func openBundledText(_ name: String, ext: String?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return }
        let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        if let textEdit {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Dustpan has no background agent: it checks free space only while it runs, so the copy says
    /// so unless the menu-bar item and the login item keep it running.
    static func lowDiskDetail(_ model: SettingsModel) -> String {
        let base = "At most once a day, while the free space is under the amount below."
        if model.showInMenuBar && model.launchAtLogin { return base }
        if model.showInMenuBar { return base + " Dustpan checks while it's in the menu bar." }
        return base + " Dustpan checks only while it's open; the menu-bar item keeps it checking."
    }

    // MARK: - Bindings

    private func binding(_ value: Bool, set: @escaping @MainActor (Bool) async -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { newValue in Task { await set(newValue) } })
    }

    private func intBinding(_ value: Int, set: @escaping @MainActor (Int) async -> Void) -> Binding<Int> {
        Binding(get: { value }, set: { newValue in Task { await set(newValue) } })
    }

    private func timeBinding(_ model: SettingsModel) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    from: DateComponents(hour: model.reminderHour, minute: model.reminderMinute)) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                Task { await model.setReminderTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) }
            })
    }

    /// Weekdays in the user's calendar order, numbered as `Calendar` numbers them (1 = Sunday).
    static var weekdays: [(number: Int, name: String)] {
        let calendar = Calendar.current
        let names = calendar.weekdaySymbols
        return (0..<7).map { offset in
            let number = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (number, names[number - 1])
        }
    }

    private static func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// An outlined card with a small coloured title.
private struct SettingsCard<Content: View>: View {
    let title: String
    let tone: Tone
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                ToneGlyph(tone: tone)
                Text(title).textStyle(.headline).accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: Space.s, content: content)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkSurface(Palette.paper)
    }
}

/// A title, a line of explanation and a switch.
private struct SettingsRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).textStyle(.body).fontWeight(.semibold)
                Text(detail).textStyle(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            InkSwitch(isOn: $isOn, label: title)
                .accessibilityHint(detail)
        }
        .opacity(isEnabled ? 1 : Fade.disabled)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Palette.line).frame(height: Stroke.hairline)
    }
}

#Preview {
    SettingsView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
