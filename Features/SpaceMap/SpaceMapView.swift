import AppKit
import SwiftUI

/// Space map: a squarified treemap of the home folder, the startup disk or a chosen folder.
/// Click a block to select it (⌘/Shift-click for more), double-click a folder to open it, the
/// breadcrumb or ← / ⌘↑ to go back. The bottom bar is always there: Move to Trash (⌘⌫)
/// pre-checks the selection with the Cleaner and asks first; right-click, the hover trash button
/// and the list's trash buttons do the same.
struct SpaceMapView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.spaceMap
        VStack(alignment: .leading, spacing: 0) {
            SpaceMapHeader(model: model)
            if let issue = model.issue {
                QuietBanner(
                    systemImage: "exclamationmark.circle", message: issue.localizedDescription, actionTitle: "OK",
                    action: { model.dismissIssue() }
                )
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.m)
            }
            if let move = model.lastMove {
                QuietBanner(
                    systemImage: "trash",
                    message:
                        "Moved \(move.count == 1 ? "“\(move.name)”" : move.name) (\(Self.bytes(move.bytes))) to the Trash. History can put it back later.",
                    actionTitle: "Undo",
                    action: { Task { await model.undoLastMove() } }
                )
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.m)
            }
            content(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .overlay {
            if let pending = model.pendingTrash {
                ConfirmMoveSheet(model: model, pending: pending)
            }
        }
    }

    @ViewBuilder
    private func content(_ model: SpaceMapModel) -> some View {
        if model.isWalking {
            WalkingView(model: model)
        } else if !model.hasMap {
            ScrollView {
                EmptyState(
                    "Your disk as blocks, one per folder, each sized by the space it really takes.",
                    actionTitle: "Map my disk",
                    actionSymbol: "square.split.2x2",
                    action: { model.start() }
                ) {
                    IllustrationView(kind: .spaceMap)
                }
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            MapContent(model: model) { appState.onboarding.showAccessSteps() }
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteFormat.string(value)
    }

    static let hint = "Click a block to select it · double-click a folder to open it · ⌘⌫ moves it to the Trash."
    static let hintSpoken =
        "Click a block to select it, double-click a folder to open it, Command Delete moves it to the Trash."

    /// ⌘ or Shift held during the current click: add to / remove from the selection.
    @MainActor static var clickTogglesSelection: Bool {
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        return flags.contains(.command) || flags.contains(.shift)
    }

    /// The current click is the second of a double-click.
    @MainActor static var isDoubleClick: Bool { (NSApp.currentEvent?.clickCount ?? 1) >= 2 }
}

// MARK: - Header

private struct SpaceMapHeader: View {
    let model: SpaceMapModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                ToneGlyph(tone: AppSection.spaceMap.tone, size: Space.l)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text("Space map")
                    .textStyle(.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.m)
                if model.hasMap && !model.isWalking {
                    InkButton("Look again", systemImage: "arrow.clockwise", kind: .secondary) { model.start() }
                        .disabled(model.isMoving)
                }
            }
            HStack(spacing: Space.s) {
                InkTabs(tabs: scopes.map { ($0, $0.title) }, selection: scopeBinding, tone: .spaceMap)
                Button("Choose folder…", action: chooseFolder)
                    .buttonStyle(QuietLinkStyle())
                    .accessibilityLabel("Choose a folder to map")
                    .disabled(model.isMoving)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    private var scopes: [SpaceMapModel.Scope] {
        if case .folder = model.scope { return [.home, .disk, model.scope] }
        return [.home, .disk]
    }

    private var scopeBinding: Binding<SpaceMapModel.Scope> {
        Binding(get: { model.scope }, set: { model.start($0) })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Map"
        panel.message = "Choose a folder to map."
        if panel.runModal() == .OK, let url = panel.url {
            model.start(.folder(url))
        }
    }
}

// MARK: - Walking

private struct WalkingView: View {
    let model: SpaceMapModel

    var body: some View {
        let progress = model.progress
        VStack(spacing: Space.l) {
            ProgressBlob(
                progress: min(Double(progress.bytes) / Double(model.expectedBytes), 0.97), tone: .spaceMap)
            Text("Mapping \(model.scope == .home ? "your home folder" : model.scope.title)…")
                .font(Typo.title)
                .foregroundStyle(Palette.ink)
            Text(
                "\(progress.files.formatted()) files · \(SpaceMapView.bytes(progress.bytes)) · \(Int(progress.filesPerSecond).formatted()) files a second"
            )
            .font(Typo.caption.monospacedDigit())
            .foregroundStyle(Palette.secondaryText)
            InkButton("Stop", systemImage: "stop.fill", kind: .secondary) { model.cancelWalk() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Map

private struct MapContent: View {
    let model: SpaceMapModel
    let showAccessSteps: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Breadcrumb(model: model, animate: animate)
                    Spacer(minLength: Space.s)
                    if let seconds = model.walkSeconds, let tree = model.tree {
                        Text(
                            "\(tree.fileCount.formatted()) files mapped "
                                + (seconds < 1
                                    ? "in under a second"
                                    : "in \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
                        )
                        .font(Typo.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                    if model.hintSeen { HintButton() }
                }
                if !model.hintSeen { HintLine() }
                HStack(alignment: .top, spacing: Space.l) {
                    TreemapBoard(model: model, animate: animate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    SideList(model: model, animate: animate, showAccessSteps: showAccessSteps)
                        .frame(width: Metric.spaceListWidth)
                        .frame(maxHeight: .infinity)
                }
                .padding(.top, Space.xxs)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.bottom, Space.m)
            SelectionBar(model: model)
        }
        .background {
            // Keyboard: ⌘↑ goes up a folder from anywhere on the screen.
            Button("Up one folder") { animate { model.goUp() } }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .task { await model.loadHint() }
    }

    /// Only drill transitions animate, and only without Reduce Motion.
    private func animate(_ change: @escaping () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(Motion.fill, change)
        }
    }
}

/// What to do with the map, in one calm line. Shown until the first selection.
private struct HintLine: View {
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "cursorarrow.click")
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            Text(SpaceMapView.hint)
                .textStyle(.caption)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SpaceMapView.hintSpoken)
    }
}

/// The hint, folded into a "?" after the first selection.
private struct HintButton: View {
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "questionmark")
                .font(Typo.caption.weight(.bold))
                .foregroundStyle(Palette.ink)
                .frame(width: Metric.checkbox, height: Metric.checkbox)
                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: Stroke.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(SpaceMapView.hint)
        .accessibilityLabel("How to use the Space map")
        .accessibilityHint(SpaceMapView.hintSpoken)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(SpaceMapView.hint)
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Metric.tooltipWidth)
                .padding(Space.m)
        }
    }
}

