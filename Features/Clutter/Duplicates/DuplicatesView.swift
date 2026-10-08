import AppKit
import SwiftUI

/// Duplicates: the folders to look in, groups of identical files as cards (thumbnail, keeper
/// marked), "Select duplicates, keep one", and Move to Trash.
struct DuplicatesView: View {
    let model: DuplicatesModel
    @Environment(AppState.self) private var appState

    var body: some View {
        let access = appState.onboarding.hasFullDiskAccess
        VStack(alignment: .leading, spacing: 0) {
            ClutterBanners(
                issue: model.issue, moved: model.lastMove.map { ($0.count, $0.bytes) },
                dismissIssue: { model.dismissIssue() }, undo: { Task { await model.undoLastMove() } })
            DuplicateRoots(model: model, hasFullDiskAccess: access) { appState.onboarding.showAccessSteps() }
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.m)
            content(access: access)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            if model.isConfirming { ConfirmDuplicatesSheet(model: model) }
        }
    }

    @ViewBuilder
    private func content(access: Bool) -> some View {
        let searchable = model.roots.filter { !model.rootNeedsAccess($0, hasFullDiskAccess: access) }
        if model.isScanning {
            DuplicatesWorking(model: model)
        } else if !model.hasScanned {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if searchable.isEmpty {
                        EmptyState(
                            "Downloads, Documents, Desktop and Pictures need Full Disk Access before Dustpan can compare files in them. You can add another folder instead."
                        ) {
                            IllustrationView(kind: .accessGuide)
                        }
                        HStack(spacing: Space.m) {
                            InkButton("Show me how", systemImage: "lock.open") {
                                appState.onboarding.showAccessSteps()
                            }
                            InkButton("Add a folder…", systemImage: "folder.badge.plus", kind: .secondary) {
                                DuplicateRoots.chooseFolder(model: model)
                            }
                        }
                    } else {
                        EmptyState(
                            "Exact copies of the same file, byte for byte. One copy of each always stays.",
                            actionTitle: "Find duplicates",
                            actionSymbol: "doc.on.doc",
                            action: { model.start() }
                        ) {
                            IllustrationView(kind: .clutter)
                        }
                    }
                }
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.groups.isEmpty {
            ScrollView {
                EmptyState("No duplicates. Every file in these folders is the only copy of itself.") {
                    IllustrationView(kind: .sweep)
                }
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                DuplicatesSummary(model: model)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.m)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.l) {
                        ForEach(model.groups) { group in
                            GroupCard(model: model, group: group)
                        }
                    }
                    .frame(maxWidth: Metric.clutterMaxWidth, alignment: .leading)
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.xxs)
                    .padding(.bottom, Space.l)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                ClutterMoveBar(
                    count: model.selectedCount, bytes: model.selectedBytes, noun: ("copy", "copies"),
                    note: "One copy of each file always stays. Everything goes to the Trash first.",
                    disabled: model.isMoving, action: { model.requestMove() })
            }
        }
    }
}

// MARK: - Folders

private struct DuplicateRoots: View {
    let model: DuplicatesModel
    let hasFullDiskAccess: Bool
    let showAccessSteps: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Text("Looking in").textStyle(.caption).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xs) {
                    ForEach(model.roots) { root in chip(root) }
                    Button("Add a folder…") { Self.chooseFolder(model: model) }
                        .buttonStyle(QuietLinkStyle())
                        .disabled(model.isScanning)
                        .accessibilityLabel("Add a folder to look in")
                }
                .padding(.vertical, Space.xxs)
            }
        }
    }

    private func chip(_ root: DuplicatesModel.Root) -> some View {
        let locked = model.rootNeedsAccess(root, hasFullDiskAccess: hasFullDiskAccess)
        let shape = Capsule()
        return HStack(spacing: Space.xxs) {
            if locked { Image(systemName: "lock").accessibilityHidden(true) }
            Text(root.isDefault ? root.url.lastPathComponent : model.displayPath(root.url))
                .lineLimit(1)
                .truncationMode(.middle)
            if !root.isDefault {
                Button {
                    model.removeRoot(root)
                } label: {
                    Image(systemName: "xmark").fontWeight(.bold)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop looking in \(root.url.lastPathComponent)")
            }
        }
        .font(Typo.caption.weight(.semibold))
        .foregroundStyle(locked ? Palette.secondaryText : Palette.ink)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs)
        .background(shape.fill(locked ? Palette.paper : Tone.clutter.fill.opacity(0.35)))
        .overlay(shape.strokeBorder(locked ? Palette.line : Palette.ink, lineWidth: Stroke.hairline))
        .fixedSize()
        .help(locked ? "Needs Full Disk Access" : root.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            root.url.lastPathComponent + (locked ? ", needs Full Disk Access" : ""))
    }

    static func chooseFolder(model: DuplicatesModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder in your home folder (not Library) to look for duplicates in."
        panel.directoryURL = model.home
        if panel.runModal() == .OK, let url = panel.url {
            model.addRoot(url)
        }
    }
}

// MARK: - Working

private struct DuplicatesWorking: View {
    let model: DuplicatesModel

