import AppKit
import SwiftUI

/// The menu-bar item's label: just the Dustpan glyph, a transparent template image that macOS
/// tints for light and dark menu bars. Free space lives in the popover.
struct MenuBarLabel: View {
    let model: MenuBarModel

    /// The vector asset sized for the menu bar (a SwiftUI `.frame` is ignored in a menu-bar label).
    @MainActor private static let glyph: NSImage = {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage()
        image.size = NSSize(width: Metric.menuBarGlyph, height: Metric.menuBarGlyph)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.glyph)
            .accessibilityLabel("Dustpan, \(model.label) free on the startup disk")
    }
}

/// The popover: free space as the big number, four small gauges, and "Sweep now".
struct MenuBarPopover: View {
    let model: MenuBarModel
    let thresholdBytes: Int64
    let sweepNow: () -> Void
    let openDustpan: () -> Void
    let quit: () -> Void

    private var isLow: Bool { (model.disk?.availableBytes ?? .max) < thresholdBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            disk
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)],
                spacing: Space.s
            ) {
                cpuGauge
                memoryGauge
                batteryGauge
                networkGauge
            }
            HStack(spacing: Space.s) {
                InkButton("Sweep now", action: sweepNow)
                Spacer(minLength: Space.xs)
                Button("Open Dustpan", action: openDustpan)
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel("Open Dustpan")
                Button("Quit", action: quit)
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel("Quit Dustpan")
            }
            .padding(.top, Space.xxs)
        }
        .padding(Space.l)
        .frame(width: Metric.menuPopoverWidth)
        .background(Palette.paper)
        // No control starts focused, so Return/Space can't start a Sweep by surprise.
        .background(NoInitialFocus())
    }

    // MARK: - Disk

    private var disk: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Startup disk").textStyle(.caption)
            if let disk = model.disk {
                Text(ByteFormat.string(disk.availableBytes))
                    .textStyle(.bigNumber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text("free of \(ByteFormat.string(disk.totalBytes))").textStyle(.body)
                SizeBar(value: disk.usedBytes, total: disk.totalBytes, tone: isLow ? .apps : .sweep)
                if isLow {
                    Text("That's under the \(ByteFormat.string(thresholdBytes)) you set in Settings.")
                        .textStyle(.caption)
                }
            } else {
                Text("—").textStyle(.bigNumber)
                Text("Reading the disk…").textStyle(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Gauges

    private var cpuGauge: some View {
        MiniGauge(
            title: "CPU", tone: .logs,
            value: model.cpu.map(Self.percent) ?? Self.waiting,
            fraction: model.cpu,
            detail: model.cpu.map { $0 < 0.5 ? "Mostly idle" : "Working hard" } ?? " ")
    }

    private var memoryGauge: some View {
        MiniGauge(
            title: "Memory pressure", tone: .dev,
            value: model.memory?.pressure.title ?? Self.waiting,
            fraction: model.memory?.usedFraction,
            detail: model.memory.map {
                "\(Self.memory($0.usedBytes)) of \(Self.memory($0.totalBytes)) in use"
            } ?? " ")
    }

    @ViewBuilder
    private var batteryGauge: some View {
        if let battery = model.battery {
            MiniGauge(
                title: "Battery", tone: .installers,
                value: Self.percent(battery.level),
                fraction: battery.level,
                detail: Self.batteryDetail(battery))
        } else {
            MiniGauge(
                title: "Battery", tone: .installers,
                value: model.hasFullSample ? "None" : Self.waiting,
                fraction: nil,
                detail: model.hasFullSample ? "No battery in this Mac" : " ")
        }
    }

    private var networkGauge: some View {
        MiniGauge(
            title: "Network", tone: .sweep,
            value: model.network.map { "↓ \(Self.rate($0.bytesInPerSecond))" } ?? Self.waiting,
            fraction: nil,
            detail: model.network.map { "↑ \(Self.rate($0.bytesOutPerSecond))" } ?? " ",
            spokenValue: model.network.map {
                "\(Self.rate($0.bytesInPerSecond)) down, \(Self.rate($0.bytesOutPerSecond)) up"
            })
    }

    static let waiting = "…"

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "0 KB/s", "1.2 MB/s" (`ByteCountFormatter(.file)`, always numeric).
    static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond.rounded())))/s"
    }

    /// RAM in binary units, as macOS shows it ("16 GB", not "17.18 GB"). Memory gauge only;
    /// file sizes everywhere else stay `.file`.
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func batteryDetail(_ battery: BatteryReading) -> String {
        var parts = [battery.isCharging ? "Charging" : (battery.isOnPower ? "Plugged in" : "On battery")]
        if let health = battery.healthPercent { parts.append("health \(health)%") }
        if let cycles = battery.cycles { parts.append("\(cycles) cycles") }
        return parts.joined(separator: " · ")
    }
}

/// One small gauge card: title, value, optional bar, one line of detail.
private struct MiniGauge: View {
    let title: String
    let tone: Tone
    let value: String
    let fraction: Double?
    let detail: String
    var spokenValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xxs) {
                ToneGlyph(tone: tone, size: Space.s)
                Text(title).textStyle(.caption).lineLimit(1)
            }
            Text(value)
                .font(Typo.gaugeNumber)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let fraction {
                SizeBar(value: Int64(fraction * 1000), total: 1000, tone: tone, height: Metric.gaugeBarHeight)
            } else {
                Spacer().frame(height: Metric.gaugeBarHeight)
            }
            Text(detail)
                .textStyle(.caption)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkSurface(Palette.paper, radius: Radius.small, shadow: Stroke.pressDepth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            [spokenValue ?? value, detail.trimmingCharacters(in: .whitespaces)]
                .filter { !$0.isEmpty && $0 != MenuBarPopover.waiting }
                .joined(separator: ", ")
                .replacingOccurrences(of: " · ", with: ", "))
    }
}

/// Clears the window's first responder when the popover appears (macOS would otherwise focus
/// the first focusable control, "Sweep now"). Tab still reaches every control.
private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> ClearingView { ClearingView() }
    func updateNSView(_ nsView: ClearingView, context: Context) {}

    final class ClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
        }
    }
}
