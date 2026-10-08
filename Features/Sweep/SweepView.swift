import SwiftUI

/// Sweep: one button looks at everything at once, then five tiles say what's lying around.
/// "Clean recommended" moves only safe, pre-selected junk; everything else is reviewed on its own
/// screen ("Review →").
struct SweepView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.sweep
        VStack(alignment: .leading, spacing: 0) {
            if let issue = model.issue {
                QuietBanner(
                    systemImage: "exclamationmark.circle", message: issue.localizedDescription, actionTitle: "OK",
                    action: { model.dismissIssue() }
                )
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.l)
            }
            content(model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .overlay {
            if model.isConfirming {
                CleanConfirmSheet(
                    bytes: model.recommendedBytes, lines: model.recommendedSummary,
                    note:
                        "Only caches and logs marked safe, untouched for a week. Apps, leftovers, duplicates and big files stay put. Everything goes to the Trash, and History can put it back until the Trash is emptied.",
                    onCancel: { model.isConfirming = false },
                    onConfirm: { Task { await model.confirmClean() } })
            } else if let app = model.quitPrompt {
                QuitAppSheet(
                    app: app, onCancel: { model.quitPrompt = nil },
                    onQuit: { Task { await model.confirmQuit() } })
            }
        }
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in
            if phase != .scanning { Task { await appState.disk.refresh() } }
        }
    }

    @ViewBuilder
    private func content(_ model: SweepModel) -> some View {
        if let report = model.lastReport {
            VStack(alignment: .leading, spacing: 0) {
                SweepTitle()
                CleanResultView(
                    report: report, undoDeadline: model.undoDeadline,
                    undo: { await model.undoLastClean() },
                    done: { model.dismissResult() }, openHistory: { appState.section = .history },
                    emptyTrash: emptyTrash)
            }
        } else {
            switch model.phase {
            case .idle: SweepIdleView(model: model, disk: appState.disk)
            case .scanning: SweepScanningView(model: model)
            case .results: SweepResultsView(model: model)
            }
        }
    }
}

extension SweepView {
    /// "Empty Trash…" on the celebration: opens Junk with its Empty Trash confirmation (which
    /// lists the size). Hidden without Full Disk Access, since the Trash can't be read then.
    fileprivate var emptyTrash: (() -> Void)? {
        guard appState.onboarding.hasFullDiskAccess else { return nil }
        let appState = appState
        return {
            appState.section = .junk
            Task { await appState.junk.requestEmptyTrash() }
        }
    }
}

/// The small screen title above the result views.
private struct SweepTitle: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            ToneGlyph(tone: AppSection.sweep.tone, size: Space.l)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text("Sweep")
                .textStyle(.display)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }
}

// MARK: - Idle

private struct SweepIdleView: View {
    let model: SweepModel
    let disk: DiskSpaceModel

    var body: some View {
        ScrollView {
            HStack(alignment: .center, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.l) {
                    Text("Let's see what's lying around.")
                        .textStyle(.display)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(
                        "One Sweep checks caches and logs, files of deleted apps, apps you don't open, copies in Downloads and big old files. Nothing moves until you say so."
                    )
                    .textStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: Metric.emptyStateTextWidth, alignment: .leading)
                    diskBar
                    HStack(alignment: .center, spacing: Space.m) {
                        InkButton("Sweep", systemImage: "sparkles") { model.start() }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityHint("Shortcut: Command R or Return")
                        Text("⌘R").textStyle(.caption).accessibilityHidden(true)
                    }
                    .padding(.top, Space.xs)
                    footnote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                IllustrationView(kind: .sweep)
                    .frame(width: Metric.illustration.width, height: Metric.illustration.height)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xxl)
        }
    }

    @ViewBuilder
    private var diskBar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let space = disk.space {
                SizeBar(value: space.usedBytes, total: space.totalBytes, tone: .sweep)
                Text("Startup disk · \(space.summary)")
                    .font(Typo.caption.monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
            } else {
                SizeBar(value: 0, total: 1)
                Text(disk.failed ? "Free space unavailable" : " ").textStyle(.caption)
            }
        }
        .frame(maxWidth: Metric.emptyStateTextWidth, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Startup disk")
    }

    @ViewBuilder
    private var footnote: some View {
        if model.wasCancelled {
            Text("Sweep stopped. Nothing was changed.").textStyle(.caption)
        } else if let date = model.lastSwept {
            Text("Last swept: \(SweepDates.relative(date))").textStyle(.caption)
        }
    }
}

