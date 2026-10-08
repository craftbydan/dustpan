import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Clutter: Large & old (big files not opened in months) and Duplicates (exact copies).
/// Both are reviewed by hand, and everything goes to the Trash with Undo.
struct ClutterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let clutter = appState.clutter
        VStack(alignment: .leading, spacing: 0) {
            ClutterHeader(clutter: clutter)
            switch clutter.tab {
            case .largeOld:
                LargeOldView(model: clutter.largeOld)
            case .duplicates:
                DuplicatesView(model: clutter.duplicates)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper)
        .background(QuickLookHost(quickLook: appState.quickLook).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct ClutterHeader: View {
    @Bindable var clutter: ClutterModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                ToneGlyph(tone: AppSection.clutter.tone, size: Space.l)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                Text("Clutter")
                    .textStyle(.display)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.m)
                lookAgain
            }
            InkTabs(
                tabs: [ClutterModel.Tab.largeOld, .duplicates].map { ($0, $0.title) }, selection: $clutter.tab,
                tone: .clutter)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    @ViewBuilder
    private var lookAgain: some View {
        switch clutter.tab {
        case .largeOld where clutter.largeOld.hasScanned && !clutter.largeOld.isScanning:
            InkButton("Look again", systemImage: "arrow.clockwise", kind: .secondary) { clutter.largeOld.start() }
                .disabled(clutter.largeOld.isMoving)
        case .duplicates where clutter.duplicates.hasScanned && !clutter.duplicates.isScanning:
            InkButton("Look again", systemImage: "arrow.clockwise", kind: .secondary) { clutter.duplicates.start() }
                .disabled(clutter.duplicates.isMoving)
        default:
            EmptyView()
        }
    }
}

// MARK: - Shared pieces

/// "Moved 3 files (2.1 GB) to the Trash. [Undo]" and quiet problem notes, above a tool's list.
struct ClutterBanners: View {
    let issue: DustpanError?
    let moved: (count: Int, bytes: Int64)?
    let dismissIssue: () -> Void
    let undo: () -> Void

    var body: some View {
        VStack(spacing: Space.s) {
            if let issue {
                QuietBanner(
                    systemImage: "exclamationmark.circle", message: issue.localizedDescription, actionTitle: "OK",
                    action: dismissIssue)
            }
            if let moved {
                QuietBanner(
                    systemImage: "trash",
                    message:
                        "Moved \(moved.count == 1 ? "1 file" : "\(moved.count) files") (\(ByteFormat.string(moved.bytes))) to the Trash. History can put them back until the Trash is emptied.",
                    actionTitle: "Undo", action: undo)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.bottom, issue == nil && moved == nil ? 0 : Space.m)
    }
}

/// The bottom bar: what's ticked, and the one primary button.
struct ClutterMoveBar: View {
    let count: Int
    let bytes: Int64
    let noun: (singular: String, plural: String)
    let note: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(count == 1 ? "1 \(noun.singular) ticked" : "\(count) \(noun.plural) ticked").textStyle(.headline)
                Text(note).textStyle(.caption)
            }
            Spacer(minLength: Space.m)
            InkButton(
                count == 0 ? "Move to Trash" : "Move \(ByteFormat.string(bytes)) to Trash", systemImage: "trash",
                action: action
            )
            .disabled(count == 0 || disabled)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.ink).frame(height: Stroke.outline) }
        .background(Palette.paper)
    }
}

/// A Quick Look thumbnail of a file (QuickLookThumbnailing), or its kind's symbol until one
/// arrives.
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = Metric.clutterThumbnail
    var symbol = "doc"

    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        ZStack {
            shape.fill(Tone.clutter.fill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
            } else {
                Image(systemName: symbol)
                    .font(Typo.title)
                    .foregroundStyle(Tone.clutter.onFill)
            }
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(Palette.ink, lineWidth: Stroke.outline))
        .accessibilityHidden(true)
        .task(id: url) { image = await Self.thumbnail(for: url, size: size, scale: scale) }
    }

    static func thumbnail(for url: URL, size: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: max(scale, 1),
            representationTypes: [.thumbnail])
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        return representation.nsImage
    }
}

extension ClutterKind {
    /// Short label for the kind filter.
    var filterTitle: String {
        switch self {
        case .archive: "Archives"
        default: title
        }
    }
}

#Preview {
    ClutterView()
        .environment(AppState.shared)
        .frame(width: Metric.windowDefault.width, height: Metric.windowDefault.height)
}
