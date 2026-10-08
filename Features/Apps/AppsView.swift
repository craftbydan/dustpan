import SwiftUI

/// Apps screen: installed apps with their leftovers and Uninstall, and a second tab for
/// leftovers of apps that are already gone.
struct AppsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.apps
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
            content(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .overlay {
            if let name = model.quitPromptName {
                QuitFirstSheet(model: model, name: name)
            } else if model.isConfirmingUninstall, let app = model.selectedApp {
                ConfirmUninstallSheet(model: model, app: app)
            } else if model.isConfirmingOrphans {
                ConfirmOrphansSheet(model: model)
            } else if let gone = model.gone {
                GoneLeftoversSheet(model: model, prompt: gone)
            }
        }
        // An app being removed in Finder (or the one shown) may have disappeared: look again when
        // Dustpan comes back to the front or an app quits. One `lstat` each; no timer.
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await model.checkForRemovedApps()
            }
        }
        .task {
            let center = NSWorkspace.shared.notificationCenter
            for await _ in center.notifications(named: NSWorkspace.didTerminateApplicationNotification) {
                await model.checkForRemovedApps()
            }
        }
    }

    private var access: Bool { appState.onboarding.hasFullDiskAccess }

    private func header(_ model: AppsModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                ToneGlyph(tone: AppSection.apps.tone, size: Space.l)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text("Apps")
                    .textStyle(.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.m)
                if model.hasLoaded && model.lastReport == nil && !model.isLoading {
                    InkButton(
                        model.tab == .updates ? "Check again" : "Look again", systemImage: "arrow.clockwise",
                        kind: .secondary
                    ) {
                        Task {
                            switch model.tab {
                            case .installed: await model.load(hasFullDiskAccess: access)
                            case .leftovers: await model.loadOrphans(hasFullDiskAccess: access)
                            case .updates: await appState.updates.check(apps: model.apps)
                            }
                        }
                    }
                    .disabled(model.isWorking || (model.tab == .updates && appState.updates.isChecking))
                    .accessibilityLabel(model.tab == .updates ? "Check for updates again" : "Look again")
                }
            }
            if model.hasLoaded && model.lastReport == nil {
                InkTabs(tabs: AppsModel.Tab.allCases.map { ($0, $0.title) }, selection: $model.tab)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    @ViewBuilder
    private func content(_ model: AppsModel) -> some View {
        if let report = model.lastReport {
            AppsResultView(model: model, report: report) { appState.section = .history }
        } else if model.isWorking {
            AppsWorkingView(title: "Moving to the Trash…")
        } else if !model.hasLoaded {
            if model.isLoading {
                AppsWorkingView(title: "Listing your apps…")
            } else {
                ScrollView {
                    EmptyState(
                        "Every app with its size and when you last opened it. Remove one together with the files it left behind.",
                        actionTitle: "List my apps",
                        actionSymbol: "square.grid.2x2",
                        action: { Task { await model.load(hasFullDiskAccess: access) } }
                    ) {
                        IllustrationView(kind: .apps)
                    }
                    .padding(.horizontal, Space.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if model.tab == .installed {
            InstalledTab(model: model)
        } else if model.tab == .updates {
            UpdatesTab(model: appState.updates, apps: model)
        } else {
            LeftoversTab(model: model, hasFullDiskAccess: access) {
                appState.onboarding.showAccessSteps()
            }
        }
    }
}

// MARK: - Installed

private struct InstalledTab: View {
    @Bindable var model: AppsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.l) {
                AppList(model: model)
                    .frame(width: Metric.appListWidth)
                if let app = model.selectedApp {
                    AppDetail(model: model, app: app)
                } else {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(summary).textStyle(.headline)
                        Text(
                            "Choose an app to see its size, the files it keeps around your Mac, and how to remove it all."
                        )
                        .textStyle(.body)
                        .lineLimit(4)
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .inkSurface(Palette.paper, radius: Radius.medium, shadow: 0)
                }
            }
            .padding(.horizontal, Space.xxl)
            .frame(maxHeight: .infinity, alignment: .top)
            if let app = model.selectedApp {
                if model.isDustpan(app) {
                    SelfRemovalBar()
                } else if app.needsAdminToRemove {
                    FinderRemovalBar(model: model, app: app)
                } else {
                    UninstallBar(model: model, app: app)
                }
            }
        }
    }

    private var summary: String {
        let count = model.apps.count == 1 ? "1 app" : "\(model.apps.count) apps"
        let unused = model.unusedCount
        let unusedBytes = ByteFormat.string(model.unusedBytes)
        let unusedText =
            unused == 0
            ? ""
            : unused == 1
                ? ", 1 unused for 6 months (\(unusedBytes))" : ", \(unused) unused for 6 months (\(unusedBytes))"
        return "\(count) · \(ByteFormat.string(model.totalAppBytes))\(unusedText)"
    }
}

private struct AppList: View {
    @Bindable var model: AppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                SearchBox(text: $model.searchText, label: "Search apps")
                Picker("Sort", selection: $model.sort) {
                    ForEach(AppsModel.Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .font(Typo.body)
                .fixedSize()
                .accessibilityLabel("Sort apps by")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    let apps = model.visibleApps
                    if apps.isEmpty {
                        Text(model.apps.isEmpty ? "No apps found." : "Nothing matches “\(model.searchText)”.")
                            .textStyle(.body)
                            .padding(Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(apps) { app in
                        AppRow(model: model, app: app, isSelected: model.selectedAppID == app.id) {
                            Task { await model.select(app) }
                        }
                    }
                }
                .padding(.bottom, Space.m)
            }
        }
    }
}

private struct AppRow: View {
    let model: AppsModel
    let app: AppRecord
    let isSelected: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        Button(action: select) {
            HStack(spacing: Space.s) {
                AppIcon(model: model, app: app, side: Metric.rowIcon)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(app.name).textStyle(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.xs)
                        Text(ByteFormat.string(app.size))
                            .font(Typo.headline.monospacedDigit())
                            .foregroundStyle(Palette.ink)
                            .fixedSize()
                    }
                    HStack(spacing: Space.xs) {
                        Text(AppDates.lastUsed(app.lastUsed)).textStyle(.caption).lineLimit(1)
                            .layoutPriority(-1)
                        Spacer(minLength: 0)
                        if app.needsAdminToRemove {
                            InkBadge(text: "For all users", tone: .settings)
                        }
                        if model.isUnused(app) {
                            InkBadge(text: "Unused 6 months", tone: .sweep)
                        }
                    }
                }
            }
            .padding(.vertical, Space.xs)
            .padding(.horizontal, Space.s)
            .background {
                if isSelected {
                    shape.fill(AppSection.apps.tone.fill.opacity(0.22))
                        .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
                } else if hovering {
                    shape.fill(Palette.line)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                app.name, ByteFormat.string(app.size), AppDates.lastUsed(app.lastUsed),
                model.isUnused(app) ? "Unused for 6 months" : nil,
                app.needsAdminToRemove ? "Installed for all users" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

private struct AppDetail: View {
    let model: AppsModel
    let app: AppRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .center, spacing: Space.m) {
                    AppIcon(model: model, app: app, side: Metric.appIconLarge)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(app.name).font(Typo.title).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(facts).textStyle(.caption).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: 0) {
                    CompactRow(
                        isSelected: .constant(!model.isDustpan(app)), selectable: false, systemImage: "app.dashed",
                        tone: .apps,
                        name: app.url.lastPathComponent, bytes: app.size,
                        why: model.isDustpan(app)
                            ? "Dustpan itself. Quit it, then drag it to the Trash in Finder."
                            : app.needsAdminToRemove
                                ? "The app itself. Installed for all users, so it's removed in Finder."
                                : "The app itself. Always moved when you uninstall.",
                        place: model.displayPath(app.url.deletingLastPathComponent()), risk: nil,
                        help: model.displayPath(app.url))
                    leftoverRows
                }
                notes
            }
            .padding(.bottom, Space.l)
        }
        // Cheap re-check: the app may have been removed meanwhile.
        .task(id: app.id) { await model.checkForRemovedApps() }
    }

    private var facts: String {
        var parts = [app.version.isEmpty ? nil : "Version \(app.version)", app.bundleID]
        if let team = app.teamID { parts.append("Team \(team)") }
        parts.append(AppDates.lastUsed(app.lastUsed))
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var leftoverRows: some View {
        if model.isLoadingLeftovers || model.leftovers == nil {
            Text("Looking for files it left around your Mac…")
                .textStyle(.body)
                .padding(Space.m)
        } else if let scan = model.leftovers {
            ForEach(scan.matches) { match in
                LeftoverRow(
                    match: match, path: model.displayPath(match.url), compact: true,
                    isSelected: Binding(
                        get: { model.isLeftoverSelected(match) }, set: { model.setLeftover(match, selected: $0) }))
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let scan = model.leftovers {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if scan.matches.isEmpty {
                    Text("No other files found for this app.").textStyle(.body)
                } else if app.needsAdminToRemove {
                    Text(
                        "\(scan.matches.count == 1 ? "1 related item" : "\(scan.matches.count) related items"), \(ByteFormat.string(model.leftoverBytes)). They stay until the app is gone; then Dustpan offers to remove them."
                    )
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        "\(scan.matches.count == 1 ? "1 related item" : "\(scan.matches.count) related items"), \(ByteFormat.string(model.leftoverBytes)). Guesses and protected items start unticked."
                    )
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !scan.skippedFolders.isEmpty {
                    Text(
                        "Without Full Disk Access, Dustpan didn't look in \(ListFormatter.localizedString(byJoining: scan.skippedFolders)), so some files may be missing."
                    )
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One leftover: what it is, why Dustpan thinks it belongs, and whether it can move.
private struct LeftoverRow: View {
    let match: LeftoverMatch
    let path: String
    var compact = false
    @Binding var isSelected: Bool

    var body: some View {
        let why = match.status.explanation.map { "\(match.explanation) \($0)" } ?? match.explanation
        if compact {
            CompactRow(
                isSelected: $isSelected, selectable: match.isRemovable,
                systemImage: LeftoverRow.symbol(for: match.folderTitle),
                tone: match.isRemovable ? .userCache : .trash, name: match.url.lastPathComponent, bytes: match.size,
                why: match.isRemovable ? match.explanation : (match.status.explanation ?? match.explanation),
                place: match.folderTitle,
                risk: match.confidence == .high && match.isRemovable ? .safe : .review, help: "\(why)\n\(path)")
        } else {
            full(why: why)
        }
    }

    private func full(why: String) -> some View {
        ExplainRow(
            isSelected: $isSelected,
            systemImage: LeftoverRow.symbol(for: match.folderTitle),
            tone: match.isRemovable ? .userCache : .trash,
            name: match.url.lastPathComponent,
            bytes: match.size,
            why: match.isRemovable ? match.explanation : (match.status.explanation ?? match.explanation),
            risk: match.confidence == .high && match.isRemovable ? .safe : .review,
            detail: match.folderTitle,
            selectable: match.isRemovable,
            help: "\(why)\n\(path)"
        )
    }

    static func symbol(for folder: String) -> String {
        switch folder {
        case "Caches": "shippingbox"
        case "Preferences": "slider.horizontal.3"
        case "Containers", "Group Containers": "archivebox"
        case "Saved Application State": "macwindow"
        case "Logs": "doc.text"
        case "LaunchAgents", "LaunchDaemons": "bolt"
        case "Cookies", "HTTPStorages", "WebKit": "globe"
        default: "folder"
        }
    }
}

private struct UninstallBar: View {
    let model: AppsModel
    let app: AppRecord

    var body: some View {
        let count = model.selectedLeftovers.count
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(count == 0 ? "\(app.name) only" : "\(app.name) and \(count == 1 ? "1 item" : "\(count) items")")
                    .textStyle(.headline)
                Text("Everything goes to the Trash first. Dustpan asks before quitting the app.").textStyle(.caption)
            }
            Spacer(minLength: Space.m)
            InkButton("Uninstall \(ByteFormat.string(model.uninstallBytes))", systemImage: "trash") {
                model.requestUninstall()
            }
            .disabled(model.isWorking || model.isLoadingLeftovers)
            .accessibilityLabel("Uninstall \(app.name), \(ByteFormat.string(model.uninstallBytes))")
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
    }
}

/// For Dustpan itself: no Uninstall (asking it to quit first would only close Dustpan), just how.
private struct SelfRemovalBar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("This is Dustpan.").textStyle(.headline)
            Text("It can't remove itself while it's open. Quit Dustpan, then drag it to the Trash in Finder.")
                .textStyle(.caption)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
    }
}

/// For an app installed for all users: no Uninstall (it would fail without a password), but the
/// way forward: Finder removes it after asking for the password, and Dustpan notices.
private struct FinderRemovalBar: View {
    let model: AppsModel
    let app: AppRecord

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) {
                text
                Spacer(minLength: Space.m)
                button
            }
            VStack(alignment: .leading, spacing: Space.s) {
                text
                button
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Installed for all users. macOS needs your password to remove it.")
                .textStyle(.headline)
                .lineLimit(2)
            Text(
                model.finderRemovalApp?.id == app.id
                    ? "Drag it to the Trash in Finder — it will ask for your password. Dustpan is watching and will offer to remove its leftovers."
                    : "Drag it to the Trash in Finder — it will ask for your password. Dustpan will notice and offer to remove its leftovers."
            )
            .textStyle(.caption)
            .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }

    private var button: some View {
        InkButton("Show in Finder", systemImage: "folder") { model.showInFinder(app) }
            .accessibilityLabel("Show \(app.name) in Finder")
            .accessibilityHint("Drag it to the Trash there; Finder asks for your password")
    }
}

// MARK: - Leftovers of deleted apps

private struct LeftoversTab: View {
    let model: AppsModel
    let hasFullDiskAccess: Bool
    let showAccessSteps: () -> Void

    var body: some View {
        Group {
            if model.isLoadingOrphans || model.orphans == nil {
                AppsWorkingView(title: "Looking for files of apps that are gone…")
            } else if let scan = model.orphans {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(
                            "Files named after apps that aren't on this Mac any more, untouched for at least a month. They're guesses, so none is ticked: tick each one you're sure about."
                        )
                        .textStyle(.body)
                        .lineLimit(3)
                        if !scan.removable.isEmpty {
                            Text(
                                "\(scan.removable.count == 1 ? "1 can be moved" : "\(scan.removable.count) can be moved") · \(ByteFormat.string(scan.removableBytes))"
                            )
                            .font(Typo.headline.monospacedDigit())
                            .foregroundStyle(Palette.ink)
                        }
                        accessNote(scan)
                        if scan.matches.isEmpty {
                            ScrollView {
                                EmptyState("No leftovers from deleted apps right now.") {
                                    IllustrationView(kind: .sweep)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(scan.matches) { match in
                                        LeftoverRow(
                                            match: match, path: model.displayPath(match.url),
                                            isSelected: Binding(
                                                get: { model.isOrphanSelected(match) },
                                                set: { model.setOrphan(match, selected: $0) }))
                                    }
                                }
                                .padding(.bottom, Space.m)
                            }
                        }
                    }
                    .padding(.horizontal, Space.xxl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if !scan.matches.isEmpty { OrphanBar(model: model) }
                }
            }
        }
        .task {
            if model.orphans == nil { await model.loadOrphans(hasFullDiskAccess: hasFullDiskAccess) }
        }
    }

    @ViewBuilder
    private func accessNote(_ scan: LeftoverScan) -> some View {
        if !scan.skippedFolders.isEmpty {
            HStack(spacing: Space.s) {
                Text(
                    "Without Full Disk Access, Dustpan didn't look in \(ListFormatter.localizedString(byJoining: scan.skippedFolders))."
                )
                .textStyle(.caption)
                .lineLimit(3)
                Button("Show me how", action: showAccessSteps)
                    .buttonStyle(QuietLinkStyle())
                    .accessibilityLabel("Show me how to turn on Full Disk Access")
            }
        }
    }
}

private struct OrphanBar: View {
    let model: AppsModel

    var body: some View {
        let count = model.selectedOrphans.count
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(count == 1 ? "1 item selected" : "\(count) items selected").textStyle(.headline)
                Text("Everything goes to the Trash first.").textStyle(.caption)
            }
            Spacer(minLength: Space.m)
            InkButton(
                model.selectedOrphanBytes == 0
                    ? "Move to Trash" : "Move \(ByteFormat.string(model.selectedOrphanBytes)) to Trash",
                systemImage: "trash"
            ) {
                model.requestRemoveOrphans()
            }
            .disabled(count == 0 || model.isWorking)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
    }
}