/// Sweep wording that tests check.
enum SweepCopy {
    /// Why nothing is recommended although there are safe items (safety rule 3).
    static func nothingAutomatic(safe: Int, recentSafe: Int) -> String {
        let choose = "You can still choose them yourself."
        if recentSafe == safe {
            return safe == 1
                ? "1 safe item was used in the last week, so Dustpan doesn't pick it for you. You can still choose it yourself."
                : "\(safe) safe items were used in the last week, so Dustpan doesn't pick them for you. \(choose)"
        }
        return safe == 1
            ? "1 safe item isn't picked for you right now. You can still choose it yourself."
            : "\(safe) safe items aren't picked for you right now. \(choose)"
    }
}

enum SweepDates {
    /// "today", "yesterday", "3 days ago".
    static func relative(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        let start = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: start).day ?? 0
        if days == 1 { return "yesterday" }
        if days > 1 { return "\(days) days ago" }
        return "today"
    }
}

// MARK: - Scanning

private struct SweepScanningView: View {
    let model: SweepModel

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Space.xxl) {
                ProgressBlob(progress: model.overallProgress, tone: .sweep)
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("Sweeping…")
                        .textStyle(.display)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.modules) { module in
                            ChecklistRow(module: module, state: model.state(module), bytes: model.bytes(module))
                        }
                    }
                    .frame(maxWidth: Metric.sheetWidth, alignment: .leading)
                    HStack(spacing: Space.m) {
                        InkButton("Cancel", kind: .secondary) { model.cancel() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityHint("Shortcut: Escape")
                        Text("esc").textStyle(.caption).accessibilityHidden(true)
                    }
                    .padding(.top, Space.s)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
        }
    }
}

private struct ChecklistRow: View {
    let module: SweepModule
    let state: SweepModuleState
    let bytes: Int64

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(Typo.headline)
                .foregroundStyle(state.isDone ? Palette.ink : Palette.secondaryText)
                .frame(width: Metric.checkbox)
                .accessibilityHidden(true)
            Text(module.checklistTitle)
                .textStyle(.body)
            Spacer(minLength: Space.s)
            Text(trailing)
                .font(Typo.caption.monospacedDigit())
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, Space.xs)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(module.checklistTitle), \(trailing)")
    }

    private var symbol: String {
        switch state {
        case .waiting: "circle"
        case .running: "circle.dotted"
        case .finished: "checkmark.circle.fill"
        case .needsAccess: "lock"
        case .failed: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        }
    }

    private var trailing: String {
        switch state {
        case .waiting: "Waiting"
        case .running(let fraction):
            if let fraction, fraction > 0 { "Looking… \(Int((fraction * 100).rounded())) %" } else { "Looking…" }
        case .finished: "Done"
        case .needsAccess: "Needs Full Disk Access"
        case .failed: "Couldn't check"
        case .cancelled: "Stopped"
        }
    }
}

// MARK: - Results

