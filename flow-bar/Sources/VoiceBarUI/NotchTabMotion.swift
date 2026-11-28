import AppKit
import QuartzCore
import SwiftUI

/// One tab behaviour for both notch tab rows (History's Dictations / Ask / Narration and the Settings drawer's tabs):
/// the shared tab-swipe spec, docs/tab-swipe.md. `GlassTabPager` moves the pill and the pages; this file connects it to
/// VoiceBar's scroll-event monitors, axis lock and focus rules.
///
/// Two rules from BrainBar's 120 fps recording, kept here:
/// 1. The selection reaches the app's state only at REST (`GlassTabPager.onSelect`), never on the frame a motion
///    starts: a publish there rebuilt every view and froze frames.
/// 2. Every page stays built and laid out. Only the small `NotchTabPage` wrapper observes the pager, so a frame of
///    motion re-runs that wrapper's body (an offset), never a page's.

/// The gesture state a tab row keeps between scroll events. A reference held in `@State`, so updating it never asks
/// SwiftUI to rebuild the row.
@MainActor final class NotchTabGesture {
    private(set) var axis = NotchHistoryCategoryPager()
    /// When the last sideways swipe let go (the `CACurrentMediaTime` clock): a click just after one is not a row click.
    private(set) var endedAt: Double = -.infinity

    static let clickCooldown = 0.35

    var isSwiping: Bool { axis.isSwiping }

    func begin(at time: Double) {
        if axis.isSwiping { endedAt = time }
        axis.begin()
    }

    /// A two-finger step of `dx`/`dy` points over pages `stride` points apart. Returns whether it is a tab swipe (the
    /// event is then kept from the list).
    func move(dx: CGFloat, dy: CGFloat, stride: CGFloat, pager: GlassTabPager, at time: Double) -> Bool {
        let wasSwiping = axis.isSwiping
        guard let step = axis.move(dx: dx, dy: dy) else { return false }
        drive(step, grab: !wasSwiping, stride: stride, pager: pager, at: time)
        return true
    }

    /// A pointer drag's whole translation so far.
    func drag(to translation: CGSize, stride: CGFloat, pager: GlassTabPager, at time: Double) {
        let wasSwiping = axis.isSwiping
        guard let step = axis.move(to: translation) else { return }
        drive(step, grab: !wasSwiping, stride: stride, pager: pager, at: time)
    }

    /// The fingers lifted: the pager settles on the tab at its position plus the projected velocity, one tab at most.
    func release(pager: GlassTabPager, at time: Double) {
        guard axis.end() else { return }
        endedAt = time
        pager.release(at: time)
    }

    /// The system cancelled the gesture: settle back on the tab it started from, so a cancel never changes tab.
    func cancel(pager: GlassTabPager, at time: Double) {
        guard axis.end() else { return }
        endedAt = time
        pager.select(pager.motionOrigin, at: time)
    }

    /// A click or key chose a tab: the rest of the gesture in progress moves nothing.
    func interrupt(at time: Double) {
        if axis.isSwiping { endedAt = time }
        axis.interrupt()
    }

    func justSwiped(pager: GlassTabPager, at time: Double) -> Bool {
        pager.phase == .tracking || axis.isSwiping || time - endedAt < Self.clickCooldown
    }

    private func drive(_ step: CGFloat, grab: Bool, stride: CGFloat, pager: GlassTabPager, at time: Double) {
        if grab { pager.grab(at: time) }
        // Fingers moving left (negative dx) bring the next tab in, exactly as far as they moved.
        pager.drag(by: -Double(step) / Double(max(stride, 1)), at: time)
    }
}

/// One page of a tab row, placed by the pager's progress: `stride` points per tab. All pages exist at all times;
/// off-screen ones take no hits and are hidden from VoiceOver. Reduce Motion: in place, cross-faded by the progress.
/// Only this wrapper observes the pager, so a frame of motion never rebuilds `content`.
struct NotchTabPage<Content: View>: View {
    @ObservedObject var pager: GlassTabPager
    let index: Int
    let stride: CGFloat
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let distance = Double(index) - pager.progress
        let onScreen = abs(distance) < 0.5
        content
            .offset(x: reduceMotion ? 0 : CGFloat(distance) * stride)
            .opacity(reduceMotion ? max(0, 1 - abs(distance)) : 1)
            .allowsHitTesting(onScreen && pager.phase != .tracking)
            .accessibilityHidden(!onScreen)
    }
}

/// The notch tab rows' per-tab accessibility elements and tooltips, laid over the glass bar at its fixed slots. The bar
/// itself is hidden from VoiceOver: each tab here is a button with its own identifier (UI tests click it by frame),
/// marked selected, and its press goes through the same pager path as a click. Never hit-tested: the bar takes the
/// pointer.
struct NotchTabSlots: View {
    @ObservedObject var pager: GlassTabPager
    let tabs: [GlassTab]
    let metrics: GlassTabMetrics
    var identifier: (Int) -> String? = { _ in nil }
    var tooltip: (Int) -> String? = { _ in nil }
    var onSelect: (Int) -> Void

    var body: some View {
        let frames = metrics.slotFrames(tabs)
        ZStack(alignment: .topLeading) {
            ForEach(tabs.indices, id: \.self) { index in
                Color.clear
                    .frame(width: frames[index].width, height: metrics.height)
                    .background(PillControlTooltip(text: tooltip(index)))
                    .offset(x: frames[index].minX)
                    .accessibilityElement()
                    .accessibilityLabel(tabs[index].spokenLabel)
                    .accessibilityIdentifier(identifier(index) ?? "")
                    .accessibilityAddTraits(pager.selection == index ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { onSelect(index) }
            }
        }
        .frame(width: frames.last?.maxX ?? 0, height: metrics.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A notch tab bar: the glass bar plus its accessible slots.
struct NotchGlassTabBar: View {
    let pager: GlassTabPager
    let tabs: [GlassTab]
    let accessibilityLabel: String
    let metrics: GlassTabMetrics
    let colors: GlassTabColors
    var identifier: (Int) -> String? = { _ in nil }
    var tooltip: (Int) -> String? = { _ in nil }

    var body: some View {
        GlassTabBar(pager: pager, tabs: tabs, accessibilityLabel: accessibilityLabel, metrics: metrics, colors: colors,
                    handlesKeyboard: false)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                NotchTabSlots(pager: pager, tabs: tabs, metrics: metrics, identifier: identifier, tooltip: tooltip) {
                    pager.select($0, at: CACurrentMediaTime())
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
    }
}

extension GlassTabColors {
    /// The notch's own contrast palette: the old selection thumb's fill (primary at 14 %) tints the pill, no track.
    static func notch(_ palette: VoiceBarNotchContrastPalette) -> GlassTabColors {
        GlassTabColors(text: palette.secondary.color, selectedText: palette.primary.color, track: .clear,
                       pill: palette.primary.color.opacity(0.14), pillRim: palette.primary.color.opacity(0.10),
                       countFill: palette.primary.color.opacity(0.12), countText: palette.primary.color)
    }
}