// MARK: - Shared pieces

/// A two-line row for the narrow app detail: checkbox, icon, name and size on top; the reason,
/// risk and folder below (wrapping instead of truncating).
private struct CompactRow: View {
    @Binding var isSelected: Bool
    let selectable: Bool
    let systemImage: String
    let tone: Tone
    let name: String
    let bytes: Int64
    let why: String
    let place: String
    let risk: RiskLevel?
    let help: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            // Always-included (the app itself) stays fully visible; listing-only rows are dimmed.
            InkCheckbox(isOn: $isSelected, label: name)
                .disabled(!selectable)
                .opacity(selectable || isSelected ? 1 : 0.35)
            Image(systemName: systemImage)
                .fontWeight(.semibold)
                .foregroundStyle(tone.onFill)
                .frame(width: Metric.rowIcon, height: Metric.rowIcon)
                .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(tone.fill))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .strokeBorder(Palette.ink, lineWidth: Stroke.outline * 0.8)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    Text(name).textStyle(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.xs)
                    Text(ByteFormat.string(bytes))
                        .font(Typo.headline.monospacedDigit())
                        .foregroundStyle(Palette.ink)
                        .fixedSize()
                }
                Text(why).textStyle(.caption).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.xs) {
                    if let risk { RiskPill(risk: risk) }
                    Text(place).textStyle(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.s)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
        .contentShape(Rectangle())
        .onTapGesture { if selectable { isSelected.toggle() } }
        .help(help)
        .accessibilityElement(children: .combine)
    }
}

