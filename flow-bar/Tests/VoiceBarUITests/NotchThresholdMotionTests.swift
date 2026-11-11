import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C6 L2 (S9, N17): the History → Settings threshold and the drawer's tab switch replaced their content in one
/// frame ("tabbed History at 186.867 s becomes blank at 186.900 s"; "Release History at 189.542 s becomes General at
/// 189.567 s"), and the grip became "Release for Settings" between two consecutive frames (60.597 → 60.613 s).
///
/// Each switch is now one crossfade: the outgoing content stays on screen while it fades out under the incoming
/// one (`NotchDrawerMotion`). The real BarView in the real panel, offscreen, driven by real pointer events; the
/// swap modifier's environment probe records the frames SwiftUI actually draws. (The accessibility tree cannot
/// show this: SwiftUI drops a view from it the moment its removal transition starts.)
@MainActor
final class NotchThresholdMotionTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var restoreAccessibility: (() -> Void)?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            // Offscreen SwiftUI builds its accessibility tree only for an AX client; this enables it in this test
            // process only (TeleprompterAWholeWordsTests' pattern). No AX client, setting or live app is touched.
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
            NotchDrawerSwapProbe.observer = nil
            for window in windows {
                window.isReleasedWhenClosed = false
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        super.tearDown()
    }

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private struct Harness {
        let model: VoiceBarNotchPresentationModel
        let surface: NotchSurfaceModel
        let host: PillHostingView<AnyView>
        let frames: FrameLog
        let panel: FloatingPillPanel
    }

    final class FrameLog {
        var frames: [NotchDrawerSwapFrame] = []
        func reset() { frames.removeAll() }
        /// Frames strictly between hidden and shown: the content was drawn part-way through a fade.
        func midway(_ phase: NotchDrawerSwapPhase) -> [NotchDrawerSwapFrame] {
            frames.filter { $0.phase == phase && $0.opacity > 0.02 && $0.opacity < 0.98 }
        }
    }

    private func drain(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, to panel: NSWindow) throws {
        panel.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )))
    }

    private func layout(_ model: VoiceBarNotchPresentationModel) -> VoiceBarPanelLayout {
        VoiceBarPanelLayout.make(
            presentation: model.presentation,
            interactionConfiguration: VoiceBarNotchInteractionConfiguration(leadingControlCount: 2, trailingControlCountFromCore: 2),
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        )
    }

    private func resize(_ harness: Harness) {
        let size = layout(harness.model).panelSize
        harness.panel.setContentSize(size)
        harness.host.frame = NSRect(origin: .zero, size: size)
        harness.host.layoutSubtreeIfNeeded()
    }

    private func makeHarness() -> Harness {
        let state = VoiceState(
            recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in },
            transcriptionVocabularyLoader: { [] }, transcriptionVocabularyAliasLoader: { [] },
            keepsExpandedInDevState: false
        )
        state.isConnected = true
        state.isCollapsed = false
        state.isHovering = true
        state.recentTranscriptionEntries = (0 ..< 20).map { index in
            RecentTranscriptionEntry(text: "Synthetic history row \(index + 1).", recordingPath: "/synthetic/\(index).wav",
                                     createdAt: Date().addingTimeInterval(Double(-60 * index)))
        }
        let model = VoiceBarNotchPresentationModel()
        let surface = NotchSurfaceModel()
        surface.log = { _ in }
        let context = NotchSettingsDrawerContext(updates: nil, pane: { tab, _ in
            AnyView(Text("\(tab.title) pane").accessibilityIdentifier("pane-\(tab.title.lowercased())"))
        })
        let frames = FrameLog()
        let host = PillHostingView(rootView: AnyView(BarView(
            state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
            presentationModel: model, includesPanelOutsets: true, surface: surface, settingsDrawer: context
        )))
        NotchDrawerSwapProbe.observer = { frames.frames.append($0) }
        host.activeHitTestProvider = { _ in true }
        host.renderedSurfaceHitTestProvider = { _ in true }
        let panel = FloatingPillPanel(content: host)
        panel.isPillDragEnabled = false
        panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000))
        panel.orderBack(nil)
        windows.append(panel)
        model.setHovered(true)
        let harness = Harness(model: model, surface: surface, host: host, frames: frames, panel: panel)
        resize(harness)
        drain(0.3)
        return harness
    }

    private func identifiers(_ root: Any, depth: Int = 0) -> Set<String> {
        guard depth < 40, let object = root as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return [] }
        var found: Set<String> = []
        if let identifier = object.value(forKey: "accessibilityIdentifier") as? String, !identifier.isEmpty {
            found.insert(identifier)
        }
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            found.formUnion(identifiers(child, depth: depth + 1))
        }
        return found
    }

    /// The window point at the centre of the first accessibility element labelled `label`.
    private func point(labelled label: String, _ harness: Harness, _ root: Any? = nil, depth: Int = 0) -> NSPoint? {
        guard depth < 40, let object = (root ?? harness.host) as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityRole")) else { return nil }
        if object.value(forKey: "accessibilityLabel") as? String == label,
           let frame = (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, frame.width > 0 {
            return harness.panel.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        }
        for child in object.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            if let found = point(labelled: label, harness, child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// History's body, `fromTop` points below the top of the notch, on its centre line (window space is unflipped).
    private func bodyPoint(_ harness: Harness, fromTop: CGFloat) -> NSPoint {
        let current = layout(harness.model)
        let x = current.visibleContentRect.minX + current.presentation.geometry.coreMidX
        return NSPoint(x: x, y: harness.host.bounds.height - 17 - fromTop)
    }

    private func visible(_ harness: Harness) -> Set<String> {
        harness.host.layoutSubtreeIfNeeded()
        return identifiers(harness.host)
    }

    private func wait(_ condition: () -> Bool, seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { drain() }
    }

    private func openDrawer(_ harness: Harness, _ event: NotchSurfaceEvent) {
        harness.surface.send(event)
        wait { harness.model.isHistoryPanelOpen }
        resize(harness)
        drain(1.0)
        resize(harness)
    }

    private let firstRow = NotchHistoryPresentation.rowAccessibilityIdentifier(index: 0)

    /// Releasing a pull past open swaps History's list for the Settings drawer: the list fades out under General.
    func testTheThresholdSwitchCrossfadesHistoryIntoSettings() throws {
        // (A release, not a programmatic open: only the user's switch is a content swap.)
        let harness = makeHarness()
        openDrawer(harness, .openHistory)
        XCTAssertTrue(visible(harness).contains(firstRow), "History's list is open")

        // The real gesture: History's body pulled past open, then released (Etan: "drag further down opens Settings").
        let start = bodyPoint(harness, fromTop: 120)
        try send(.leftMouseDown, at: start, to: harness.panel)
        drain()
        for step in 1 ... 12 {
            try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - CGFloat(step) * 140 / 12), to: harness.panel)
            drain(0.02)
        }
        harness.frames.reset()
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 140), to: harness.panel)
        drain(0.8)
        XCTAssertEqual(harness.surface.drawer, .settings(.general), "the release opened Settings")
        XCTAssertFalse(harness.frames.midway(.leaving).isEmpty,
                       "History's list fades out across frames instead of vanishing in one")
        XCTAssertFalse(harness.frames.midway(.resting).isEmpty, "General fades in across frames")
        let after = visible(harness)
        XCTAssertFalse(after.contains(firstRow), "the crossfade finishes")
        XCTAssertTrue(after.contains("pane-general"))
    }

    /// A tab switch inside the drawer crossfades too (History tab → General).
    func testATabSwitchCrossfadesTheDrawerContent() throws {
        let harness = makeHarness()
        openDrawer(harness, .openSettings(.history))
        XCTAssertTrue(visible(harness).contains(firstRow), "the History tab shows History's list")

        let general = try XCTUnwrap(point(labelled: SettingsTab.general.title, harness), "the General tab")
        harness.frames.reset()
        try send(.leftMouseDown, at: general, to: harness.panel)
        try send(.leftMouseUp, at: general, to: harness.panel)
        drain(0.6)
        XCTAssertEqual(harness.surface.drawer, .settings(.general), "the click selected General")
        XCTAssertFalse(harness.frames.midway(.leaving).isEmpty, "the History tab list fades out instead of vanishing")
        XCTAssertFalse(harness.frames.midway(.resting).isEmpty, "General fades in")
        XCTAssertTrue(visible(harness).contains("pane-general"))
        XCTAssertFalse(visible(harness).contains(firstRow))
    }

    /// N17: the grip hands off to "Release for Settings" and back as one crossfade, never a one-frame swap.
    func testTheReleaseHintHandsOffFromTheGripAndBack() throws {
        let harness = makeHarness()
        openDrawer(harness, .openHistory)
        let hint = NotchHistoryPresentation.settingsPullHintIdentifier

        // Press History's body and pull past open until the hint arms (window space is unflipped).
        let start = bodyPoint(harness, fromTop: 120)
        try send(.leftMouseDown, at: start, to: harness.panel)
        drain()
        harness.frames.reset()
        var dy: CGFloat = 0
        while !visible(harness).contains(hint), dy < 400 {
            dy += 12
            try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - dy), to: harness.panel)
            drain(0.02)
        }
        XCTAssertTrue(visible(harness).contains(hint), "pulling past open arms the Settings hint")

        drain(0.4)
        XCTAssertFalse(harness.frames.midway(.resting).isEmpty, "the hint fades in over the grip")

        // Back above the threshold: the hint fades out rather than vanishing in the next frame.
        harness.frames.reset()
        try send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 6), to: harness.panel)
        drain(0.6)
        XCTAssertFalse(harness.frames.midway(.leaving).isEmpty, "the hint fades out across frames")
        XCTAssertFalse(visible(harness).contains(hint), "and then it is gone")
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: start.y - 6), to: harness.panel)
        drain(0.5)
    }
}
