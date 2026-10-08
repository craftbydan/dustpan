import SwiftUI

// The confirmation and the celebration of a junk clean. Shared by the Junk screen and the
// Sweep's "Clean recommended", so both look and behave the same (30 s Undo included).

/// The confirmation's top block when ticked items wait on open apps: who's open, what waits,
/// and "Quit them for me" / "Leave them". Never silently skipped.
struct BlockedSection {
    let groups: [BlockedGroup]
    /// Apps that were asked to quit and are still open.
    var stillOpen: [String] = []
    var isQuitting = false
    let quitAll: () -> Void
    let leave: () -> Void
}

/// "Move 1.2 GB to the Trash?" with one line per category.
struct CleanConfirmSheet: View {
    let bytes: Int64
    let lines: [JunkModel.CategorySummary]
    var note = "Everything goes to the Trash. You can put it back from History until the Trash is emptied."
    var blocked: BlockedSection?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var title: String {
        bytes > 0 || lines.contains(where: { $0.count > 0 })
            ? "Move \(ByteFormat.string(bytes)) to the Trash?" : "These need their apps closed first"
    }

    var body: some View {
        InkSheet(title: title, onCancel: onCancel) {
            if let blocked, !blocked.groups.isEmpty { BlockedBlock(section: blocked) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(spacing: Space.s) {
                        ToneGlyph(tone: Tone(rawValue: line.category.rawValue) ?? .trash)
                        Text(line.category.title).textStyle(.body)
                        Text(line.count == 1 ? "1 item" : "\(line.count) items").textStyle(.caption)
                        Spacer(minLength: Space.s)
                        Text(ByteFormat.string(line.bytes)).font(Typo.headline.monospacedDigit())
                            .foregroundStyle(Palette.ink)
                    }
                    .padding(.vertical, Space.xs)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(note)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Cancel", kind: .secondary, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Move to Trash", systemImage: "trash", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(lines.isEmpty || blocked?.isQuitting == true)
            }
        }
    }
}

private struct BlockedBlock: View {
    let section: BlockedSection

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        let apps = section.groups.map(\.app.name)
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(section.groups) { group in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    NoticePill(text: "\(group.app.name) is open")
                    Text(
                        "\(group.count == 1 ? "1 item" : "\(group.count) items") · \(ByteFormat.string(group.bytes)) can't move until it's closed"
                    )
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if !section.stillOpen.isEmpty {
                Text(
                    "\(ListFormatter.localizedString(byJoining: section.stillOpen)) didn't quit. It may be asking you to save something."
                )
                .font(Typo.caption.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    "Quitting asks \(apps.count == 1 ? "it" : "each one") politely. Unsaved work may ask you to save first."
                )
                .textStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.m) {
                InkButton(
                    section.isQuitting ? "Quitting…" : "Quit \(apps.count == 1 ? "it" : "them") for me",
                    systemImage: "power", kind: .secondary, size: .small, action: section.quitAll
                )
                .disabled(section.isQuitting)
                .accessibilityLabel("Quit \(ListFormatter.localizedString(byJoining: apps)) for me")
                let waiting = section.groups.reduce(0) { $0 + $1.count }
                Button(waiting == 1 ? "Leave it" : "Leave them", action: section.leave)
                    .buttonStyle(QuietLinkStyle())
                    .disabled(section.isQuitting)
                    .accessibilityHint("Unticks what waits on the open app")
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.line))
        .overlay(shape.strokeBorder(Palette.tomato, lineWidth: Stroke.outline))
        .accessibilityElement(children: .contain)
    }
}

/// "Quit Chrome?" — asked once before Dustpan sends a polite quit (never a forced one).
struct QuitAppSheet: View {
    let app: BlockingApp
    let onCancel: () -> Void
    let onQuit: () -> Void

