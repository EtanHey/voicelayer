import AppKit
import QuartzCore
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// go-1126 vl-swipe: one tab behaviour for both notch tab rows (docs/tab-swipe.md). The pill's frame follows the
/// pager's progress, a release picks its tab from position plus projected velocity, a click runs the same spring from
/// where the pill is drawn, no slot changes width with the selection, the selection reaches the app only at rest, and
/// no page is rebuilt while the pages move.
@MainActor
final class NotchTabMotionTests: XCTestCase {
    private var windows: [NSWindow] = []
    private let frame = 1.0 / 120
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            // Offscreen SwiftUI builds its accessibility tree only for an AX client (NotchHistoryCategoriesTests).
            let app = NSApplication.shared
            let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
            guard app.responds(to: setter) else { return }
            let was = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let set = unsafeBitCast(app.method(for: setter), to: Setter.self)
            set(app, setter, true)
            restoreAccessibility = { set(app, setter, was) }
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            restoreAccessibility?()
            restoreAccessibility = nil
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    private var historyTabs: [GlassTab] { SettingsHistoryScope.allCases.map { GlassTab(title: $0.title, spokenLabel: $0.title) } }

    private func historyMetrics(width: CGFloat = 404) -> GlassTabMetrics {
        var metrics = GlassTabMetrics()
        metrics.fontSize = NotchHistoryPresentation.categorySelectorFontSize
        metrics.height = NotchHistoryPresentation.categorySelectorHeight
        metrics.fill = width
        return metrics
    }

    // MARK: Spec 4: fixed slots

    func testSlotWidthsAreFixedAndNeverDependOnTheSelection() throws {
        for (tabs, metrics) in [(historyTabs, historyMetrics()),
                                (NotchSettingsDrawer.glassTabs, NotchSettingsDrawer.tabMetrics(width: 388))] {
            let widths = metrics.slotWidths(tabs)
            XCTAssertEqual(Set(widths).count, 1, "equal slots across the row")
            XCTAssertEqual(widths.reduce(0, +), metrics.fill!, accuracy: 1e-9, "the row spans its drawer")
        }
        // On screen: the selector's slots sit at the same frames whatever is selected, at rest and mid-settle.
        var seen: [[NSRect]] = []
        for selection in 0 ..< 3 {
            for progress in [Double(selection), Double(selection) + 0.5] where progress <= 2 {
                let pager = GlassTabPager(count: 3, selection: selection)
                pager.present(progress)
                let host = hostSelector(pager)
                seen.append(try SettingsHistoryScope.allCases.map { scope in
                    try XCTUnwrap(element(NotchHistoryPresentation.categoryIdentifier(scope), in: host)).frame
                })
            }
        }
        for frames in seen { XCTAssertEqual(frames, seen[0], "no slot moves or resizes with the selection") }
    }

    // MARK: Spec 1 and 2: progress -> pill frame

    func testThePillFollowsProgressBetweenSlotsAndRestsOnTheSlot() {
        for (tabs, metrics) in [(historyTabs, historyMetrics()),
                                (NotchSettingsDrawer.glassTabs, NotchSettingsDrawer.tabMetrics(width: 388))] {
            let slots = metrics.slotFrames(tabs).map { $0.insetBy(dx: metrics.inset, dy: metrics.inset) }
            for (index, slot) in slots.enumerated() {
                XCTAssertEqual(metrics.pillFrame(tabs, progress: Double(index)), slot, "at rest: the slot's exact frame")
            }
            for p in Swift.stride(from: 0.0, through: Double(slots.count - 1), by: 0.125) {
                let lower = Int(p.rounded(.down)), upper = min(lower + 1, slots.count - 1)
                let t = CGFloat(p - Double(lower))
                let pill = metrics.pillFrame(tabs, progress: p)
                XCTAssertEqual(pill.minX, slots[lower].minX + (slots[upper].minX - slots[lower].minX) * t, accuracy: 1e-9)
                XCTAssertEqual(pill.width, slots[lower].width + (slots[upper].width - slots[lower].width) * t, accuracy: 1e-9)
            }
            XCTAssertEqual(metrics.pillFrame(tabs, progress: -0.3), slots[0], "past an end it stays on that end")
        }
    }

    // MARK: Spec 2: the release target

