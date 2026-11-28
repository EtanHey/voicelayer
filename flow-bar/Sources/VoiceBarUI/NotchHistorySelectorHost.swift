import AppKit
import SwiftUI

/// The selector has a distinct native focus subtree: a SwiftUI button reached by Tab must not be confused
/// with the Settings tab bar, which otherwise shares BarView's outer hosting view.
final class NotchHistorySelectorFocus {
    weak var host: NSView?
    func owns(_ responder: NSResponder?) -> Bool {
        guard let host, let view = responder as? NSView else { return false }
        return view === host || view.isDescendant(of: host)
    }
}

struct NotchHistorySelectorHost: NSViewRepresentable {
    let content: AnyView
    let focus: NotchHistorySelectorFocus
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> Host {
        let view = Host(rootView: hostedContent)
        view.isFocusEnabled = isEnabled
        view.identifier = NSUserInterfaceItemIdentifier("history-selector-keyboard-host")
        focus.host = view
        return view
    }
    func updateNSView(_ view: Host, context: Context) {
        view.isFocusEnabled = isEnabled
        view.rootView = hostedContent
        focus.host = view
    }
    // Keep the nested buttons disabled with their pane.
    private var hostedContent: AnyView { AnyView(content.disabled(!isEnabled)) }

    static func dismantleNSView(_ view: Host, coordinator: ()) {
        view.releaseOwnedFocus()
    }

    final class Host: NSHostingView<AnyView> {
        var isFocusEnabled = true {
            didSet {
                if !isFocusEnabled { releaseOwnedFocus() }
            }
        }
        override var acceptsFirstResponder: Bool { isFocusEnabled }
        override func becomeFirstResponder() -> Bool { isFocusEnabled && super.becomeFirstResponder() }
        override var canBecomeKeyView: Bool { isFocusEnabled }
        override var needsPanelToBecomeKey: Bool { false }
        override var isOpaque: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        func releaseOwnedFocus() {
            if let view = window?.firstResponder as? NSView,
               view === self || view.isDescendant(of: self) { window?.makeFirstResponder(nil) }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { releaseOwnedFocus() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