    var body: some View {
        InkSheet(title: "Quit \(app.name)?", onCancel: onCancel) {
            Text(
                "Unsaved work in \(app.name) may ask you to save. Dustpan asks it the same way as choosing Quit from its menu, and waits for it."
            )
            .textStyle(.body)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Cancel", kind: .secondary, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Quit \(app.name)", systemImage: "power", action: onQuit)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The ink burst, the freed size, Undo for 30 seconds, and anything that stayed put.
struct CleanResultView: View {
    let report: CleanReport
    let undoDeadline: Date?
    let undo: () async -> Void
    let done: () -> Void
    let openHistory: () -> Void
    /// Opens the Empty Trash confirmation; nil hides the button (e.g. without Full Disk Access).
    var emptyTrash: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .center, spacing: Space.xl) {
                    if !report.moved.isEmpty {
                        // The burst gives way to the text in a narrow window.
                        ViewThatFits(in: .horizontal) {
                            InkBurst()
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        if report.moved.isEmpty {
                            // Calm, no giant "0 bytes": the reasons below are the point.
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text("Nothing moved this time")
                                    .font(Typo.title)
                                    .foregroundStyle(Palette.ink)
                                Text("Everything stayed where it was. Here's why.")
                                    .textStyle(.body)
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(ByteFormat.string(report.freedBytes))
                                    .textStyle(.bigNumber)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                Text("moved to the Trash")
                                    .font(Typo.title)
                                    .foregroundStyle(Palette.ink)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(ByteFormat.string(report.freedBytes)) moved to the Trash")
                        }
                        if !report.moved.isEmpty {
                            Text(
                                "\(report.moved.count == 1 ? "1 item" : "\(report.moved.count) items") moved. Apps rebuild what they need, and History can put them back until the Trash is emptied."
                            )
                            .textStyle(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            TrashNote(plural: report.moved.count != 1, emptyTrash: emptyTrash)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Space.m) { actions }
                            VStack(alignment: .leading, spacing: Space.s) { actions }
                        }
                        .padding(.top, Space.s)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !report.skipped.isEmpty {
                    SkippedGroupsView(items: report.skipped.map { ($0.url, $0.reason) })
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.bottom, Space.xxl)
        }
    }
}

extension CleanResultView {
    @ViewBuilder
    fileprivate var actions: some View {
        UndoButton(deadline: undoDeadline, undo: undo)
        InkButton("Done", action: done)
            .keyboardShortcut(.defaultAction)
        Button("See History", action: openHistory)
            .buttonStyle(QuietLinkStyle())
            .fixedSize()
    }
}

/// Moving to the Trash frees no space until the Trash is emptied; this says so, calmly, with
/// the existing Empty Trash confirmation one click away.
struct TrashNote: View {
    var plural = true
    let emptyTrash: (() -> Void)?

    static func text(plural: Bool) -> String {
        "\(plural ? "They're" : "It's") in the Trash now — empty the Trash to get the space back."
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(Self.text(plural: plural))
                .textStyle(.caption)
                .lineLimit(3)
            if let emptyTrash {
                Button("Empty Trash…", action: emptyTrash)
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityHint("Shows the size and asks before deleting anything")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Undo (24 s)" for 30 seconds after a clean, then it goes away.
private struct UndoButton: View {
    let deadline: Date?
    let undo: () async -> Void

    var body: some View {
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Int(deadline.timeIntervalSince(context.date).rounded(.up))
                if left > 0 {
                    InkButton("Undo (\(left) s)", systemImage: "arrow.uturn.backward", kind: .secondary) {
                        Task { await undo() }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel("Undo, \(left) seconds left")
                }
            }
        }
    }
}

/// "N items stayed where they were", grouped by reason: one line per reason with its count and
/// a Show/Hide list of names (truncated in the middle), instead of the same sentence repeated on
/// every row. A reason with a single item shows that item's name directly.
struct SkippedGroupsView: View {
    struct Group: Identifiable, Equatable {
        let id: Int
        let reason: SkipReason
        let urls: [URL]
    }

    let items: [(url: URL, reason: SkipReason)]
    /// A custom line for a reason (e.g. "14 leftovers kept until Teams is removed."); when given,
    /// it replaces the count and the generic explanation.
    var title: (SkipReason, Int) -> String? = { _, _ in nil }
    var showsHeader = true

    @State private var expanded: Set<Int> = []

    /// Items grouped by identical reason, in order of first appearance.
    static func groups(_ items: [(url: URL, reason: SkipReason)]) -> [Group] {
        var order: [SkipReason] = []
        var urls: [[URL]] = []
        for item in items {
            if let index = order.firstIndex(of: item.reason) {
                urls[index].append(item.url)
            } else {
                order.append(item.reason)
                urls.append([item.url])
            }
        }
        return order.indices.map { Group(id: $0, reason: order[$0], urls: urls[$0]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if showsHeader {
                Text(items.count == 1 ? "1 item stayed where it was" : "\(items.count) items stayed where they were")
                    .textStyle(.headline)
            }
            ForEach(Self.groups(items)) { group in
                groupRow(group)
                    .padding(.vertical, Space.xxs)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
            }
        }
        .frame(maxWidth: Metric.sheetWidth + Space.xxxl, alignment: .leading)
    }

    @ViewBuilder
    private func groupRow(_ group: Group) -> some View {
        let custom = title(group.reason, group.urls.count)
        let isOpen = expanded.contains(group.id)
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                if let custom {
                    Text(custom).font(Typo.body.weight(.semibold)).foregroundStyle(Palette.ink).lineLimit(2)
                } else if group.urls.count == 1, let url = group.urls.first {
                    Text(url.lastPathComponent)
                        .font(Typo.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .help(url.path)
                } else {
                    Text("\(group.urls.count) items").font(Typo.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        .fixedSize()
                }
                Spacer(minLength: Space.s)
                if group.urls.count > 1 || custom != nil {
                    Button(isOpen ? "Hide" : "Show") {
                        if isOpen { expanded.remove(group.id) } else { expanded.insert(group.id) }
                    }
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel(
                        isOpen ? "Hide the \(group.urls.count) items" : "Show the \(group.urls.count) items")
                }
            }
            if custom == nil {
                Text(group.reason.explanation).textStyle(.caption).lineLimit(2)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(Array(group.urls.enumerated()), id: \.offset) { _, url in
                        Text(url.lastPathComponent)
                            .textStyle(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(url.path)
                    }
                }
                .padding(.leading, Space.m)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