    func testTheReleasePicksThePositionPlusTheProjectedVelocity() {
        /// A swipe of `steps` points per 120 Hz step, a pause, then the release: the tab it settles on.
        func release(start: Int, steps: [Double], pause: Double) -> Int {
            let pager = GlassTabPager(count: 5, selection: start)
            var time = 0.0
            pager.grab(at: time)
            for dx in steps {
                time += frame
                pager.drag(by: -dx / 400, at: time)
            }
            pager.release(at: time + pause)
            return pager.selection
        }
        XCTAssertEqual(release(start: 2, steps: Array(repeating: -4, count: 45), pause: 0.2), 2, "45 % of a page, still: back")
        XCTAssertEqual(release(start: 2, steps: Array(repeating: -4, count: 55), pause: 0.2), 3, "55 %, still: on")
        XCTAssertEqual(release(start: 2, steps: Array(repeating: -4, count: 20), pause: 0), 3,
                       "20 % but moving at 480 pt/s: the projection carries it on")
        XCTAssertEqual(release(start: 2, steps: Array(repeating: 4, count: 20), pause: 0), 1, "the same flick back")
        XCTAssertEqual(release(start: 2, steps: Array(repeating: -4, count: 30) + Array(repeating: 2, count: 12), pause: 0), 2,
                       "out 30 %, then moving back at release: the velocity wins")
        XCTAssertEqual(release(start: 2, steps: Array(repeating: -40, count: 30), pause: 0), 3, "never more than one tab")
    }

    // MARK: Spec 3: a click runs the same spring

    func testAClickIsTheSameSpringAsAReleaseFromThePresentedPosition() {
        func trajectory(_ start: (GlassTabPager) -> Void) -> [Double] {
            let pager = GlassTabPager(count: 3, selection: 0)
            pager.isLive = { true }
            start(pager)
            var time = 1.0
            var out: [Double] = []
            for _ in 0 ..< 60 {
                time += frame
                pager.tick(at: time)
                out.append(pager.progress)
            }
            XCTAssertEqual(pager.phase, .resting)
            return out
        }
        let click = trajectory { pager in
            pager.present(0.6)
            pager.select(1, at: 1)
        }
        let release = trajectory { pager in
            pager.grab(at: 0.5)
            pager.drag(to: 0.6, at: 0.5)
            pager.release(at: 1) // half a second still: no velocity, the same start as the click; 0.6 rounds to 1
        }
        XCTAssertEqual(click, release, "a click and a still release run frame for frame the same spring")
        XCTAssertEqual(click.last, 1)
        XCTAssertLessThanOrEqual(click.firstIndex(of: 1) ?? .max, 60, "at rest within 0.5 s")
    }

    func testCancelledPillDragPastThresholdReturnsToStartingTab() {
        for (tabs, metrics) in [(historyTabs, historyMetrics()),
                                (NotchSettingsDrawer.glassTabs, NotchSettingsDrawer.tabMetrics(width: 388))] {
            let pager = GlassTabPager(count: tabs.count)
            pager.isLive = { true }
            var committed: [Int] = []
            pager.onSelect = { committed.append($0) }
            let pill = metrics.pillFrame(tabs, progress: 0)
            let next = metrics.pillFrame(tabs, progress: 1)
            var press: GlassTabPress? = GlassTabPress.begin(
                at: CGPoint(x: pill.midX, y: pill.midY), pager: pager, tabs: tabs, metrics: metrics, time: 1
            )
            press?.move(translation: (next.midX - pill.midX) * 0.6, pager: pager, tabs: tabs, metrics: metrics, time: 1.02)
            XCTAssertGreaterThan(pager.progress, 0.5)
            GlassTabPress.gestureDidReset(&press, pager: pager, time: 1.2)
            XCTAssertNil(press)
            XCTAssertEqual(pager.phase, .settling)
            XCTAssertEqual(pager.selection, 0)
            for step in 1 ... 120 { pager.tick(at: 1.2 + Double(step) * frame) }
            XCTAssertEqual(pager.phase, .resting)
            XCTAssertEqual(pager.progress, 0)
            XCTAssertEqual(committed, [])
        }
    }