private struct SweepResultsView: View {
    let model: SweepModel
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        headline
                        leftOut
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Metric.tileMinWidth), spacing: Space.l)],
                        alignment: .leading, spacing: Space.l
                    ) {
                        ForEach(model.modules) { module in
                            tile(module)
                        }
                    }
                    accessNote
                }
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xl)
            }
            bottomBar
        }
    }

    @ViewBuilder
    private var headline: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            switch model.headline {
            case .ready(let bytes):
                // Scales down rather than widening the screen in a narrow window.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Text(ByteFormat.string(bytes)).textStyle(.bigNumber).lineLimit(1)
                        Text("ready to go").font(Typo.title).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ByteFormat.string(bytes)).textStyle(.bigNumber).lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("ready to go").font(Typo.title).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                }
                Text(
                    "Safe caches and logs, untouched for a week. The tiles below are for you to review; none of them is cleaned without you."
                )
                .textStyle(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.xxs)
            case .nothingAutomatic(let safe, let recent):
                Text("Nothing to clean automatically.")
                    .font(Typo.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SweepCopy.nothingAutomatic(safe: safe, recentSafe: recent))
                    .textStyle(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)
                InkButton("Review safe items", systemImage: "checkmark", kind: .secondary, size: .small) {
                    appState.reviewSafeJunk()
                }
                .padding(.top, Space.xs)
                .accessibilityHint("Opens Junk showing only items marked safe. Nothing is ticked for you.")
            case .reviewOnly:
                Text("Nothing to clean automatically.")
                    .font(Typo.title)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The tiles below are worth a look, but none of them is cleaned without you.")
                    .textStyle(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            case .allEmpty:
                Text("Nothing needs cleaning right now.")
                    .textStyle(.display)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Every check came back empty. Sweep again any time.")
                    .textStyle(.caption)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "Google Chrome is open, so its 415 MB cache is left out. Quit Google Chrome"
    @ViewBuilder
    private var leftOut: some View {
        let groups = model.leftOut
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(groups) { group in
                    let quitting = model.runningApps.quitting.contains(group.app.bundleID)
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: "power")
                            .fontWeight(.bold)
                            .foregroundStyle(Palette.ink)
                            .accessibilityHidden(true)
                        Text(
                            "\(group.app.name) is open, so its \(ByteFormat.string(group.bytes)) cache is left out."
                        )
                        .textStyle(.body)
                        .lineLimit(2)
                        if !group.app.bundleID.isEmpty {
                            Button(quitting ? "Quitting…" : "Quit \(group.app.name)") {
                                model.requestQuit(group.app)
                            }
                            .buttonStyle(QuietLinkStyle())
                            .fixedSize()
                            .disabled(quitting)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
    }

    private func tile(_ module: SweepModule) -> some View {
        let state = model.state(module)
        let figure: String? =
            switch state {
            case .needsAccess: "Locked"
            case .failed, .cancelled: "—"
            default: model.bytes(module) == 0 ? "None" : nil
            }
        // With a banner above (no Full Disk Access, or a problem note) the shorter tiles keep both
        // rows on screen at the default window size.
        let compact = appState.onboarding.showsBanner || model.issue != nil
        return Tile(
            tone: module.tone, bytes: model.bytes(module), label: "\(module.title)", detail: detail(module),
            figure: figure, compact: compact
        ) {
            if case .needsAccess = state {
                appState.onboarding.showAccessSteps()
            } else {
                appState.review(module)
            }
        }
        .accessibilityHint(state == .needsAccess ? "Shows how to turn on Full Disk Access" : "Review")
    }

    private func detail(_ module: SweepModule) -> String {
        switch model.state(module) {
        case .needsAccess: return "Needs Full Disk Access"
        case .failed: return "Couldn't check this time"
        case .cancelled: return "Stopped"
        default: break
        }
        let count = model.count(module)
        let review = "Review →"
        switch module {
        case .junk:
            return model.junkTileDetail
        case .orphans:
            return "\(count == 1 ? "1 item" : "\(count) items"), guesses · \(review)"
        case .unusedApps:
            return "\(count == 1 ? "1 app" : "\(count) apps") · suggestion · \(review)"
        case .duplicates:
            return "\(count == 1 ? "1 extra copy" : "\(count) extra copies") · \(review)"
        case .largeOld:
            return "\(count == 1 ? "1 file" : "\(count) files") · \(review)"
        }
    }

    @ViewBuilder
    private var accessNote: some View {
        let skipped = model.junkSkippedCategories
        if skipped > 0 {
            HStack(spacing: Space.s) {
                Image(systemName: "lock").accessibilityHidden(true)
                Text(
                    "Without Full Disk Access, \(skipped == 1 ? "1 junk category was" : "\(skipped) junk categories were") only partly checked, and Downloads was skipped."
                )
                .lineLimit(2)
                Button("Show me how") { appState.onboarding.showAccessSteps() }
                    .buttonStyle(QuietLinkStyle())
                    .fixedSize()
                    .accessibilityLabel("Show me how to turn on Full Disk Access")
            }
            .textStyle(.caption)
        }
    }

    /// One row when it fits; otherwise the status above the buttons. "Clean recommended" only shows
    /// when something is recommended; otherwise the caption says why.
    private var bottomBar: some View {
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
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if let date = model.lastSwept {
                Text("Last swept: \(SweepDates.relative(date))").textStyle(.headline).lineLimit(1)
            }
            Text(
                model.recommendedItems.isEmpty
                    ? "Nothing is picked for you this time." : "Everything goes to the Trash first."
            )
            .textStyle(.caption)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Sweep again") { model.start() }
            .buttonStyle(QuietLinkStyle())
            .fixedSize()
            .disabled(model.isCleaning)
        if model.recommendedItems.isEmpty {
            InkButton("Review everything") { appState.review(.junk) }
                .keyboardShortcut(.defaultAction)
        } else {
            InkButton("Review everything", kind: .secondary) { appState.review(.junk) }
            // Return opens the confirmation (which lists the size); nothing moves without it.
            InkButton("Clean recommended", systemImage: "trash") { model.requestClean() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCleaning || model.isConfirming)
                .accessibilityLabel("Clean recommended, \(ByteFormat.string(model.recommendedBytes))")
                .accessibilityHint("Asks before moving anything to the Trash")
        }
    }
}

extension SweepModule {
    /// Tile colour.
    var tone: Tone {
        switch self {
        case .junk: .dev
        case .orphans: .apps
        case .unusedApps: .userCache
        case .duplicates: .logs
        case .largeOld: .clutter
        }
    }
}

#Preview {
    SweepView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
