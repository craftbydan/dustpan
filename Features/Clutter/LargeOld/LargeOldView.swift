import SwiftUI

/// Large & old: filters, a list of big files with Quick Look on the space bar, and Move to Trash.
struct LargeOldView: View {
    let model: LargeOldModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClutterBanners(
                issue: model.issue, moved: model.lastMove.map { ($0.count, $0.bytes) },
                dismissIssue: { model.dismissIssue() }, undo: { Task { await model.undoLastMove() } })
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            if model.isConfirming { ConfirmLargeOldSheet(model: model) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            LargeOldWorking(model: model)
        } else if !model.hasScanned {
            ScrollView {
                EmptyState(
                    "Big files you haven't opened in months. Nothing is ticked: you look, you decide.",
                    actionTitle: "Find big old files",
                    actionSymbol: "magnifyingglass",
                    action: { model.start() }
                ) {
                    IllustrationView(kind: .clutter)
                }
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                LargeOldFilters(model: model)
                    .padding(.horizontal, Space.xxl)
                    .padding(.bottom, Space.m)
                LargeOldList(model: model, showAccessSteps: { appState.onboarding.showAccessSteps() })
                    .frame(maxHeight: .infinity, alignment: .top)
                ClutterMoveBar(
                    count: model.selectedFiles.count, bytes: model.selectedBytes, noun: ("file", "files"),
                    note: "Space bar shows a file in Quick Look. Everything goes to the Trash first.",
                    disabled: model.isMoving, action: { model.requestMove() })
            }
        }
    }
}

private struct LargeOldWorking: View {
    let model: LargeOldModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ProgressBlob(progress: 0.5, tone: .clutter)
            Text("Looking for big files in your home folder…")
                .font(Typo.title)
                .foregroundStyle(Palette.ink)
            Text("Spotlight knows when each was last opened; folders it skips are measured directly.")
                .textStyle(.caption)
            InkButton("Stop", systemImage: "stop.fill", kind: .secondary) { model.cancel() }
        }
        .padding(.horizontal, Space.xxl)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Filters