/// Always at the bottom of the map: what's selected and Move to Trash (⌘⌫). With nothing
/// selected it says how to select and shows the button disabled, so the action is easy to find.
private struct SelectionBar: View {
    let model: SpaceMapModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                status
                Spacer(minLength: Space.m)
                buttons
            }
            VStack(alignment: .leading, spacing: Space.s) {
                status
                HStack(spacing: Space.m) {
                    Spacer(minLength: 0)
                    buttons
                }
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection")
    }

    private var isEmpty: Bool { model.selection.isEmpty }

    private var title: String {
        let count = model.selection.count
        guard count > 0 else { return "Click a block to select it" }
        let items = count == 1 ? "1 item" : "\(count) items"
        return "\(items) · \(SpaceMapView.bytes(model.selectedBytes)) selected"
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(title)
                .textStyle(.headline)
                .lineLimit(1)
            Text(
                isEmpty
                    ? "⌘-click to pick more than one. Everything goes to the Trash first."
                    : "Everything goes to the Trash first. History can put it back."
            )
            .textStyle(.caption)
            .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var buttons: some View {
        HStack(spacing: Space.s) {
            if !isEmpty {
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(QuietLinkStyle())
                    .accessibilityLabel("Clear the selection")
                InkButton("Reveal in Finder", systemImage: "folder", kind: .secondary, size: .small) {
                    model.revealSelection()
                }
            }
            InkButton(
                isEmpty ? "Move to Trash" : "Move \(SpaceMapView.bytes(model.selectedBytes)) to Trash",
                systemImage: "trash"
            ) {
                Task { await model.requestTrashSelection() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(isEmpty || model.isMoving || model.isChecking)
            .accessibilityHint(isEmpty ? "Select a block first" : "Asks before moving anything")
        }
        .fixedSize()
    }
}

private struct Breadcrumb: View {
    let model: SpaceMapModel
    let animate: (@escaping () -> Void) -> Void

    var body: some View {
        let crumbs = model.breadcrumb
        HStack(spacing: Space.xxs) {
            ForEach(Array(crumbs.enumerated()), id: \.element) { position, index in
                if position > 0 {
                    Image(systemName: "chevron.right")
                        .font(Typo.caption.weight(.bold))
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityHidden(true)
                }
                if position == crumbs.count - 1 {
                    Text(model.title(of: index))
                        .font(Typo.label)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel(
                            "Showing \(model.title(of: index)), \(SpaceMapView.bytes(model.size(index)))")
                } else {
                    Button(model.title(of: index)) { animate { model.go(to: index) } }
                        .buttonStyle(QuietLinkStyle())
                        .lineLimit(1)
                        .accessibilityLabel("Back to \(model.title(of: index))")
                }
            }
            Text(SpaceMapView.bytes(model.currentSize))
                .font(Typo.caption.monospacedDigit())
                .foregroundStyle(Palette.secondaryText)
                .padding(.leading, Space.xs)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }
}

// MARK: - Treemap

extension FileKind {
    var fill: Color {
        switch self {
        case .apps: Palette.tomato
        case .media: Palette.sun
        case .documents: Palette.cobalt
        case .dev: Palette.bubblegum
        case .caches: Palette.mint
        case .other: Palette.stone
        }
    }

    var onFill: Color { self == .documents ? Palette.paperFixed : Palette.inkFixed }
}

extension SpaceMapModel.Entry {
    /// Blocks Dustpan measured but doesn't list (protected, other volumes) are drawn quietly.
    var isQuiet: Bool { nodeKind != .file && nodeKind != .directory && nodeKind != .link }

    var kindLabel: String {
        if case .others = content { return "Too small to draw one by one" }
        return switch nodeKind {
        case .protected: "Protected — measured, not listed"
        case .needsAccess: "Needs Full Disk Access"
        case .otherVolume: "Another disk"
        case .unreadable: "macOS didn't let Dustpan look inside"
        case .partial: "Partly listed: macOS stopped Dustpan partway"
        default: fileKind.title
        }
    }
}

private struct TreemapBoard: View {
    let model: SpaceMapModel
    let animate: (@escaping () -> Void) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TreemapCanvas(model: model, size: geometry.size, animate: animate)
                .id(model.current)
                .transition(
                    reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96, anchor: .center)))
        }
        .padding(Stroke.outline)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .inkSurface(Palette.paper, radius: Radius.medium)
    }
}