    func testFourSlotSettingsClickRestsWithinHalfASecond() {
        let tabs = NotchSettingsDrawer.glassTabs
        let metrics = NotchSettingsDrawer.tabMetrics(width: 388)
        let pager = GlassTabPager(count: tabs.count)
        pager.isLive = { true }
        var committed: [Int] = []
        pager.onSelect = { committed.append($0) }
        let target = tabs.count - 1
        let slot = metrics.pillFrame(tabs, progress: Double(target))
        let point = CGPoint(x: slot.midX, y: slot.midY)
        let press = GlassTabPress.begin(at: point, pager: pager, tabs: tabs, metrics: metrics, time: 0)
        press.end(at: point, pager: pager, tabs: tabs, metrics: metrics, time: 0)
        XCTAssertEqual(pager.selection, target)
        XCTAssertEqual(pager.progress, 0)

        var steps = 0
        while pager.phase != .resting && steps < 120 {
            let previous = pager.progress
            steps += 1
            pager.tick(at: Double(steps) * frame)
            XCTAssertLessThanOrEqual(abs(pager.progress - previous), 1.0 / 3)
            if pager.phase != .resting { XCTAssertTrue(committed.isEmpty) }
        }
        print("[tab-motion] click Dictation→General: \(steps) frames to rest at 120 Hz")
        XCTAssertLessThanOrEqual(steps, 60)
        XCTAssertEqual(metrics.pillFrame(tabs, progress: pager.progress), slot)
        XCTAssertEqual(pager.progress, Double(target))
        XCTAssertEqual(committed, [target])
    }

    /// A click on a category in the real History panel: from the presented position, on the shared spring, the lists
    /// and the selector moving together; nothing is committed (no publish, no rebuilt row) until the motion rests.
    func testAClickOnACategoryMovesWithoutRebuildingAndCommitsAtRest() throws {
        let counter = RowBuildCounter()
        let archive = NotchHistoryArchiveStore(loadAsk: { _ in [] }, loadSpeech: { _ in [] })
        let pager = GlassTabPager(count: 3, selection: 0)
        let host = hostPanel(archive: archive, pager: pager, counter: counter)
        // The test is the clock: frames come from the ticks below, never from a display link.
        pager.isLive = { true }
        pager.onNeedsFrames = { _ in }

        let speech = try XCTUnwrap(element(NotchHistoryPresentation.categoryIdentifier(.speech), in: host)).frame
        let window = try XCTUnwrap(host.window)
        let point = window.convertPoint(fromScreen: NSPoint(x: speech.midX, y: speech.midY))
        counter.builds = 0
        click(at: point, in: window)
        XCTAssertEqual(pager.selection, 2)
        XCTAssertEqual(pager.phase, .settling, "a click starts the spring")
        XCTAssertEqual(pager.progress, 0, "from where it was drawn: no jump on the click")
        XCTAssertEqual(archive.selectedScope, .recording, "nothing is published on the frame the motion starts")

        var time = CACurrentMediaTime()
        var previous = pager.progress
        var steps = 0
        var buildsWhileMoving = 0
        while pager.phase != .resting, steps < 120 {
            time += frame
            pager.tick(at: time)
            render(host)
            XCTAssertLessThanOrEqual(abs(pager.progress - previous), 1.0 / 3, "no frame moves more than a third of a tab")
            previous = pager.progress
            steps += 1
            if pager.phase != .resting {
                XCTAssertEqual(archive.selectedScope, .recording, "still moving: not committed")
                buildsWhileMoving = counter.builds
            }
        }
        XCTAssertLessThanOrEqual(Double(steps) * frame, 0.5, "at rest within half a second")
        XCTAssertEqual(pager.progress, 2)
        XCTAssertEqual(archive.selectedScope, .speech, "committed at rest")
        XCTAssertEqual(buildsWhileMoving, 0, "no Dictations row was rebuilt while the lists moved")
        print("[tab-motion] click Dictations→Narration: \(steps) frames to rest, rows rebuilt while moving \(buildsWhileMoving)")
    }

    // MARK: Settings drawer