private struct SearchBox: View {
    @Binding var text: String
    let label: String

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.ink)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.small / 2, style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.4), lineWidth: Stroke.hairline))
    }
}

struct AppsWorkingView: View {
    let title: String
    var progress = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            ProgressBlob(progress: progress, tone: .apps)
            Text(title).font(Typo.title).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

enum AppDates {
    static func lastUsed(_ date: Date?) -> String {
        guard let date else { return "No record of last use" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Last used \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

// MARK: - Confirmations

private struct QuitFirstSheet: View {
    let model: AppsModel
    let name: String

    var body: some View {
        InkSheet(title: "Quit \(name) first?", onCancel: cancel) {
            Text(
                "\(name) is open. Dustpan will ask it to quit, the same as choosing Quit from its menu. If it has unsaved work, it will ask you first."
            )
            .textStyle(.body)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Cancel", kind: .secondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Quit \(name)", systemImage: "power") {
                    Task { await model.confirmQuit() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func cancel() { model.quitPromptName = nil }
}

private struct ConfirmUninstallSheet: View {
    let model: AppsModel
    let app: AppRecord

    var body: some View {
        let leftovers = model.selectedLeftovers
        InkSheet(title: "Uninstall \(app.name)?", onCancel: cancel) {
            VStack(alignment: .leading, spacing: 0) {
                line(app.url.lastPathComponent, detail: "the app", bytes: app.size)
                if !leftovers.isEmpty {
                    line(
                        leftovers.count == 1 ? "1 related item" : "\(leftovers.count) related items",
                        detail: "caches, settings and other files", bytes: leftovers.reduce(0) { $0 + $1.size })
                }
            }
            Text("Everything goes to the Trash. You can put it back from History until the Trash is emptied.")
                .textStyle(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Cancel", kind: .secondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Uninstall", systemImage: "trash") {
                    Task { await model.confirmUninstall() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func line(_ title: String, detail: String, bytes: Int64) -> some View {
        HStack(spacing: Space.s) {
            ToneGlyph(tone: .apps)
            Text(title).textStyle(.body)
            Text(detail).textStyle(.caption)
            Spacer(minLength: Space.s)
            Text(ByteFormat.string(bytes)).font(Typo.headline.monospacedDigit()).foregroundStyle(Palette.ink)
        }
        .padding(.vertical, Space.xs)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
        .accessibilityElement(children: .combine)
    }

    private func cancel() { model.isConfirmingUninstall = false }
}

/// "Microsoft Teams is gone. Remove its 14 leftovers (80 MB)?" — after the user removed an app
/// installed for all users in Finder. Selection rules as for an uninstall (guesses unticked).
private struct GoneLeftoversSheet: View {
    let model: AppsModel
    let prompt: AppsModel.GonePrompt

    var body: some View {
        let removable = prompt.scan.matches.filter(\.isRemovable)
        let bytes = removable.reduce(Int64(0)) { $0 + $1.size }
        let count = removable.count
        InkSheet(
            title: count == 0
                ? "\(prompt.app.name) is gone."
                : "\(prompt.app.name) is gone. Remove its \(count == 1 ? "leftover" : "\(count) leftovers") (\(ByteFormat.string(bytes)))?",
            onCancel: { model.dismissGone() }
        ) {
            if prompt.scan.matches.isEmpty {
                Text("Dustpan didn't find any files it left behind.").textStyle(.body)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(prompt.scan.matches) { match in
                            LeftoverRow(
                                match: match, path: model.displayPath(match.url), compact: true,
                                isSelected: Binding(
                                    get: { model.isGoneSelected(match) }, set: { model.setGone(match, selected: $0) }))
                        }
                    }
                }
                .frame(maxHeight: Metric.sheetListMaxHeight)
                Text(
                    "Guesses start unticked. Everything goes to the Trash; History can put it back until the Trash is emptied."
                )
                .textStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton(count == 0 ? "OK" : "Keep them", kind: .secondary) { model.dismissGone() }
                    .keyboardShortcut(.cancelAction)
                if count > 0 {
                    InkButton(
                        "Move \(ByteFormat.string(model.selectedGoneLeftovers.reduce(0) { $0 + $1.size })) to Trash",
                        systemImage: "trash"
                    ) {
                        Task { await model.confirmGoneLeftovers() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedGoneLeftovers.isEmpty)
                }
            }
        }
    }
}

private struct ConfirmOrphansSheet: View {
    let model: AppsModel

    var body: some View {
        let count = model.selectedOrphans.count
        InkSheet(title: "Move \(ByteFormat.string(model.selectedOrphanBytes)) to the Trash?", onCancel: cancel) {
            Text(
                "\(count == 1 ? "1 item" : "\(count) items") from apps that are no longer installed. Everything goes to the Trash. You can put it back from History until the Trash is emptied."
            )
            .textStyle(.body)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.m) {
                Spacer(minLength: 0)
                InkButton("Cancel", kind: .secondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                InkButton("Move to Trash", systemImage: "trash") {
                    Task { await model.confirmRemoveOrphans() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func cancel() { model.isConfirmingOrphans = false }
}

// MARK: - Result

private struct AppsResultView: View {
    let model: AppsModel
    let report: UninstallReport
    let openHistory: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .center, spacing: Space.xl) {
                    if !report.moved.isEmpty {
                        // The burst gives way to the text in a narrow window.
                        ViewThatFits(in: .horizontal) {
                            InkBurst(tones: [.apps, .sweep, .logs, .installers])
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        if report.moved.isEmpty {
                            // Calm, no giant "0 bytes": the reasons below are the point.
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(headline).font(Typo.title).foregroundStyle(Palette.ink)
                                Text(
                                    report.skipped.contains { $0.reason == .appMoveFailed }
                                        ? "It's installed for all users, so Finder has to remove it. Here's how."
                                        : "Everything stayed where it was. Here's why."
                                )
                                .textStyle(.body)
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Text(ByteFormat.string(report.freedBytes))
                                    .textStyle(.bigNumber)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                Text(headline).font(Typo.title).foregroundStyle(Palette.ink)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(ByteFormat.string(report.freedBytes)) \(headline)")
                        }
                        if !report.moved.isEmpty {
                            Text(
                                "\(report.moved.count == 1 ? "1 item is" : "\(report.moved.count) items are") in the Trash now. Empty the Trash when you're sure."
                            )
                            .textStyle(.body)
                            .fixedSize(horizontal: false, vertical: true)
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
                    skippedSection
                }
            }
            .padding(.horizontal, Space.xxl)
            .padding(.bottom, Space.xxl)
        }
    }

    @ViewBuilder
    private var actions: some View {
        AppsUndoButton(model: model)
        InkButton("Done") { model.dismissResult() }
            .keyboardShortcut(.defaultAction)
        Button("See History", action: openHistory)
            .buttonStyle(QuietLinkStyle())
            .fixedSize()
    }

    /// The app's own row first (with "Show in Finder" when macOS refused the move), then the
    /// rest grouped by reason.
    @ViewBuilder
    private var skippedSection: some View {
        let app = model.lastUninstallApp
        let appSkip = report.skipped.first { app != nil && $0.url.standardizedFileURL == app?.url.standardizedFileURL }
        let rest = report.skipped.filter { $0 != appSkip }
        VStack(alignment: .leading, spacing: Space.s) {
            Text(
                report.skipped.count == 1
                    ? "1 item stayed where it was" : "\(report.skipped.count) items stayed where they were"
            )
            .textStyle(.headline)
            if let appSkip, let app {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(appSkip.url.lastPathComponent)
                        .font(Typo.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(appSkip.reason.explanation).textStyle(.caption).lineLimit(3)
                    if appSkip.reason == .appMoveFailed {
                        InkButton("Show in Finder", systemImage: "folder", kind: .secondary, size: .small) {
                            model.showInFinder(app)
                        }
                        .accessibilityLabel("Show \(app.name) in Finder")
                    }
                }
                .padding(.vertical, Space.xs)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
                .accessibilityElement(children: .contain)
            }
            if !rest.isEmpty {
                SkippedGroupsView(
                    items: rest.map { ($0.url, $0.reason) },
                    title: { reason, count in
                        guard reason == .appNotRemoved, let name = app?.name else { return nil }
                        return count == 1
                            ? "1 leftover kept until \(name) is removed."
                            : "\(count) leftovers kept until \(name) is removed."
                    },
                    showsHeader: false)
            }
        }
        .frame(maxWidth: Metric.sheetWidth + Space.xxxl, alignment: .leading)
    }

    private var headline: String {
        switch model.resultKind {
        case .uninstall(let name):
            report.appRemoved ? "\(name) moved to the Trash" : "\(name) wasn't removed"
        case .removedAppLeftovers(let name):
            report.moved.isEmpty ? "Nothing was moved" : "of \(name)'s leftovers moved to the Trash"
        case .orphans, nil:
            report.moved.isEmpty ? "Nothing was moved" : "moved to the Trash"
        }
    }
}

/// "Undo (24 s)" for 30 seconds after an uninstall, then it goes away.
private struct AppsUndoButton: View {
    let model: AppsModel

    var body: some View {
        if let deadline = model.undoDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Int(deadline.timeIntervalSince(context.date).rounded(.up))
                if left > 0 {
                    InkButton("Undo (\(left) s)", systemImage: "arrow.uturn.backward", kind: .secondary) {
                        Task { await model.undoLast() }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel("Undo, \(left) seconds left")
                }
            }
        }
    }
}

#Preview {
    AppsView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}

/// An app's icon, loaded off the main actor; an empty square of the same size until it's ready.
struct AppIcon: View {
    let model: AppsModel
    let app: AppRecord
    let side: CGFloat

    var body: some View {
        Group {
            if let icon = model.icon(for: app) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
        .task(id: app.id) { await model.loadIcon(for: app) }
    }
}
