import SwiftUI

/// The Apps screen's Updates tab: newer versions found in the App Store, apps' own (Sparkle)
/// feeds and Homebrew, with a way to open the right place. Dustpan never installs anything.
struct UpdatesTab: View {
    let model: UpdatesModel
    let apps: AppsModel

    var body: some View {
        Group {
            if let report = model.report, !model.isChecking {
                results(report)
            } else {
                AppsWorkingView(
                    title: model.total == 0
                        ? "Checking for updates…" : "Looking for updates: \(model.done) of \(model.total) apps…",
                    progress: model.progress)
            }
        }
        .task {
            if apps.hasLoaded { await model.tabOpened(apps: apps.apps) }
        }
    }

    private func results(_ report: UpdateReport) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(model.headline).textStyle(.headline)
                Text(caption(report)).textStyle(.caption)
            }
            .accessibilityElement(children: .combine)
            if let notice = model.notice {
                QuietBanner(systemImage: model.noticeSymbol, message: notice)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.outdated.isEmpty {
                        Text(
                            "No newer versions found. Dustpan looks in the App Store, apps' own update feeds and Homebrew."
                        )
                        .textStyle(.body)
                        .padding(.vertical, Space.s)
                    }
                    ForEach(model.outdated) { update in
                        UpdateRow(model: model, apps: apps, update: update)
                    }
                    section(
                        title: "Can't check", items: model.cantCheck,
                        isOpen: Binding(get: { model.showCantCheck }, set: { model.showCantCheck = $0 }))
                    section(
                        title: "Up to date", items: model.upToDate,
                        isOpen: Binding(get: { model.showUpToDate }, set: { model.showUpToDate = $0 }))
                }
                .padding(.bottom, Space.l)
            }
        }
        .padding(.horizontal, Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func caption(_ report: UpdateReport) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = formatter.localizedString(for: report.checkedAt, relativeTo: Date())
        return "\(model.summary) · checked \(when). Nothing is downloaded or installed."
    }

    @ViewBuilder
    private func section(title: String, items: [AppUpdate], isOpen: Binding<Bool>) -> some View {
        if !items.isEmpty {
            Button {
                isOpen.wrappedValue.toggle()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                        .fontWeight(.bold)
                        .frame(width: Space.m)
                        .accessibilityHidden(true)
                    Text("\(title) (\(items.count))").textStyle(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.top, Space.l)
                .padding(.bottom, Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(items.count) apps")
            .accessibilityValue(isOpen.wrappedValue ? "Shown" : "Hidden")
            .accessibilityHint(isOpen.wrappedValue ? "Hides the list" : "Shows the list")
            if isOpen.wrappedValue {
                ForEach(items) { update in
                    UpdateRow(model: model, apps: apps, update: update)
                }
            }
        }
    }
}

private struct UpdateRow: View {
    let model: UpdatesModel
    let apps: AppsModel
    let update: AppUpdate

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.s) {
                icon
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        Text(update.app.name).textStyle(.headline).lineLimit(1).truncationMode(.middle)
                        if let source = update.source {
                            InkBadge(text: source.title, tone: UpdateRow.tone(for: source))
                        }
                    }
                    Text(versionLine)
                        .font(update.isOutdated ? Typo.body.monospacedDigit() : Typo.caption.monospacedDigit())
                        .foregroundStyle(update.isOutdated ? Palette.ink : Palette.secondaryText)
                        .lineLimit(2)
                    if let token = update.brewToken, update.isOutdated {
                        Text("Installed with Homebrew: brew upgrade --cask \(token)")
                            .textStyle(.caption)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            Spacer(minLength: Space.m)
            if update.open != nil, update.isOutdated || update.status == .cantCheck(.noSource) {
                InkButton(
                    UpdatesModel.openTitle(update.open), systemImage: "arrow.up.forward.app", kind: .secondary
                ) {
                    model.open(update)
                }
                .accessibilityLabel(UpdatesModel.openSpoken(update.open, name: update.app.name))
            }
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.xs)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        if let record = apps.apps.first(where: { $0.id == update.id }) {
            AppIcon(model: apps, app: record, side: Metric.rowIcon)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: Metric.rowIcon, height: Metric.rowIcon)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityHidden(true)
        }
    }

    private var versionLine: String {
        switch update.status {
        case .available(let version): "\(update.installedVersion) → \(version)"
        case .upToDate: "\(update.installedVersion), the newest"
        case .cantCheck(let reason): "\(update.installedVersion). \(reason.explanation)"
        }
    }

    private var spoken: String {
        let source = update.source.map { ", from \($0.title)" } ?? ""
        switch update.status {
        case .available(let version):
            return "\(update.app.name), version \(update.installedVersion), \(version) available\(source)"
        case .upToDate:
            return "\(update.app.name), version \(update.installedVersion), up to date\(source)"
        case .cantCheck(let reason):
            return "\(update.app.name), version \(update.installedVersion), can't check. \(reason.explanation)"
        }
    }

    static func tone(for source: UpdateSource) -> Tone {
        switch source {
        case .appStore: .spaceMap
        case .sparkle: .clutter
        case .homebrew: .sweep
        }
    }
}
