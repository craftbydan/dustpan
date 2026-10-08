import SwiftUI

/// History screen: everything Dustpan moved to the Trash, grouped by day, with "Put back".
struct HistoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let model = appState.history
        Screen(title: "History", tone: .history) {
            if let issue = model.issue {
                QuietBanner(
                    systemImage: "exclamationmark.circle", message: issue.localizedDescription, actionTitle: "OK",
                    action: { model.dismissIssue() })
            }
            if model.isLoaded && model.isEmpty {
                EmptyState(
                    "Everything Dustpan moves to the Trash is listed here, and you can put any of it back."
                ) {
                    IllustrationView(kind: .history)
                }
            } else {
                VStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(model.days) { day in
                        DaySection(model: model, day: day)
                    }
                }
            }
        }
        .task { await model.load() }
    }
}

private struct DaySection: View {
    let model: HistoryModel
    let day: HistoryModel.Day

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(Self.title(day.date))
                    .font(Typo.title)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(summary).textStyle(.caption)
                Spacer(minLength: Space.m)
                if day.entries.filter({ $0.status == .inTrash }).count > 1 {
                    Button("Put all back") { Task { await model.putBackAll(in: day) } }
                        .buttonStyle(QuietLinkStyle())
                        .accessibilityLabel("Put back everything from \(Self.title(day.date))")
                }
            }
            VStack(spacing: 0) {
                ForEach(day.entries) { entry in
                    HistoryRow(model: model, entry: entry)
                }
            }
            .padding(.horizontal, Space.m)
            .inkSurface(Palette.paper, radius: Radius.medium)
        }
    }

    private var summary: String {
        let count = day.entries.count == 1 ? "1 item" : "\(day.entries.count) items"
        let inTrash = day.bytesInTrash
        return inTrash == day.totalBytes
            ? "\(count) · \(ByteFormat.string(day.totalBytes)) in the Trash"
            : "\(count) · \(ByteFormat.string(day.totalBytes)) moved, \(ByteFormat.string(inTrash)) still in the Trash"
    }

    static func title(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct HistoryRow: View {
    let model: HistoryModel
    let entry: HistoryEntry

    var body: some View {
        let url = URL(fileURLWithPath: entry.log.originalPath)
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(url.lastPathComponent).textStyle(.headline).lineLimit(1)
                Text(model.folder(of: entry)).textStyle(.caption).lineLimit(1).truncationMode(.middle)
                if let id = entry.log.id, let failure = model.failures[id] {
                    Text(failure.explanation)
                        .font(Typo.caption.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
            }
            Spacer(minLength: Space.m)
            VStack(alignment: .trailing, spacing: Space.xxs) {
                Text(ByteFormat.string(entry.log.bytes)).font(Typo.headline.monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Text(entry.log.date.formatted(date: .omitted, time: .shortened)).textStyle(.caption)
            }
            status
                .frame(minWidth: Metric.rowIcon * 4, alignment: .trailing)
        }
        .padding(.vertical, Space.s)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: Stroke.hairline) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.status {
        case .inTrash:
            Button {
                Task { await model.putBack(entry) }
            } label: {
                Label("Put back", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(QuietLinkStyle())
            .disabled(entry.log.id.map { model.working.contains($0) } ?? true)
            .accessibilityLabel("Put back \(URL(fileURLWithPath: entry.log.originalPath).lastPathComponent)")
        case .restored(let date):
            Label("Put back \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark")
                .font(Typo.caption)
                .foregroundStyle(Palette.secondaryText)
        case .backInPlace:
            Label("Back in place", systemImage: "checkmark")
                .font(Typo.caption)
                .foregroundStyle(Palette.secondaryText)
        case .gone:
            Label("Trash emptied", systemImage: "xmark")
                .font(Typo.caption)
                .foregroundStyle(Palette.secondaryText)
        }
    }
}

#Preview {
    HistoryView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