private struct TreemapCanvas: View {
    let model: SpaceMapModel
    let size: CGSize
    let animate: (@escaping () -> Void) -> Void

    @State private var hovered: Int?
    @State private var pointer: CGPoint = .zero
    @FocusState private var hasFocus: Bool

    private var entries: [SpaceMapModel.Entry] { model.entries }

    private var rects: [CGRect] {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: Space.xxs, dy: Space.xxs)
        return TreemapLayout.squarify(entries.map { Double($0.size) }, in: bounds)
    }

    /// The hovered block, or (DEBUG screenshots) the one the model asks to draw as hovered.
    private var hoveredIndex: Int? {
        #if DEBUG
            if let forced = model.debugHover, let i = entries.firstIndex(where: { $0.node == forced }) { return i }
        #endif
        return hovered
    }

    var body: some View {
        let rects = rects
        let entries = entries
        let hoveredIndex = hoveredIndex
        Canvas { context, _ in
            for (i, rect) in rects.enumerated() where rect.width >= 1 && rect.height >= 1 {
                draw(entries[i], in: rect, hovered: i == hoveredIndex, context: &context)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            hasFocus = true
            guard let i = rects.firstIndex(where: { $0.contains(location) }), let index = entries[i].node else {
                return
            }
            if SpaceMapView.isDoubleClick, entries[i].canDrill {
                animate { model.drill(into: index) }
            } else {
                model.click(index, toggle: SpaceMapView.clickTogglesSelection)
            }
        }
        .overlay(alignment: .topLeading) { trashButton(rects: rects, hovered: hoveredIndex) }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer = location
                hovered = rects.firstIndex { $0.contains(location) }
            case .ended:
                hovered = nil
            }
        }
        .contextMenu {
            if let hovered, entries.indices.contains(hovered), let index = entries[hovered].node {
                ItemMenu(model: model, index: index, animate: animate)
            }
        }
        .overlay(alignment: .topLeading) { tooltip(hovered: hoveredIndex) }
        .focusable()
        .focusEffectDisabled()
        .focused($hasFocus)
        .onKeyPress(phases: .down) { press in handleKey(press, rects: rects) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space map of \(model.title(of: model.current))")
        .accessibilityHint("Arrow keys move between blocks; Space selects; Return opens a folder")
        .accessibilityChildren {
            ForEach(Array(entries.enumerated()), id: \.element.id) { _, entry in
                TileAccessibility(model: model, entry: entry, animate: animate)
            }
        }
    }

    // MARK: Keyboard

    /// ↓/↑ next/previous block in reading order (top to bottom, then left to right), Space
    /// selects, ⌘/Shift-Space adds, → or Return opens a folder, ← goes up, Esc clears.
    private func handleKey(_ press: KeyPress, rects: [CGRect]) -> KeyPress.Result {
        let order = readingOrder(rects)
        let position = model.focused.flatMap { focused in order.firstIndex { entries[$0].node == focused } }
        func focus(_ step: Int) -> KeyPress.Result {
            guard !order.isEmpty else { return .ignored }
            let next = position.map { min(max($0 + step, 0), order.count - 1) } ?? 0
            model.focus(entries[order[next]].node)
            return .handled
        }
        switch press.key {
        case .downArrow: return focus(1)
        case .upArrow: return press.modifiers.contains(.command) ? .ignored : focus(-1)
        case .leftArrow:
            animate { model.goUp() }
            return .handled
        case .rightArrow, .return:
            guard let focused = model.focused, model.canDrill(focused) else { return .ignored }
            animate { model.drill(into: focused) }
            return .handled
        case .space:
            guard let focused = model.focused else { return focus(0) }
            if press.modifiers.contains(.command) || press.modifiers.contains(.shift) {
                model.setSelected(focused, !model.isSelected(focused))
            } else if model.isSelected(focused) && model.selection.count == 1 {
                model.setSelected(focused, false)
            } else {
                model.click(focused)
            }
            return .handled
        case .escape:
            guard !model.selection.isEmpty else { return .ignored }
            model.clearSelection()
            return .handled
        default:
            return .ignored
        }
    }

    private func readingOrder(_ rects: [CGRect]) -> [Int] {
        rects.indices
            .filter { entries[$0].node != nil && rects[$0].width >= 1 && rects[$0].height >= 1 }
            .sorted {
                let a = rects[$0]
                let b = rects[$1]
                return abs(a.minY - b.minY) > Space.xxs ? a.minY < b.minY : a.minX < b.minX
            }
    }

    // MARK: Drawing

    private func draw(
        _ entry: SpaceMapModel.Entry, in rect: CGRect, hovered: Bool, context: inout GraphicsContext
    ) {
        let tile = rect.insetBy(dx: Stroke.hairline, dy: Stroke.hairline)
        guard tile.width > 0, tile.height > 0 else { return }
        let radius = min(Radius.small / 2, min(tile.width, tile.height) / 4)
        let shape = Path(roundedRect: tile, cornerRadius: radius, style: .continuous)
        let big = min(tile.width, tile.height) >= Metric.treemapLabelMin.height
        let selected = entry.node.map(model.isSelected) ?? false
        let focused = entry.node != nil && entry.node == model.focused && hasFocus

        if (hovered || selected) && big {
            let shadow = Path(
                roundedRect: tile.offsetBy(dx: Stroke.pressDepth, dy: Stroke.pressDepth), cornerRadius: radius,
                style: .continuous)
            context.fill(shadow, with: .color(Palette.ink))
        }
        let ignored = entry.node.map(model.isIgnored) ?? false
        let fill: Color = entry.isQuiet || ignored ? Palette.line : entry.fileKind.fill
        context.fill(shape, with: .color(Palette.paper))
        context.fill(shape, with: .color(fill))
        let line: CGFloat =
            selected ? Stroke.outline * 1.6 : hovered ? Stroke.outline : (big ? Stroke.outline * 0.6 : Stroke.hairline)
        context.stroke(
            shape, with: .color(Palette.ink),
            style: StrokeStyle(lineWidth: line, dash: entry.isQuiet && !selected ? [Space.xxs, Space.xxs] : []))
        if focused {
            let ring = Path(
                roundedRect: tile.insetBy(dx: Stroke.outline * 2, dy: Stroke.outline * 2),
                cornerRadius: max(radius - Stroke.outline, 0), style: .continuous)
            context.stroke(ring, with: .color(Palette.cobalt), style: StrokeStyle(lineWidth: Stroke.outline))
        }
        if selected && tile.width >= Metric.checkbox * 2 && tile.height >= Metric.checkbox * 1.5 {
            // A tick badge in the corner, so the selection reads without colour.
            let badge = CGRect(
                x: tile.maxX - Metric.checkbox - Space.xxs, y: tile.minY + Space.xxs, width: Metric.checkbox,
                height: Metric.checkbox)
            context.fill(Path(ellipseIn: badge), with: .color(Palette.ink))
            let tick = context.resolve(
                Text(Image(systemName: "checkmark")).font(Typo.pill).foregroundStyle(Palette.paper))
            context.draw(tick, at: CGPoint(x: badge.midX, y: badge.midY), anchor: .center)
        }

        guard tile.width > Metric.treemapLabelMin.width, tile.height > Metric.treemapLabelMin.height else { return }
        let textColor = entry.isQuiet || ignored ? Palette.ink : entry.fileKind.onFill
        let padding = Space.xs
        let reserved = selected ? Metric.checkbox + Space.xxs : 0
        let maxChars = max(Int((tile.width - padding * 2 - reserved) / 7), 1)
        let name = entry.name.count > maxChars ? String(entry.name.prefix(max(maxChars - 1, 1))) + "…" : entry.name
        let label = context.resolve(
            Text(name).font(Typo.caption.weight(.semibold)).foregroundStyle(textColor))
        var clipped = context
        clipped.clip(to: Path(tile.insetBy(dx: padding / 2, dy: Space.xxs)))
        clipped.draw(label, at: CGPoint(x: tile.minX + padding, y: tile.minY + Space.xs), anchor: .topLeading)
        if tile.height > Metric.treemapLabelMin.height * 2 {
            let sizeText = context.resolve(
                Text(SpaceMapView.bytes(entry.size)).font(Typo.caption.monospacedDigit()).foregroundStyle(
                    textColor.opacity(0.85)))
            clipped.draw(
                sizeText, at: CGPoint(x: tile.minX + padding, y: tile.minY + Space.xs + Space.m), anchor: .topLeading)
        }
    }

    /// A small trash button in the hovered block's corner, when the block is big enough.
    @ViewBuilder
    private func trashButton(rects: [CGRect], hovered: Int?) -> some View {
        if let hovered, entries.indices.contains(hovered), let index = entries[hovered].node,
            model.canTrash(index)
        {
            let tile = rects[hovered]
            let side = Metric.checkbox + Space.xxs
            if tile.width >= Metric.treemapLabelMin.width + side, tile.height >= side * 2 {
                let selectedCorner = model.isSelected(index) ? Metric.checkbox + Space.xs : 0
                Button {
                    Task { await model.requestTrash(index) }
                } label: {
                    Image(systemName: "trash")
                        .font(Typo.caption.weight(.bold))
                        .foregroundStyle(Palette.inkFixed)
                        .frame(width: side, height: side)
                        .background(Circle().fill(Palette.tomato))
                        .overlay(Circle().strokeBorder(Palette.inkFixed, lineWidth: Stroke.outline * 0.6))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Move “\(entries[hovered].name)” to the Trash…")
                .accessibilityLabel("Move \(entries[hovered].name) to the Trash")
                .offset(
                    x: tile.maxX - side - Space.xs - selectedCorner,
                    y: tile.minY + Space.xs)
            }
        }
    }

    @ViewBuilder
    private func tooltip(hovered: Int?) -> some View {
        if let hovered, entries.indices.contains(hovered) {
            let entry = entries[hovered]
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(entry.name)
                    .font(Typo.headline)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text("\(SpaceMapView.bytes(entry.size)) · \(entry.kindLabel)")
                    .font(Typo.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
                if entry.node != nil {
                    Text(
                        entry.canDrill
                            ? "Click to select · double-click to open" : "Click to select · right-click for more"
                    )
                    .font(Typo.caption)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
            .padding(Space.s)
            .frame(width: Metric.tooltipWidth, alignment: .leading)
            .inkSurface(Palette.paper, radius: Radius.small, shadow: Stroke.pressDepth)
            .offset(tooltipOffset(for: hovered))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Below-right of the pointer, flipped to stay inside the map. For a forced (DEBUG) hover the
    /// pointer is taken as the block's centre.
    private func tooltipOffset(for hovered: Int) -> CGSize {
        var point = pointer
        if self.hovered == nil, rects.indices.contains(hovered) {
            point = CGPoint(x: rects[hovered].midX, y: rects[hovered].midY)
        }
        let gap = Space.m
        let height = Space.xxxl + Space.l
        var x = point.x + gap
        var y = point.y + gap
        if x + Metric.tooltipWidth > size.width { x = point.x - Metric.tooltipWidth - gap }
        if y + height > size.height { y = point.y - height - gap }
        return CGSize(width: max(x, 0), height: max(y, 0))
    }
}

/// One block for VoiceOver: name, size and kind; selected trait; Select (default), Open, Move
/// to Trash, Reveal in Finder.
private struct TileAccessibility: View {
    let model: SpaceMapModel
    let entry: SpaceMapModel.Entry
    let animate: (@escaping () -> Void) -> Void

    var body: some View {
        let selected = entry.node.map(model.isSelected) ?? false
        Rectangle()
            .accessibilityElement()
            .accessibilityLabel("\(entry.name), \(SpaceMapView.bytes(entry.size)), \(entry.kindLabel)")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction {
                if let index = entry.node { model.setSelected(index, !selected) }
            }
            .accessibilityAction(named: "Open") {
                if let index = entry.node, entry.canDrill { animate { model.drill(into: index) } }
            }
            .accessibilityAction(named: "Move to Trash") {
                if let index = entry.node { Task { await model.requestTrash(index) } }
            }
            .accessibilityAction(named: "Reveal in Finder") {
                if let index = entry.node { model.reveal(index) }
            }
    }
}

/// Right-click actions for one item (map block or list row). Move to Trash acts on the whole
/// selection when the item is part of it.
private struct ItemMenu: View {
    let model: SpaceMapModel
    let index: UInt32
    let animate: (@escaping () -> Void) -> Void

    var body: some View {
        let inSelection = model.isSelected(index) && model.selection.count > 1
        if model.canDrill(index) {
            Button("Open") { animate { model.drill(into: index) } }
        }
        Button(model.isSelected(index) ? "Deselect" : "Select") { model.setSelected(index, !model.isSelected(index)) }
        Button("Reveal in Finder") { model.reveal(index) }
        Button(inSelection ? "Move \(model.selection.count) Selected Items to Trash…" : "Move to Trash…") {
            Task { await model.requestTrash(index) }
        }
        .disabled(!model.canTrash(index))
        Button(model.isIgnored(index) ? "Ignored" : "Ignore") { Task { await model.ignore(index) } }
            .disabled(model.isIgnored(index))
    }
}

// MARK: - Side list

private struct SideList: View {
    let model: SpaceMapModel
    let animate: (@escaping () -> Void) -> Void
    let showAccessSteps: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Biggest here")
                    .font(Typo.headline)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Top \(model.topItems.count) in \(model.title(of: model.current))")
                    .textStyle(.caption)
                    .lineLimit(1)
            }
            .padding(Space.m)
            Rectangle().fill(Palette.line).frame(height: Stroke.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.topItems, id: \.self) { index in
                        TopRow(model: model, index: index, animate: animate)
                    }
                }
                .padding(.vertical, Space.xxs)
            }
            notes
        }
        .inkSurface(Palette.paper, radius: Radius.medium, shadow: 0)
    }

    @ViewBuilder
    private var notes: some View {
        let access = model.needsAccessPaths
        if !access.isEmpty || model.protectedBytes > 0 {
            Rectangle().fill(Palette.line).frame(height: Stroke.hairline)
            VStack(alignment: .leading, spacing: Space.xs) {
                if !access.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Image(systemName: "lock").accessibilityHidden(true)
                        Text(
                            access.count == 1
                                ? "1 folder needs Full Disk Access: \(access[0])"
                                : "\(access.count) folders need Full Disk Access, so their size isn't shown."
                        )
                        .lineLimit(3)
                    }
                    .textStyle(.caption)
                    .help(access.joined(separator: "\n"))
                    Button("Show me how", action: showAccessSteps)
                        .buttonStyle(QuietLinkStyle())
                }
                if model.protectedBytes > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Image(systemName: "shield").accessibilityHidden(true)
                        Text(
                            "\(SpaceMapView.bytes(model.protectedBytes)) in places Dustpan never touches (measured, not listed)."
                        )
                        .lineLimit(3)
                    }
                    .textStyle(.caption)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One "Biggest here" row: checkbox (shares the map's selection), name and size, a trash button
/// (on hover, and always on a selected row), and an Open chevron for folders.
private struct TopRow: View {
    let model: SpaceMapModel
    let index: UInt32
    let animate: (@escaping () -> Void) -> Void
    @State private var hovering = false

    var body: some View {
        let kind = model.kind(index)
        let quiet = kind != .file && kind != .directory && kind != .link
        let selected = model.isSelected(index)
        let showsTrash = (hovering || selected) && model.canTrash(index)
        HStack(spacing: Space.xs) {
            InkCheckbox(
                isOn: Binding(get: { model.isSelected(index) }, set: { model.setSelected(index, $0) }),
                label: "Select \(model.name(index))")
            Button {
                if SpaceMapView.isDoubleClick, model.canDrill(index) {
                    animate { model.drill(into: index) }
                } else {
                    model.click(index, toggle: SpaceMapView.clickTogglesSelection)
                }
            } label: {
                HStack(spacing: Space.xs) {
                    RoundedRectangle(cornerRadius: Metric.swatch / 4, style: .continuous)
                        .fill(quiet ? Palette.line : model.fileKind(index).fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: Metric.swatch / 4, style: .continuous)
                                .strokeBorder(Palette.ink, lineWidth: Stroke.hairline)
                        )
                        .frame(width: Metric.swatch, height: Metric.swatch)
                    Text(model.name(index))
                        .font(Typo.body)
                        .foregroundStyle(model.isIgnored(index) ? Palette.secondaryText : Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.xxs)
                    Text(SpaceMapView.bytes(model.size(index)))
                        .font(Typo.caption.monospacedDigit())
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            Button {
                Task { await model.requestTrash(index) }
            } label: {
                Image(systemName: "trash")
                    .font(Typo.caption.weight(.bold))
                    .foregroundStyle(Palette.inkFixed)
                    .frame(width: Metric.checkbox, height: Metric.checkbox)
                    .background(Circle().fill(Palette.tomato))
                    .overlay(Circle().strokeBorder(Palette.inkFixed, lineWidth: Stroke.hairline))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(showsTrash ? 1 : 0)
            .disabled(!showsTrash)
            .help("Move “\(model.name(index))” to the Trash…")
            .accessibilityHidden(true)
            Button {
                animate { model.drill(into: index) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(Typo.caption.weight(.bold))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: Space.m, height: Metric.checkbox)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(model.canDrill(index) ? 1 : 0)
            .disabled(!model.canDrill(index))
            .help("Open")
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(selected ? Palette.line : hovering ? Palette.line.opacity(0.5) : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu { ItemMenu(model: model, index: index, animate: animate) }
        .help(model.displayPath(index))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(model.name(index)), \(SpaceMapView.bytes(model.size(index))), \(model.fileKind(index).title)"
                + (model.canDrill(index) ? ", folder" : "")
        )
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.setSelected(index, !selected) }
        .accessibilityAction(named: "Move to Trash") { Task { await model.requestTrash(index) } }
        .accessibilityAction(named: "Open") {
            if model.canDrill(index) { animate { model.drill(into: index) } }
        }
        .accessibilityAction(named: "Reveal in Finder") { model.reveal(index) }
        .accessibilityAction(named: "Ignore") { Task { await model.ignore(index) } }
    }
}

// MARK: - Confirm

/// The Move to Trash confirmation after the pre-check: what goes (size and names), what stays
/// with the Cleaner's reasons (grouped), and Quit buttons for open apps. No destructive button
/// when nothing may go.
private struct ConfirmMoveSheet: View {
    let model: SpaceMapModel
    let pending: SpaceMapModel.PendingTrash

    var body: some View {
        let allowed = pending.allowed
        InkSheet(title: title, onCancel: { model.cancelTrash() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if !allowed.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(summary)
                                .font(Typo.body.monospacedDigit())
                                .foregroundStyle(Palette.ink)
                                .lineLimit(3)
                                .truncationMode(.middle)
                            Text(
                                "You chose this yourself, so Dustpan can't say whether anything still needs it. It goes to the Trash: you can put it back from History or Finder until the Trash is emptied."
                            )
                            .textStyle(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(pending.blockingApps) { app in
                        HStack(spacing: Space.s) {
                            Text("Quit \(app.name) first — an open app can't be moved.")
                                .textStyle(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Space.xs)
                            InkButton("Quit \(app.name)", kind: .secondary, size: .small) {
                                Task { await model.quitBlockingApps() }
                            }
                            .disabled(model.runningApps.quitting.contains(app.bundleID))
                        }
                    }
                    if !pending.refused.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(allowed.isEmpty ? "Why" : "Staying where it is")
                                .textStyle(.headline)
                            SkippedGroupsView(
                                items: pending.refused.map { (url: $0.url, reason: $0.reason) },
                                title: { reason, count in
                                    if case .appRunning(let name) = reason {
                                        return count == 1 ? "Quit \(name) first" : "\(count) items: quit \(name) first"
                                    }
                                    return nil
                                },
                                showsHeader: false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Metric.sheetWidth * 0.75)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer()
                if allowed.isEmpty {
                    InkButton("Close", kind: .secondary) { model.cancelTrash() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    InkButton("Cancel", kind: .secondary) { model.cancelTrash() }
                        .keyboardShortcut(.cancelAction)
                    InkButton("Move \(SpaceMapView.bytes(pending.allowedBytes)) to Trash", systemImage: "trash") {
                        Task { await model.confirmTrash() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var title: String {
        let allowed = pending.allowed
        if allowed.isEmpty {
            return pending.refused.count == 1
                ? "“\(model.name(pending.refused[0].index))” can't go to the Trash"
                : "None of these can go to the Trash"
        }
        if allowed.count == 1 { return "Move “\(model.name(allowed[0]))” to the Trash?" }
        return "Move \(allowed.count) items to the Trash?"
    }

    private var summary: String {
        let allowed = pending.allowed
        let bytes = SpaceMapView.bytes(pending.allowedBytes)
        if allowed.count == 1 { return "\(bytes) · \(model.displayPath(allowed[0]))" }
        let names = allowed.prefix(3).map { model.name($0) }.joined(separator: ", ")
        let more = allowed.count > 3 ? " and \(allowed.count - 3) more" : ""
        return "\(bytes) · \(names)\(more)"
    }
}

#Preview {
    SpaceMapView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