private struct LargeOldFilters: View {
    @Bindable var model: LargeOldModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            // Side by side when there's room, otherwise one under the other.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.l) {
                    sizeTabs
                    ageTabs
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    sizeTabs
                    ageTabs
                }
            }
            labelled("Kind") {
                InkTabs(
                    tabs: [(ClutterKind?.none, "All")] + ClutterKind.allCases.map { (Optional($0), $0.filterTitle) },
                    selection: $model.filter.kind, tone: .clutter)
            }
        }
    }

    private var sizeTabs: some View {
        labelled("Size") {
            InkTabs(
                tabs: LargeOldFilter.MinimumSize.allCases.map { ($0, $0.title) },
                selection: $model.filter.minimumSize, tone: .clutter)
        }
    }

    private var ageTabs: some View {
        labelled("Not opened in") {
            InkTabs(
                tabs: LargeOldFilter.Age.allCases.map { ($0, $0.title) }, selection: $model.filter.age, tone: .clutter)
        }
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.xs) {
            Text(label).textStyle(.caption).fixedSize()
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

// MARK: - List

private struct LargeOldList: View {
    let model: LargeOldModel
    let showAccessSteps: () -> Void
    @FocusState private var listFocused: Bool
    @Environment(AppState.self) private var appState
    private var quickLook: QuickLook { appState.quickLook }

    var body: some View {
        let visible = model.visibleFiles
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(summary(visible))
                    .textStyle(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.m)
                if !visible.isEmpty {
                    Button(model.allVisibleSelected ? "Untick all" : "Tick all") {
                        model.setAllVisibleSelected(!model.allVisibleSelected)
                    }
                    .buttonStyle(QuietLinkStyle())
                }
            }
            .padding(.horizontal, Space.xxl)
            accessNote
            if visible.isEmpty {
                Text(
                    model.files.isEmpty
                        ? "No big files here. Your home folder has nothing over 100 MB that Dustpan can list."
                        : "Nothing matches these filters. Try a smaller size or a shorter time."
                )
                .textStyle(.body)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.l)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { file in
                                row(file).id(file.id)
                            }
                        }
                        .frame(maxWidth: Metric.clutterMaxWidth, alignment: .leading)
                        .padding(.horizontal, Space.xxl)
                        .padding(.bottom, Space.l)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($listFocused)
                    .onKeyPress(.space) {
                        quickLookFocused()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        move(1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        move(-1, proxy: proxy)
                        return .handled
                    }
                    .accessibilityLabel("Big files")
                }
            }
        }
    }

    private func summary(_ visible: [LargeFile]) -> String {
        let count = visible.count == 1 ? "1 file" : "\(visible.count) files"
        return "\(count) · \(ByteFormat.string(visible.reduce(0) { $0 + $1.allocatedSize }))"
    }

    @ViewBuilder
    private var accessNote: some View {
        if model.needsAccessCount > 0 {
            HStack(spacing: Space.s) {
                Image(systemName: "lock").accessibilityHidden(true)
                Text(
                    model.needsAccessCount == 1
                        ? "1 more big file is in Downloads, Documents or Desktop, which need Full Disk Access."
                        : "\(model.needsAccessCount) more big files are in Downloads, Documents or Desktop, which need Full Disk Access."
                )
                .lineLimit(2)
                Button("Show me how", action: showAccessSteps)
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
            }
            .textStyle(.caption)
            .padding(.horizontal, Space.xxl)
        }
    }

    private func row(_ file: LargeFile) -> some View {
        let focused = model.focusedID == file.id
        return ExplainRow(
            isSelected: Binding(get: { model.isSelected(file) }, set: { model.setSelected(file, $0) }),
            systemImage: file.kind.symbol, tone: .clutter, name: file.url.lastPathComponent,
            bytes: file.allocatedSize, why: model.displayFolder(file), risk: .review, detail: model.ageText(file),
            help: file.url.path
        )
        .background(focused ? Palette.line : Color.clear)
        .overlay(alignment: .leading) {
            if focused {
                Rectangle().fill(Palette.cobalt).frame(width: Stroke.outline * 2)
                    .accessibilityHidden(true)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                model.focusedID = file.id
                listFocused = true
            }
        )
        .contextMenu {
            Button("Quick Look") { quickLook.toggle(file.url) }
            Button("Reveal in Finder") { model.reveal(file) }
        }
        .accessibilityAction(named: "Quick Look") { quickLook.toggle(file.url) }
        .accessibilityAction(named: "Reveal in Finder") { model.reveal(file) }
    }

    private func quickLookFocused() {
        if model.focusedFile == nil { model.moveFocus(by: 1) }
        if let file = model.focusedFile { quickLook.toggle(file.url) }
    }

    private func move(_ offset: Int, proxy: ScrollViewProxy) {
        model.moveFocus(by: offset)
        if let id = model.focusedID {
            proxy.scrollTo(id)
            if let file = model.focusedFile { quickLook.follow(file.url) }
        }
    }
}

// MARK: - Confirm

private struct ConfirmLargeOldSheet: View {
    let model: LargeOldModel

    var body: some View {
        let files = model.selectedFiles
        InkSheet(
            title: files.count == 1
                ? "Move “\(files[0].url.lastPathComponent)” to the Trash?"
                : "Move \(files.count) files (\(ByteFormat.string(model.selectedBytes))) to the Trash?",
            onCancel: { model.isConfirming = false }
        ) {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(files.prefix(4)) { file in
                    Text("\(ByteFormat.string(file.allocatedSize)) · \(file.url.lastPathComponent)")
                        .font(Typo.body.monospacedDigit())
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if files.count > 4 {
                    Text("and \(files.count - 4) more").textStyle(.caption)
                }
                Text(
                    "You picked these yourself, so Dustpan can't say whether you still need them. They go to the Trash: you can put them back from History or Finder until the Trash is emptied."
                )
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            }
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