    var body: some View {
        let progress = model.progress
        VStack(alignment: .leading, spacing: Space.l) {
            ProgressBlob(progress: progress.phase == .comparing ? progress.fraction : 0.05, tone: .clutter)
            Text(progress.phase == .listing ? "Listing files…" : "Comparing files with the same size…")
                .font(Typo.title)
                .foregroundStyle(Palette.ink)
            Text(
                progress.phase == .listing
                    ? "\(progress.filesSeen.formatted()) files so far"
                    : "\(progress.candidates.formatted()) files to compare · \(ByteFormat.string(progress.bytesRead)) of \(ByteFormat.string(progress.bytesToRead)) read"
            )
            .font(Typo.body.monospacedDigit())
            .foregroundStyle(Palette.secondaryText)
            InkButton("Stop", systemImage: "stop.fill", kind: .secondary) { model.cancel() }
        }
        .padding(.horizontal, Space.xxl)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Results

private struct DuplicatesSummary: View {
    let model: DuplicatesModel

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("\(ByteFormat.string(model.totalReclaimable)) in extra copies")
                    .font(Typo.title)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(detail).textStyle(.caption)
            }
            Spacer(minLength: Space.m)
            if model.selectedCount > 0 {
                Button("Untick all") { model.clearSelection() }
                    .buttonStyle(QuietLinkStyle())
            }
            InkButton("Select duplicates, keep one", systemImage: "checkmark.circle", kind: .secondary) {
                model.selectDuplicatesKeepOne()
            }
        }
        .frame(maxWidth: Metric.clutterMaxWidth, alignment: .leading)
    }

    private var detail: String {
        let groups = model.groups.count == 1 ? "1 file has copies" : "\(model.groups.count) files have copies"
        var text = "\(groups) · \(model.filesSeen.formatted()) files compared"
        if let folder = model.sweptFolder {
            text += " · from the Sweep, \(folder.lastPathComponent) only (Look again for every folder)"
        }
        if let seconds = model.seconds {
            text +=
                seconds < 1 ? " in under a second" : " in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
        }
        if !model.needsAccess.isEmpty {
            text +=
                " · \(model.needsAccess.map(\.lastPathComponent).joined(separator: ", ")) skipped (needs Full Disk Access)"
        }
        return text
    }
}

private struct GroupCard: View {
    let model: DuplicatesModel
    let group: DuplicateGroup
    @Environment(AppState.self) private var appState
    private var quickLook: QuickLook { appState.quickLook }

    var body: some View {
        let keeper = model.keeper(of: group)
        let name = keeper.lastPathComponent
        HStack(alignment: .top, spacing: Space.m) {
            Button {
                quickLook.toggle(keeper)
            } label: {
                FileThumbnail(url: keeper, symbol: ClutterKind.of(name).symbol)
            }
            .buttonStyle(.plain)
            .help("Quick Look")
            .accessibilityLabel("Quick Look \(name)")
            VStack(alignment: .leading, spacing: Space.xs) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(group.files.count) copies of “\(name)”")
                        .textStyle(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(
                        "\(ByteFormat.string(group.files.first?.allocatedSize ?? group.size)) each · \(ByteFormat.string(reclaimable(keeper))) can go"
                    )
                    .font(Typo.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
                }
                VStack(spacing: 0) {
                    ForEach(group.files) { file in
                        CopyRow(model: model, group: group, file: file, isKeeper: file.url == keeper)
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .inkSurface(Palette.paper, radius: Radius.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.files.count) copies of \(name)")
    }

    private func reclaimable(_ keeper: URL) -> Int64 {
        group.files.filter { $0.url != keeper }.reduce(0) { $0 + $1.allocatedSize }
    }
}

private struct CopyRow: View {
    let model: DuplicatesModel
    let group: DuplicateGroup
    let file: DuplicateFile
    let isKeeper: Bool
    @Environment(AppState.self) private var appState
    private var quickLook: QuickLook { appState.quickLook }

    var body: some View {
        HStack(spacing: Space.s) {
            InkCheckbox(
                isOn: Binding(
                    get: { model.isSelected(file) }, set: { model.setSelected(file, in: group, $0) }),
                label: "Move \(file.url.lastPathComponent) in \(folder)"
            )
            .disabled(isKeeper)
            .opacity(isKeeper ? 0.35 : 1)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(file.url.lastPathComponent)
                    .font(Typo.body)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(folder) · added \(file.created.formatted(date: .abbreviated, time: .omitted))")
                    .textStyle(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.s)
            if isKeeper {
                InkBadge(text: "Keeping", systemImage: "checkmark", tone: .clutter)
            } else {
                Button("Keep this one") { model.keep(file, in: group) }
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel("Keep the copy in \(folder) instead")
            }
        }
        .padding(.vertical, Space.xs)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
        .contentShape(Rectangle())
        .help(file.url.path)
        .contextMenu {
            Button("Quick Look") { quickLook.toggle(file.url) }
            Button("Reveal in Finder") { model.reveal(file.url) }
            if !isKeeper { Button("Keep this one") { model.keep(file, in: group) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(file.url.lastPathComponent) in \(folder)" + (isKeeper ? ", the copy that stays" : "")
        )
        .accessibilityAction(named: "Quick Look") { quickLook.toggle(file.url) }
        .accessibilityAction(named: "Reveal in Finder") { model.reveal(file.url) }
    }

    private var folder: String { model.displayPath(file.url.deletingLastPathComponent()) }
}

// MARK: - Confirm

private struct ConfirmDuplicatesSheet: View {
    let model: DuplicatesModel

    var body: some View {
        let count = model.selectedCount
        InkSheet(
            title:
                "Move \(count == 1 ? "1 copy" : "\(count) copies") (\(ByteFormat.string(model.selectedBytes))) to the Trash?",
            onCancel: { model.isConfirming = false }
        ) {
            Text(
                "One copy of each file stays where it is. Right before moving, Dustpan compares every copy with the one that stays, byte for byte, and leaves it alone if anything changed. You can put them back from History or Finder until the Trash is emptied."
            )
            .textStyle(.body)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer()
                InkButton("Cancel", kind: .secondary) { model.isConfirming = false }
                    .keyboardShortcut(.cancelAction)
                InkButton("Move to Trash", systemImage: "trash") { Task { await model.confirmMove() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
