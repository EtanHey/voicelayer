import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Review round 2: Hebrew and mixed Hebrew/English compact notes, mounted in the real `BarView` through the resident
/// presentation model, under both layout directions, at physical notch widths (resolved from hardware housing
/// metrics) and the virtual flat-display notch. The full text must be mounted and laid out (the scroll case too),
/// Open History must share the text's row on its trailing side and stay inside the tab, and the interactive region
/// must exclude the app and menu-bar space around the tab.
@MainActor
final class NotchCompactNoteRTLTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private static let hebrew = "התמלול נכשל: מודל הדיבור לא סיים את ההקלטה. פתחו את ההיסטוריה ובחרו את ההקלטה השמורה "
        + "כדי לנסות שוב כשהמודל יהיה זמין."
    private static let mixed = "Parakeet לא סיים את התמלול של 0:37 — whisper-server לא הגיב. נסו שוב מ-History."
    private static let scrolling = String(repeating: hebrew + " ", count: 6).trimmingCharacters(in: .whitespaces)
    private static let hebrewNote = "סיימו את העבודה הקולית או בטלו את העדכון, ואז צאו שוב מ-VoiceBar."

    private struct Screen {
        let name: String
        let geometry: VoiceBarNotchScreenGeometry
    }

    /// Two physical housings (AppKit's auxiliary areas leave a 202 or 186 pt gap; calibration trims 8.5 pt a side)
    /// and the 185 pt virtual notch of a flat display.
    private var screens: [Screen] {
        func notch(gap: CGFloat) -> VoiceBarNotchScreenGeometry {
            let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
            let left = (frame.width - gap) / 2
            return .resolve(metrics: .init(frame: frame, visibleFrame: frame.insetBy(dx: 0, dy: 19),
                                           safeAreaTop: 32,
                                           auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: left, height: 32),
                                           auxiliaryTopRightArea: CGRect(x: left + gap, y: 950, width: left, height: 32)))
        }
        let flat = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return [
            Screen(name: "physical 185", geometry: notch(gap: 202)),
            Screen(name: "physical 169", geometry: notch(gap: 186)),
            Screen(name: "virtual", geometry: .resolve(metrics: .init(
                frame: flat, visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056), safeAreaTop: 0,
                auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil))),
        ]
    }

    private enum Case: CaseIterable {
        case hebrewDiagnostic, mixedDiagnostic, scrollingDiagnostic, busyNote, hebrewNote
    }

    private struct Mounted {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let presentation: VoiceBarNotchPresentation
        let layout: VoiceBarPanelLayout
        let text: String
    }

    private func mount(_ kind: Case, screen: Screen, direction: LayoutDirection) throws -> Mounted {
        let state = VoiceState(keepsExpandedInDevState: true)
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { _ in }
        let core = screen.geometry.housingFrame.width
        let inset = screen.geometry.visibleCoreOcclusionInset
        var input: VoiceBarNotchOperationalInput
        let text: String
        switch kind {
        case .hebrewDiagnostic, .mixedDiagnostic, .scrollingDiagnostic:
            text = kind == .hebrewDiagnostic ? Self.hebrew : kind == .mixedDiagnostic ? Self.mixed : Self.scrolling
            state.handleEvent(["type": "error", "message": text])
            input = .init(mode: .error, statusText: VoiceBarPresentation.errorStatusText(text),
                          coreWidth: core, visibleCoreOcclusionInset: inset)
        case .busyNote:
            state.mode = .recording
            state.speakSelection()
            text = try XCTUnwrap(state.selectionFeedbackNote)
            input = .init(mode: .recording, coreWidth: core, visibleCoreOcclusionInset: inset, transientNote: text)
        case .hebrewNote:
            text = Self.hebrewNote
            state.isHovering = true
            input = .init(mode: .idle, isHovered: true, coreWidth: core, visibleCoreOcclusionInset: inset,
                          transientNote: text)
        }
        let resolved = VoiceBarPresentation.notchPresentation(from: input)
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(
            hasTeleprompter: false, isRecording: resolved.visualState == .recording,
            hasCompactStatus: resolved.visualState == .compactStatus,
            compactStatusLeadingWingWidth: resolved.geometry.leadingWingWidth,
            compactStatusTrailingWingWidth: resolved.geometry.trailingWingWidth,
            recordingLeadingWingWidth: resolved.geometry.leadingWingWidth,
            recordingTrailingWingWidth: resolved.geometry.trailingWingWidth,
            keepsIdleExpanded: resolved.visualState == .hoverLauncher,
            coreWidth: core, visibleCoreOcclusionInset: inset,
            virtualNotchIdleCoreHeight: screen.geometry.virtualNotchIdleCoreHeight,
            transientNoteWidth: resolved.transientNoteWidth, feedback: resolved.feedback)
        XCTAssertEqual(model.presentation.geometry, resolved.geometry, "\(screen.name): the resident model's shell")
        XCTAssertEqual(model.presentation.feedback, resolved.feedback, "\(screen.name): the resident model's note")
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        let layout = VoiceBarPanelLayout.make(presentation: model.presentation, canvasGeometry: canvas)
        let host = NSHostingView(rootView: AnyView(
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, .dark)
                .environment(\.layoutDirection, direction)
        ))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: layout.panelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window, presentation: model.presentation, layout: layout, text: text)
    }

    private func mountedText(_ view: NSView, matching text: String) -> NSView? {
        if let label = view as? NSTextField, label.stringValue == text { return label }
        if let label = view as? NSTextView, label.string == text { return label }
        if view.accessibilityValue() as? String == text { return view }
        return view.subviews.compactMap { mountedText($0, matching: text) }.first
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// Window coordinates (lower-left), as the panel layout uses.
    private func frame(_ view: NSView) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    func testHebrewAndMixedNotesStayWholeInlineAndInsideTheTab() throws {
        var checked = 0
        for screen in screens {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                for kind in Case.allCases {
                    let mounted = try mount(kind, screen: screen, direction: direction)
                    defer { mounted.window.contentView = nil; mounted.window.close() }
                    let label = "\(screen.name) / \(direction) / \(kind)"
                    let feedback = try XCTUnwrap(mounted.presentation.feedback, "\(label): wrapped text is feedback")
                    let geometry = mounted.presentation.geometry
                    let shell = mounted.layout.visibleContentRect
                    // The tab, in window coordinates: the lower body, under the top row.
                    let tab = CGRect(x: shell.minX + geometry.bodyOriginX, y: shell.minY,
                                     width: geometry.bodyWidth, height: geometry.lowerSurfaceHeight)
                    XCTAssertLessThanOrEqual(geometry.bodyWidth,
                        max(geometry.coreWidth, VoiceBarNotchContract.noteMinimumWidth) + 0.001, label)

                    // 1. The full text is mounted and every character is laid out, untruncated.
                    let node = try XCTUnwrap(mountedText(mounted.host, matching: mounted.text),
                                             "\(label): the full string is mounted")
                    if let native = node as? NSTextView, let manager = native.layoutManager,
                       let container = native.textContainer {
                        manager.ensureLayout(for: container)
                        let glyphs = manager.glyphRange(for: container)
                        XCTAssertEqual(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).length,
                                       (mounted.text as NSString).length, "\(label): every character laid out")
                        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
                            XCTAssertEqual(manager.truncatedGlyphRange(inLineFragmentForGlyphAt: range.location).location,
                                           NSNotFound, "\(label): a line truncates")
                        }
                    }
                    let textFrame = frame(node)
                    let opensHistory = kind == .busyNote || [.hebrewDiagnostic, .mixedDiagnostic, .scrollingDiagnostic].contains(kind)
                    let column = VoiceBarNotchFeedback.messageWidth(feedback.width, opensHistory: opensHistory)
                    let scrolls = VoiceBarNotchFeedback.textHeight(mounted.text, width: column)
                        > VoiceBarNotchFeedback.maximumTextHeight
                    if scrolls {
                        // The scroll case: the whole text is in a scroll view whose viewport sits in the tab.
                        let scroll = try XCTUnwrap(sequence(first: node, next: \.superview)
                            .compactMap { $0 as? NSScrollView }.first, "\(label): long text scrolls")
                        XCTAssertTrue(tab.insetBy(dx: -0.5, dy: -0.5).contains(frame(scroll)), "\(label): viewport \(frame(scroll)) ⊄ tab \(tab)")
                        XCTAssertGreaterThan(textFrame.height, frame(scroll).height, "\(label): more text than viewport")
                    } else {
                        XCTAssertNotEqual(kind, .scrollingDiagnostic, "\(label): six paragraphs must scroll")
                        XCTAssertTrue(tab.insetBy(dx: -0.5, dy: -0.5).contains(textFrame),
                                      "\(label): text \(textFrame) ⊄ tab \(tab)")
                    }

                    // 2. Open History: on the text's row, on its trailing side, inside the tab.
                    let actions = views(PillControlTooltip.TooltipView.self, in: mounted.host)
                        .filter { $0.toolTip == VoiceBarNotchFeedback.historyActionTitle }
                    XCTAssertEqual(actions.count, opensHistory ? 1 : 0, "\(label): Open History count")
                    if let action = actions.first {
                        let actionFrame = frame(action)
                        XCTAssertTrue(tab.insetBy(dx: -0.5, dy: -0.5).contains(actionFrame),
                                      "\(label): Open History \(actionFrame) ⊄ tab \(tab)")
                        let row = scrolls ? frame(try XCTUnwrap(sequence(first: node, next: \.superview)
                            .compactMap { $0 as? NSScrollView }.first)) : textFrame
                        XCTAssertGreaterThan(min(row.maxY, actionFrame.maxY), max(row.minY, actionFrame.minY),
                                             "\(label): Open History left the text's row")
                        if direction == .rightToLeft {
                            XCTAssertLessThanOrEqual(actionFrame.maxX, row.minX + 0.5, "\(label): RTL trailing is left")
                        } else {
                            XCTAssertGreaterThanOrEqual(actionFrame.minX, row.maxX - 0.5, "\(label): LTR trailing is right")
                        }
                        XCTAssertLessThanOrEqual(actionFrame.width, VoiceBarNotchFeedback.historyButtonWidth + 0.5,
                                                 "\(label): the action keeps its own compact column")
                    }

                    // 3. Interactive region: the tab, never the app or menu-bar space around it.
                    let layout = mounted.layout
                    let midY = tab.midY
                    XCTAssertTrue(layout.containsInteractiveContent(CGPoint(x: tab.midX, y: midY)), "\(label): tab")
                    let wingSpan = shell.minX + geometry.topOriginX
                    if tab.minX - 6 > wingSpan {
                        XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: tab.minX - 6, y: midY)),
                                       "\(label): beside the tab, under the wing, is app space")
                    }
                    if tab.maxX + 6 < wingSpan + geometry.topWidth {
                        XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: tab.maxX + 6, y: midY)),
                                       "\(label): beside the tab, under the wing, is app space")
                    }
                    let menuBarY = shell.minY + geometry.lowerSurfaceHeight + geometry.topHeight / 2
                    XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: shell.minX - 4, y: menuBarY)),
                                   "\(label): menu bar left of the shell")
                    XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: shell.maxX + 4, y: menuBarY)),
                                   "\(label): menu bar right of the shell")
                    XCTAssertFalse(layout.containsInteractiveContent(CGPoint(x: tab.midX, y: tab.minY - 3)),
                                   "\(label): below the tab")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 3 * 2 * Case.allCases.count)
    }
}
