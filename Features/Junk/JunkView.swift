import SwiftUI

/// Junk screen: categories as tiles on the left, the chosen category's items on the right,
/// and a bottom bar that moves the selection to the Trash after a confirmation.
struct JunkView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.junk
        VStack(alignment: .leading, spacing: 0) {
            header(model)
            if let issue = model.issue {
                QuietBanner(
                    systemImage: "exclamationmark.circle", message: issue.localizedDescription, actionTitle: "OK",
                    action: { model.dismissIssue() }
                )
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.m)
            }
            if let left = model.trashLeft {
                QuietBanner(
                    systemImage: "trash", message: TrashCopy.leftLine(left), actionTitle: "OK",
                    action: { model.dismissEmptiedNote() }, secondaryTitle: "Open Trash in Finder",
                    secondaryAction: { model.showTrashInFinder() }
                )
                .padding(.horizontal, Space.xxl)
                .padding(.bottom, Space.m)
            }
            if let note = model.unticked, model.lastReport == nil {
                QuietBanner(
                    systemImage: "power", message: note, actionTitle: "OK", action: { model.dismissUnticked() }
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
            if model.isConfirming {
                ConfirmCleanSheet(model: model)
            } else if let app = model.quitPrompt {
                QuitAppSheet(
                    app: app, onCancel: { model.quitPrompt = nil },
                    onQuit: { Task { await model.confirmQuit() } })
            } else if let summary = model.trashToEmpty {
                EmptyTrashSheet(model: model, summary: summary)
            }
        }
    }

    private func header(_ model: JunkModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            ToneGlyph(tone: AppSection.junk.tone, size: Space.l)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text("Junk")
                .textStyle(.display)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.m)
            if model.hasScanned && model.lastReport == nil && !model.isScanning {
                InkButton("Look again", systemImage: "arrow.clockwise", kind: .secondary) {
                    Task { await model.scan(hasFullDiskAccess: appState.onboarding.hasFullDiskAccess) }
                }
                .disabled(model.isCleaning)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    @ViewBuilder
    private func content(_ model: JunkModel) -> some View {
        if let report = model.lastReport {
            JunkResultView(model: model, report: report) { appState.section = .history }
        } else if model.isScanning || model.isCleaning {
            WorkingView(model: model)
        } else if !model.hasScanned {
            ScrollView {
                EmptyState(
                    "Caches, logs and build files that apps make again on their own. Each one comes with the reason it's safe.",
                    actionTitle: "Look for junk",
                    actionSymbol: "magnifyingglass",
                    action: { Task { await model.scan(hasFullDiskAccess: appState.onboarding.hasFullDiskAccess) } }
                ) {
                    IllustrationView(kind: .junk)
                }
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.results.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    EmptyState("Nothing to clean right now. Apps haven't left anything worth removing.") {
                        IllustrationView(kind: .sweep)
                    }
                    accessNote(model)
                }
                .padding(.horizontal, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    // A narrow window (down to the 900 pt minimum) trades tile width for list width.
                    let roomy =
                        proxy.size.width - Space.xxl * 2 - Space.l - Metric.categoryColumnWidth
                        >= Metric.junkListComfortWidth
                    HStack(alignment: .top, spacing: Space.l) {
                        CategoryColumn(model: model, accessNote: accessNote(model))
                            .frame(width: roomy ? Metric.categoryColumnWidth : Metric.categoryColumnCompactWidth)
                        ItemList(model: model)
                    }
                    .padding(.horizontal, Space.xxl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                CleanBar(model: model)
            }
        }
    }

    /// "N categories need Full Disk Access", with the way to fix it.
    @ViewBuilder
    private func accessNote(_ model: JunkModel) -> some View {
        let count = model.skippedCategories.count
        if count > 0 {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(count == 1 ? "1 category needs Full Disk Access" : "\(count) categories need Full Disk Access")
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text("Without it, Dustpan skips the Trash, Downloads and other apps' folders.")
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show me how") { appState.onboarding.showAccessSteps() }
                    .buttonStyle(QuietLinkStyle())
                    .accessibilityLabel("Show me how to turn on Full Disk Access")
            }
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Categories

private struct CategoryColumn<Note: View>: View {
    let model: JunkModel
    let accessNote: Note

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                ForEach(model.results, id: \.category) { result in
                    Tile(
                        tone: Tone(rawValue: result.category.rawValue) ?? .trash,
                        bytes: result.totalBytes,
                        label: result.category.title,
                        detail: detail(result),
                        isSelected: model.focusedCategory == result.category,
                        compact: true
                    ) {
                        model.focusedCategory = result.category
                    }
                }
                accessNote
                    .padding(.top, Space.xs)
            }
            // Room for the tiles' offset shadows.
            .padding(.trailing, Stroke.shadowOffset)
            .padding(.bottom, Space.l)
        }
        .scrollIndicators(.never)
    }

    private func detail(_ result: ScanResult) -> String {
        let selected = model.selectedCount(in: result.category)
        let items = result.items.count == 1 ? "1 item" : "\(result.items.count) items"
        let base = selected == 0 ? "\(items), none selected" : "\(selected) of \(items) selected"
        if result.category == .trash, model.trashKeptBytes > 0 {
            return "\(base) · \(ByteFormat.string(model.trashKeptBytes)) needs Finder to empty"
        }
        let blocked = model.blockedCount(in: result.category)
        guard blocked > 0 else { return base }
        return "\(base) · \(blocked == 1 ? "1 needs" : "\(blocked) need") an app closed"
    }
}

