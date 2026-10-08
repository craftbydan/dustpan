import AppKit
import Quartz
import SwiftUI

/// Shows files in the system Quick Look panel (`QLPreviewPanel`), like Finder's space bar.
///
/// The panel asks the responder chain for a controller; `QuickLookResponder` is put into the
/// window's chain (after the window) by `QuickLookHost`, so the panel finds it from any view.
/// One instance lives in `AppState.quickLook`.
@MainActor
final class QuickLook: NSObject {

    private(set) var urls: [URL] = []
    private(set) var index = 0

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Opens the panel on `url` (or closes it when it already shows that file).
    func toggle(_ url: URL) {
        if isVisible, urls.indices.contains(index), urls[index] == url {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        show([url], at: 0)
    }

    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        self.index = min(max(index, 0), urls.count - 1)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = self.index
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Follows the list when the panel is open (arrow keys in the list).
    func follow(_ url: URL) {
        guard isVisible else { return }
        show([url], at: 0)
    }
}

/// The responder the Quick Look panel talks to. The panel calls it on the main thread.
@MainActor
final class QuickLookResponder: NSResponder, @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate
{
    let quickLook: QuickLook

    init(quickLook: QuickLook) {
        self.quickLook = quickLook
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = self.quickLook.index
        }
    }

    override nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLook.urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = quickLook.urls
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}

/// Puts a `QuickLookResponder` into the hosting window's responder chain. Add it once to a
/// screen as a zero-size background.
struct QuickLookHost: NSViewRepresentable {
    let quickLook: QuickLook

    func makeNSView(context: Context) -> HostView { HostView(responder: QuickLookResponder(quickLook: quickLook)) }
    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        private let responder: QuickLookResponder

        init(responder: QuickLookResponder) {
            self.responder = responder
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.nextResponder !== responder else { return }
            // Insert once, after the window; keep whatever came after it.
            var next = window.nextResponder
            while let current = next {
                if current === responder { return }
                next = current.nextResponder
            }
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
        }
    }
}
