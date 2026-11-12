import AppKit
import SwiftUI

/// C9-N item 3 (Etan, 2026-11-12: "why when I click the mic picker icon in the hovered notch does it go to the right
/// settings but the title is right where the fade is?"). `scrollTo(_, anchor: .top)` put the section title flush with
/// the scrolled-to header ROW's top edge, so where the title text landed depended on the Form's own header padding:
/// 20 pt below the top on the M1 (macOS 26.5), inside the drawer's 20 pt top fade (`NotchScrollEdgeFade`) on Etan's
/// M4. A landing measures the title text itself and puts it `lead` points below the visible top: the fade's height
/// plus a section gap in the drawer; in the window the 20 pt the M1 already drew, so the window does not move there.
@MainActor
final class SettingsScrollLanding {
    /// The gap a section title keeps below the drawer's fade once landed.
    static let sectionGap: CGFloat = 10
    /// The window's landing: where 92d7ab5b drew the title on the M1 (measured 20.0 pt).
    static let windowLead: CGFloat = 20

    static func lead(inDrawer: Bool) -> CGFloat {
        inDrawer ? NotchSettingsDrawerPresentation.scrollEdgeFade + sectionGap : windowLead
    }

    fileprivate weak var probe: NSView?

    /// Scrolls the probe's enclosing scroll view so the probe's top sits `lead` below the visible top (clamped to
    /// the scroll range). Returns false when the title is not laid out yet (the caller scrolls it into view first).
    @discardableResult
    func land(lead: CGFloat, animated: Bool) -> Bool {
        guard let probe, probe.window != nil, let scroll = probe.enclosingScrollView,
              let document = scroll.documentView else { return false }
        let clip = scroll.contentView
        let rect = probe.convert(probe.bounds, to: document)
        let top = document.isFlipped ? rect.minY : document.bounds.height - rect.maxY
        let inset = scroll.contentInsets.top
        let maximum = max(-inset, document.frame.height - clip.bounds.height)
        let y = min(max(-inset, top - lead - inset), maximum)
        let origin = NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? y : document.bounds.height
            - clip.bounds.height - y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.scroll(to: origin)
        }
        scroll.reflectScrolledClipView(clip)
        return true
    }
}

/// Marks where a landing's title is, from inside the scroll view's document.
struct SettingsScrollLandingProbe: NSViewRepresentable {
    let landing: SettingsScrollLanding

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        landing.probe = view
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        landing.probe = view
    }
}