// MARK: - Items

private struct ItemList: View {
    @Bindable var model: JunkModel
    @State private var hovered: UUID?
    @State private var inspected: UUID?
    @State private var showIgnored = false
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let category = model.focusedCategory, let result = model.result(for: category) {
                listHeader(category: category, result: result)
                controls(category: category)
                selectAllLine(category: category)
                rows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // ⌘I: details for the row under the pointer (or the first row).
            Button("Show details") {
                let id = hovered ?? model.focusedItemID ?? model.visibleItems.first?.id
                inspected = inspected == id ? nil : id
            }
            .keyboardShortcut("i", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// "12 MB of 40 MB selected"; for a Trash holding entries only Finder can delete, how much.
    private func headerCaption(category: JunkCategory, result: ScanResult) -> String {
        if category == .trash, model.trashKeptBytes > 0 {
            return "\(ByteFormat.string(model.trashKeptBytes)) needs Finder to empty"
        }
        return
            "\(ByteFormat.string(model.selectedBytes(in: category))) of \(ByteFormat.string(result.totalBytes)) selected"
    }

    private func listHeader(category: JunkCategory, result: ScanResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(category.title).font(Typo.title).foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            Text(headerCaption(category: category, result: result))
                .textStyle(.caption)
            Spacer(minLength: Space.s)
            if category == .trash {
                InkButton("Empty Trash…", systemImage: "trash", kind: .secondary) {
                    Task { await model.requestEmptyTrash() }
                }
            }
            if !model.ignored.isEmpty {
                Button("\(model.ignored.count) ignored") { showIgnored = true }
                    .buttonStyle(QuietLinkStyle())
                    .popover(isPresented: $showIgnored, arrowEdge: .bottom) { IgnoredList(model: model) }
                    .accessibilityLabel("\(model.ignored.count) ignored items and rules")
            }
        }
    }

    /// Search, risk filter and sort on one line; on two lines when the list is narrow.
    private func controls(category: JunkCategory) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) {
                SearchField(text: $model.searchText)
                Spacer(minLength: Space.s)
                pickers
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                SearchField(text: $model.searchText)
                HStack(spacing: Space.s) {
                    pickers
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .inkSurface(Palette.paper, radius: Radius.small, shadow: 0)
    }

    @ViewBuilder
    private var pickers: some View {
        Picker("Show", selection: $model.riskFilter) {
            ForEach(JunkModel.RiskFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Show by risk")
        Picker("Sort by", selection: $model.sort) {
            ForEach(JunkModel.Sort.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Sort by")
    }

    /// "Select all safe" acts on the visible (filtered, searched) rows; it skips rows whose app is
    /// open and says how many.
    private func selectAllLine(category: JunkCategory) -> some View {
        let title = model.riskFilter.selectAllTitle
        return HStack(spacing: Space.s) {
            InkCheckbox(
                isOn: Binding(get: { model.allVisibleSelected }, set: { model.setAllVisibleSelected($0) }),
                label: "\(title) in \(category.title)")
            Text(title).textStyle(.body)
                .onTapGesture { model.setAllVisibleSelected(!model.allVisibleSelected) }
                .accessibilityHidden(true)
            if model.skippedScope == .list, let note = model.skippedNote {
                Text(note).textStyle(.caption).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
    }

    /// Keyboard: Tab into the list, ↑/↓ move between rows, space ticks the row, ⌘I shows details.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    let items = model.visibleItems
                    if items.isEmpty {
                        Text(emptyText)
                            .textStyle(.body)
                            .padding(Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(.bottom, Space.m)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.space) {
                model.toggleFocused()
                if let id = model.focusedItemID { proxy.scrollTo(id) }
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.moveFocus(by: 1)
                if let id = model.focusedItemID { proxy.scrollTo(id) }
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.moveFocus(by: -1)
                if let id = model.focusedItemID { proxy.scrollTo(id) }
                return .handled
            }
            .accessibilityLabel("Items")
        }
    }

    private var emptyText: String {
        if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Nothing matches “\(model.searchText)”."
        }
        switch model.riskFilter {
        case .all: return "Nothing here."
        case .safe: return "Nothing marked safe in this category."
        case .review: return "Nothing to review in this category."
        }
    }

    private func row(_ item: ScanItem) -> some View {
        let rule = model.rule(for: item)
        let blocker = model.blocker(for: item).map { app in
            ExplainRow.Blocker(
                appName: app.name, quit: app.bundleID.isEmpty ? nil : { model.requestQuit(app) },
                isQuitting: model.runningApps.quitting.contains(app.bundleID))
        }
        let why =
            item.detectionOnly
            ? (rule?.why ?? "Shown for information only.") : (rule?.why ?? "Found by a cleaning rule.")
        return ExplainRow(
            isSelected: Binding(get: { model.isSelected(item) }, set: { model.setSelected(item, $0) }),
            systemImage: item.category.symbol,
            tone: Tone(rawValue: item.category.rawValue) ?? .trash,
            name: JunkModel.name(of: item),
            bytes: item.allocatedSize,
            why: why,
            risk: item.risk == .safe ? .safe : .review,
            detail: Self.relative(item.modified),
            selectable: model.isSelectable(item),
            help: "\(why)\n\(model.displayPath(item.url))",
            info: { inspected = inspected == item.id ? nil : item.id },
            blocker: blocker
        )
        .background(model.focusedItemID == item.id && listFocused ? Palette.line : Color.clear)
        .overlay(alignment: .leading) {
            if model.focusedItemID == item.id && listFocused {
                Rectangle().fill(Palette.cobalt).frame(width: Stroke.outline * 2)
                    .accessibilityHidden(true)
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                model.focusedItemID = item.id
                listFocused = true
            }
        )
        .onHover { inside in
            if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
        }
        .popover(
            isPresented: Binding(
                get: { inspected == item.id }, set: { if !$0, inspected == item.id { inspected = nil } }),
            arrowEdge: .leading
        ) {
            ItemDetails(model: model, item: item)
        }
        .contextMenu {
            Button("Show Details") { inspected = item.id }
            Divider()
            Button("Ignore This Item") { Task { await model.ignore(item) } }
            if let rule {
                Button("Ignore Everything in “\(rule.title)”") { Task { await model.ignoreRule(of: item) } }
            }
        }
        .accessibilityAction(named: "Show details") { inspected = item.id }
        .accessibilityAction(named: "Ignore this item") { Task { await model.ignore(item) } }
    }

    static func relative(_ date: Date) -> String {
        guard date > .distantPast else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// The full story of one item: why, rule, source, path.
private struct ItemDetails: View {
    let model: JunkModel
    let item: ScanItem

    var body: some View {
        let rule = model.rule(for: item)
        VStack(alignment: .leading, spacing: Space.s) {
            Text(JunkModel.name(of: item)).textStyle(.headline)
            Text(rule?.why ?? "Found by a cleaning rule.")
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            if item.detectionOnly {
                Text("Shown for information only. Dustpan doesn't move this.")
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.excludedURLs.isEmpty {
                Text(
                    "\(item.excludedURLs.count == 1 ? "1 folder" : "\(item.excludedURLs.count) folders") inside stay put: another rule looks after them."
                )
                .textStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Palette.line).frame(height: Stroke.hairline)
            detailLine("Where", model.displayPath(item.url))
            detailLine("Rule", rule?.title ?? item.ruleID)
            detailLine("Source", rule?.source ?? "—")
            detailLine("Last changed", item.modified.formatted(date: .abbreviated, time: .shortened))
            if rule?.requiresQuit == true {
                Text("Its app has to be closed before this can be moved.")
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.m)
        .frame(width: Metric.popoverWidth, alignment: .leading)
        .background(Palette.paper)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(label).textStyle(.caption)
            Spacer(minLength: Space.s)
            Text(value)
                .font(Typo.caption)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IgnoredList: View {
    let model: JunkModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Ignored").textStyle(.headline)
            Text("Dustpan won't suggest these. Stop ignoring one and it shows up on the next scan.")
                .textStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.ignored) { entry in
                HStack(spacing: Space.s) {
                    Text(model.ignoreTitle(entry))
                        .textStyle(.body)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: Space.s)
                    Button("Stop ignoring") { Task { await model.stopIgnoring(entry) } }
                        .buttonStyle(QuietLinkStyle())
                }
            }
        }
        .padding(Space.m)
        .frame(width: Metric.popoverWidth, alignment: .leading)
        .background(Palette.paper)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.ink)
                .accessibilityLabel("Search items")
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .frame(minWidth: Metric.searchMinWidth, maxWidth: Metric.searchWidth)
        .background(
            RoundedRectangle(cornerRadius: Radius.small / 2, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.4), lineWidth: Stroke.hairline))
    }
}

// MARK: - Bottom bar

private struct CleanBar: View {
    let model: JunkModel

    var body: some View {
        let count = model.selection.count
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(count == 1 ? "1 item selected" : "\(count) items selected").textStyle(.headline)
                    .lineLimit(1)
                if model.skippedScope == .everywhere, let note = model.skippedNote {
                    Text(note).textStyle(.caption).lineLimit(1)
                } else if model.showsTrashNote {
                    TrashNote(emptyTrash: model.emptyTrashAction)
                } else {
                    Text("Everything goes to the Trash first.").textStyle(.caption).lineLimit(1)
                }
            }
            Spacer(minLength: Space.m)
            // Every category at once: safe items only, never "Review" ones or ones whose app is open.
            InkButton("Select all safe", kind: .secondary, size: .small) { model.selectAllSafe() }
                .disabled(!model.canSelectAllSafe || model.isCleaning)
                .accessibilityHint("Ticks every item marked safe, in every category, except ones whose app is open")
            InkButton(
                model.selectedBytes == 0 ? "Move to Trash" : "Move \(ByteFormat.string(model.selectedBytes)) to Trash",
                systemImage: "trash"
            ) {
                model.requestClean()
            }
            .disabled(count == 0 || model.isCleaning)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
    }
}

// MARK: - Working

private struct WorkingView: View {
    let model: JunkModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ProgressBlob(progress: model.isCleaning ? 1 : (model.progress?.fraction ?? 0), tone: .dev)
            if model.isCleaning {
                Text("Moving to the Trash…").font(Typo.title).foregroundStyle(Palette.ink)
            } else {
                Text("Looking through caches and logs…").font(Typo.title).foregroundStyle(Palette.ink)
                if let progress = model.progress, progress.totalItems > 0 {
                    Text(
                        "\(progress.completedItems) of \(progress.totalItems) places checked · \(ByteFormat.string(progress.bytesFound)) found"
                    )
                    .font(Typo.body.monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
                }
            }
        }
        .padding(.horizontal, Space.xxl)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confirmations

private struct ConfirmCleanSheet: View {
    let model: JunkModel

    var body: some View {
        let groups = model.blockedGroups
        let quitting = !model.runningApps.quitting.isDisjoint(with: groups.map(\.app.bundleID))
        CleanConfirmSheet(
            bytes: model.movableBytes, lines: model.summary,
            blocked: groups.isEmpty
                ? nil
                : BlockedSection(
                    groups: groups, stillOpen: model.stillOpen, isQuitting: quitting,
                    quitAll: { Task { await model.quitBlockedApps() } }, leave: { model.leaveBlocked() }),
            onCancel: { model.cancelClean() },
            onConfirm: { Task { await model.confirmClean() } })
    }
}

private struct EmptyTrashSheet: View {
    let model: JunkModel
    let summary: TrashSummary

    var body: some View {
        if summary.hasDeletable {
            mixed
        } else {
            finderOnly
        }
    }

    /// Something Dustpan can delete, perhaps plus things only Finder can.
    private var mixed: some View {
        InkSheet(title: "Empty \(ByteFormat.string(summary.bytes)) from the Trash?", onCancel: cancel) {
            Text(
                "This permanently deletes \(summary.names.count == 1 ? "1 item" : "\(summary.names.count) items") (\(ByteFormat.string(summary.bytes))). Unlike everything else in Dustpan, this can't be undone, and History can't put them back."
            )
            .textStyle(.body)
            .fixedSize(horizontal: false, vertical: true)
            if !summary.kept.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(TrashCopy.keptLine(summary.kept, more: true))
                        .textStyle(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Trash in Finder") { model.showTrashInFinder() }
                        .buttonStyle(QuietLinkStyle())
                }
            }
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Cancel", kind: .secondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Empty Trash (\(ByteFormat.string(summary.bytes)))", systemImage: "trash") {
                    Task { await model.confirmEmptyTrash() }
                }
            }
        }
    }

    /// Nothing Dustpan may delete: no destructive button at all, only the way to Finder.
    private var finderOnly: some View {
        InkSheet(title: "Only Finder can empty this Trash", onCancel: cancel) {
            Text(TrashCopy.keptLine(summary.kept, more: false))
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Close", kind: .secondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Open Trash in Finder", systemImage: "folder") { model.showTrashInFinder() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func cancel() { model.trashToEmpty = nil }
}

/// Plain words for Trash entries only Finder can delete.
enum TrashCopy {
    /// "1.05 GB more was put there with your password (apps installed for all users) — only
    /// Finder can delete that." (`more: false` → "Everything in it (1.05 GB) …").
    static func keptLine(_ kept: [TrashLeftEntry], more: Bool) -> String {
        let bytes = ByteFormat.string(kept.reduce(0) { $0 + $1.bytes })
        let locked = kept.contains { $0.reason == .locked }
        let password = kept.contains { $0.reason != .locked }
        let why: String
        switch (locked, password) {
        case (true, false): why = "is locked"
        case (true, true): why = "is locked or was put there with your password"
        default: why = "was put there with your password (apps installed for all users)"
        }
        return more
            ? "\(bytes) more \(why) — only Finder can delete that."
            : "Everything in it (\(bytes)) \(why), so macOS only lets Finder delete it."
    }

    /// The calm note after an Empty Trash that left something.
    static func leftLine(_ report: EmptyTrashReport) -> String {
        let left = "\(ByteFormat.string(report.leftBytes)) is still in the Trash — macOS only lets Finder delete it."
        return report.freedBytes > 0 ? "Deleted \(ByteFormat.string(report.freedBytes)). \(left)" : left
    }
}

// MARK: - Result

private struct JunkResultView: View {
    let model: JunkModel
    let report: CleanReport
    let openHistory: () -> Void

    var body: some View {
        CleanResultView(
            report: report, undoDeadline: model.undoDeadline, undo: { await model.undoLastClean() },
            done: { model.dismissResult() }, openHistory: openHistory, emptyTrash: model.emptyTrashAction)
    }
}

extension JunkModel {
    /// Opens the Empty Trash confirmation, when the Trash could be read (its tile is shown).
    var emptyTrashAction: (() -> Void)? {
        guard result(for: .trash) != nil else { return nil }
        return { [self] in Task { await self.requestEmptyTrash() } }
    }
}

extension JunkCategory {
    /// SF Symbol for rows in this category.
    var symbol: String {
        switch self {
        case .userCache: "shippingbox"
        case .logs: "doc.text"
        case .savedState: "macwindow"
        case .dev: "hammer"
        case .ai: "sparkles"
        case .installers: "arrow.down.circle"
        case .trash: "trash"
        case .xcode: "chevron.left.forwardslash.chevron.right"
        }
    }
}

#Preview {
    JunkView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