    /// Every pane is built up front and none while the panes move; the tab reaches the app at rest.
    func testTheSettingsDrawerKeepsEveryPaneBuiltAndCommitsAtRest() throws {
        var built: [SettingsTab] = []
        var selected: [SettingsTab] = []
        let pager = GlassTabPager(count: SettingsTab.allCases.count, selection: SettingsTab.allCases.firstIndex(of: .speech)!)
        let drawer = NotchSettingsDrawer(
            selectedTab: .speech, appearance: .dark,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                built.append(tab)
                return AnyView(Text("\(tab.title) pane").frame(maxWidth: .infinity, maxHeight: .infinity))
            }),
            history: { AnyView(Text("history rows")) },
            pager: pager, onSelectTab: { selected.append($0) }
        )
        let host = hostView(drawer.frame(width: 404, height: 360), size: NSSize(width: 404, height: 360))
        pager.isLive = { true }
        pager.onNeedsFrames = { _ in }
        XCTAssertEqual(Set(built), [.speech, .dictionary, .transcription, .general], "every pane is laid out up front")
        built = []
        pager.select(4, at: CACurrentMediaTime()) // a click on General, three tabs away
        var time = CACurrentMediaTime()
        for _ in 0 ..< 120 where pager.phase != .resting {
            time += frame
            pager.tick(at: time)
            render(host)
            if pager.phase != .resting { XCTAssertEqual(selected, [], "not committed mid-motion") }
        }
        XCTAssertEqual(built, [], "no pane is built while the panes move")
        XCTAssertEqual(selected, [.general], "committed once, at rest")
    }

    func testOffViewportSettingsControlsCannotBecomeFirstResponder() throws {
        let pager = GlassTabPager(count: SettingsTab.allCases.count, selection: 1)
        let drawer = NotchSettingsDrawer(
            selectedTab: .speech, appearance: .dark,
            context: NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
                AnyView(FocusTestPane(title: tab.title))
            }),
            pager: pager, onSelectTab: { _ in }
        )
        let host = hostView(drawer.frame(width: 404, height: 360), size: NSSize(width: 404, height: 360))
        let window = try XCTUnwrap(host.window)
        let viewport = host.bounds.insetBy(dx: NotchSettingsDrawerPresentation.horizontalInset, dy: 0)
        let fieldValues = Set(SettingsTab.allCases.dropFirst().map { "\($0.title) field" })
        func fields(in view: NSView) -> [NSTextField] {
            let controls = view.subviews.flatMap { fields(in: $0) }
            guard let field = view as? NSTextField, fieldValues.contains(field.stringValue) else { return controls }
            return [field] + controls
        }
        func ownsFocus(_ field: NSTextField) -> Bool {
            if window.firstResponder === field { return true }
            let editor = window.firstResponder as? NSTextView
            return editor?.isFieldEditor == true && editor?.delegate === field
        }
        func assertFocus() throws {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            render(host)
            let controls = fields(in: host)
            let foreground = try XCTUnwrap(controls.first {
                viewport.intersects($0.convert($0.bounds, to: host)) && $0.isEnabled
            }, "the foreground field is enabled")
            XCTAssertTrue(window.makeFirstResponder(foreground))
            XCTAssertTrue(ownsFocus(foreground), "the foreground field can actually take focus")
            for control in controls where !viewport.intersects(control.convert(control.bounds, to: host)) {
                window.makeFirstResponder(nil)
                window.makeFirstResponder(control)
                XCTAssertFalse(control.isEnabled, "an off-viewport field must be disabled")
                XCTAssertFalse(ownsFocus(control), "an off-viewport field cannot acquire first responder")
            }
            window.makeFirstResponder(nil)
        }

        try assertFocus()
        pager.onNeedsFrames = { _ in }
        pager.isLive = { true }
        pager.select(2, at: 0)
        pager.tick(at: 0.017) // Dictionary is less than one stride away, but still outside the viewport.
        XCTAssertEqual(pager.phase, .settling)
        XCTAssertGreaterThan(pager.progress, 1)
        XCTAssertLessThan(pager.progress, 2 - 388.0 / 428.0)
        try assertFocus()
        for step in 3 ... 120 { pager.tick(at: Double(step) * frame) }
        XCTAssertEqual(pager.phase, .resting)
        try assertFocus()
    }

    private struct FocusTestPane: View {
        @State private var text: String

        init(title: String) {
            _text = State(initialValue: "\(title) field")
        }

        var body: some View {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .frame(width: 48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func testHostedHistorySelectorHonorsFocusAndSolidPillEnvironment() throws {
        let focus = NotchHistorySelectorFocus()
        var drewSolidPill = false
        let selector = NotchHistorySelectorHost(
            content: AnyView(SolidPillEnvironmentProbe { drewSolidPill = $0 }), focus: focus
        )
        .disabled(true)
        .environment(\.glassTabSolidPill, true)
        let host = hostView(selector, size: NSSize(width: 404, height: 40))
        let selectorHost = try XCTUnwrap(focus.host)
        let window = try XCTUnwrap(host.window)
        XCTAssertTrue(drewSolidPill)
        XCTAssertFalse(selectorHost.canBecomeKeyView)
        window.makeFirstResponder(selectorHost)
        XCTAssertFalse(focus.owns(window.firstResponder))
    }

    private struct SolidPillEnvironmentProbe: View {
        @Environment(\.glassTabSolidPill) private var solidPill
        let observed: (Bool) -> Void

        var body: some View {
            Color.clear.onAppear { observed(solidPill) }
        }
    }

    // MARK: Reduce Motion

    func testReduceMotionNeverOvershootsTheTarget() {
        let pager = GlassTabPager(count: 3, selection: 0)
        pager.isLive = { true }
        pager.reduceMotion = true
        var time = 0.0
        pager.grab(at: time)
        for _ in 0 ..< 6 {
            time += frame
            pager.drag(by: 0.15, at: time)
        }
        time += frame
        pager.release(at: time)
        XCTAssertEqual(pager.selection, 1)
        for _ in 0 ..< 120 {
            time += frame
            pager.tick(at: time)
            XCTAssertLessThanOrEqual(pager.progress, 1 + 1e-12, "no overshoot")
        }
        XCTAssertEqual(pager.progress, 1)
    }

    // MARK: Helpers

    final class RowBuildCounter { var builds = 0 }

    private func hostSelector(_ pager: GlassTabPager) -> NSView {
        let bar = NotchGlassTabBar(
            pager: pager, tabs: historyTabs, accessibilityLabel: NotchHistoryPresentation.categorySelectorLabel,
            metrics: historyMetrics(), colors: .notch(.resolve(for: .dark)),
            identifier: { NotchHistoryPresentation.categoryIdentifier(SettingsHistoryScope.allCases[$0]) }
        )
        .environment(\.glassTabSolidPill, true)
        return hostView(bar, size: NSSize(width: 404, height: NotchHistoryPresentation.categorySelectorHeight))
    }

    private func hostPanel(archive: NotchHistoryArchiveStore, pager: GlassTabPager, counter: RowBuildCounter) -> NSView {
        let entries = (0 ..< 12).map {
            RecentTranscriptionEntry(text: "Synthetic dictation \($0).", recordingPath: "/synthetic/\($0).wav",
                                     createdAt: Date(timeIntervalSince1970: 1_794_400_000 + Double($0) * 60))
        }
        let dictations = NotchHistoryPanel(
            entries: entries, activeRetranscriptionPath: nil, palette: .resolve(for: .dark),
            onCopy: { _ in true }, onPaste: { _ in }, onRetranscribe: { _ in },
            rowHeader: { index in
                counter.builds += 1
                return "\(index) min ago"
            }
        )
        let panel = NotchHistoryCategoryPanel(dictations: dictations, archive: archive, pager: pager)
            .environment(\.glassTabSolidPill, true)
        return hostView(panel, size: NSSize(width: 404, height: 276))
    }

    private func hostView<V: View>(_ view: V, size: NSSize) -> NSView {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        windows.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// One drawn frame: SwiftUI's update, layout and display, as a display cycle runs them.
    private func render(_ host: NSView) {
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                              clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(event)
            }
        }
    }

    /// The accessibility element with this identifier, with its frame in screen points.
    private func element(_ id: String, in root: NSView) -> (id: String, frame: NSRect)? {
        func walk(_ node: Any, depth: Int) -> (id: String, frame: NSRect)? {
            guard depth < 40, let object = node as? NSObject else { return nil }
            let identifier = object.value(forKey: "accessibilityIdentifier") as? String ?? ""
            let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            if identifier == id, frame.width > 0 { return (identifier, frame) }
            for child in (object.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
                if let found = walk(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return walk(root, depth: 0)
    }
}
