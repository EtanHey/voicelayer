import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Design revision 2026-11-02: compact notes stay within the notch shell, expand downward,
/// and retain readable wrapped content without truncation. Settings and History follow the shared surface policy.
@MainActor
final class NotchCompactNoteTests: XCTestCase {
    private static let quitRefusal = "Finish voice work or cancel the update, then quit again."
    private static let long = "The speech model could not finish this transcription. Open History and select "
        + "the retained recording to retry when the model is available."

    /// Every visual state, through an exhaustive switch: a new state fails to compile until it is listed here,
    /// so it cannot silently add a wing-wide note.
    private func input(for state: VoiceBarNotchVisualState, coreWidth: CGFloat) -> VoiceBarNotchOperationalInput {
        switch state {
        case .idle:
            return .init(mode: .idle, isCollapsed: true, coreWidth: coreWidth)
        case .hoverLauncher:
            return .init(mode: .idle, isHovered: true, coreWidth: coreWidth)
        case .recording:
            return .init(mode: .recording, showsRecordingHold: true, coreWidth: coreWidth)
        case .compactStatus:
            // Not transcribing: N2 shows nothing under the notch then (NotchStatusFeedbackTests).
            return .init(mode: .speaking, statusText: "Speaking…", coreWidth: coreWidth)
        case .teleprompter:
            return .init(mode: .speaking, hasTeleprompterText: true, statusText: "Speaking…", coreWidth: coreWidth)
        case .history:
            var input = VoiceBarNotchOperationalInput(mode: .idle, coreWidth: coreWidth)
            input.isHistoryPanelOpen = true
            return input
        }
    }

    /// Every kind of note a presentation can carry: the short selection notes, "Select text first", the quit
    /// refusal, a long note, and long error/status copy that moves out of the wing.
    private func noteCases(_ base: VoiceBarNotchOperationalInput) -> [(String, VoiceBarNotchOperationalInput)] {
        func with(_ change: (inout VoiceBarNotchOperationalInput) -> Void) -> VoiceBarNotchOperationalInput {
            var copy = base
            change(&copy)
            return copy
        }
        return [
            ("busy note", with { $0.transientNote = "Busy recording. Selection not read" }),
            ("select text first", with { $0.transientNote = "Select text first" }),
            ("quit refusal", with { $0.transientNote = Self.quitRefusal }),
            ("long note", with { $0.transientNote = Self.long + " " + Self.long }),
            ("error with History", with { $0.mode = .error; $0.statusText = Self.long }),
            ("overflowing status", with {
                $0.mode = .idle; $0.confirmationText = Self.quitRefusal; $0.statusText = Self.quitRefusal
            }),
            ("status and note", with {
                $0.mode = .error; $0.statusText = Self.long; $0.transientNote = Self.quitRefusal
            }),
        ]
    }

    /// The tab width a note may take on its own: the notch, or the minimum on a narrow virtual notch.
    private func tabLimit(_ geometry: VoiceBarNotchGeometry) -> CGFloat {
        max(geometry.coreWidth, VoiceBarNotchContract.noteMinimumWidth)
    }

    func testEveryStatesNoteIsATabUnderTheNotchNeverAWing() throws {
        var checked = 0
        for core: CGFloat in [120, 185, 280] {
            for state in VoiceBarNotchVisualState.allCases {
                let base = input(for: state, coreWidth: core)
                let plain = VoiceBarPresentation.notchPresentation(from: base)
                for (kind, noted) in noteCases(base) {
                    let p = VoiceBarPresentation.notchPresentation(from: noted)
                    guard p.feedback != nil || p.transientNoteRect != nil else { continue }
                    checked += 1
                    let label = "\(state) / \(kind) / core \(core)"
                    let g = p.geometry
                    XCTAssertGreaterThan(g.lowerSurfaceHeight, 0, label)
                    let layout = VoiceBarNotchShapeLayout(geometry: g)
                    // The top row never overhangs the shell's own frame.
                    XCTAssertGreaterThanOrEqual(g.topOriginX, -0.001, label)
                    XCTAssertLessThanOrEqual(g.topOriginX + g.topWidth, g.totalWidth + 0.001, label)

                    let ownBody = p.ownBodyHeight > 0
                    if ownBody {
                        // The teleprompter / History body hosts the note at its existing width: no new wing.
                        let rest = plain.geometry
                        XCTAssertEqual(g.bodyLeadingExtent, rest.bodyLeadingExtent, label)
                        XCTAssertEqual(g.bodyTrailingExtent, rest.bodyTrailingExtent, label)
                    } else {
                        // A tab under the notch: never past either wing, never wider than the notch allows.
                        XCTAssertLessThanOrEqual(g.bodyLeadingExtent, g.leadingWingWidth, label)
                        XCTAssertLessThanOrEqual(g.bodyTrailingExtent, g.trailingWingWidth, label)
                        XCTAssertLessThanOrEqual(g.bodyWidth, tabLimit(g) + 0.001, label)
                        XCTAssertLessThanOrEqual(g.bodyWidth, g.topWidth, label)
                        if g.coreWidth >= VoiceBarNotchContract.noteMinimumWidth {
                            XCTAssertEqual(g.bodyWidth, g.coreWidth, "\(label): tucked exactly under the notch")
                            XCTAssertEqual(layout.bodyRect.minX, layout.coreRect.minX, accuracy: 0.001, label)
                        }
                        // The drawn outline agrees: no glass beside the tab, below the wings.
                        let path = VoiceBarNotchContinuousShape(
                            geometry: g, compactOuterCornerRadius: 15, bodyShoulderCornerRadius: 15
                        ).path(in: CGRect(origin: .zero, size: layout.totalSize))
                        let y = g.topHeight + min(10, g.lowerSurfaceHeight / 2)
                        XCTAssertTrue(path.contains(CGPoint(x: layout.bodyRect.midX, y: y)), "\(label): tab is drawn")
                        if g.leadingWingWidth > g.bodyLeadingExtent + 2 {
                            XCTAssertFalse(path.contains(CGPoint(x: layout.bodyRect.minX - 2, y: y)),
                                           "\(label): glass left of the tab is a wing slab")
                        }
                        if g.trailingWingWidth > g.bodyTrailingExtent + 2 {
                            XCTAssertFalse(path.contains(CGPoint(x: layout.bodyRect.maxX + 2, y: y)),
                                           "\(label): glass right of the tab is a wing slab")
                        }
                        // The wings themselves are still drawn.
                        XCTAssertTrue(path.contains(CGPoint(x: layout.leadingWingRect.midX, y: g.topHeight / 2)),
                                      label)
                    }
                    // The text column is the tab's, wherever the note sits.
                    if let feedback = p.feedback {
                        XCTAssertLessThanOrEqual(feedback.width, tabLimit(g) + 0.001, label)
                        XCTAssertLessThanOrEqual(feedback.width, layout.bodyRect.width + 0.001, label)
                    }
                    if let rect = p.transientNoteRect {
                        XCTAssertTrue(layout.bodyRect.insetBy(dx: -0.001, dy: -0.001).contains(rect), label)
                    }
                    // The resident model reproduces the same tab.
                    let model = VoiceBarNotchPresentationModel()
                    model.updateOperationalEnvelope(
                        hasTeleprompter: p.visualState == .teleprompter, isRecording: p.visualState == .recording,
                        hasCompactStatus: p.visualState == .compactStatus,
                        compactStatusLeadingWingWidth: p.geometry.leadingWingWidth,
                        compactStatusTrailingWingWidth: p.geometry.trailingWingWidth,
                        recordingLeadingWingWidth: p.geometry.leadingWingWidth,
                        recordingTrailingWingWidth: p.geometry.trailingWingWidth,
                        teleprompterLeadingWingWidth: p.visualState == .teleprompter ? g.leadingWingWidth : nil,
                        teleprompterTrailingWingWidth: p.visualState == .teleprompter ? g.trailingWingWidth : nil,
                        keepsIdleExpanded: p.visualState == .hoverLauncher,
                        coreWidth: core, transientNoteWidth: p.transientNoteWidth, feedback: p.feedback
                    )
                    if p.visualState != .history {
                        XCTAssertEqual(model.presentation.geometry, g, label)
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 60, "Every state × note kind must actually be exercised")
    }

    func testTheQuitRefusalIsATabNotTheLauncherWideSlab() throws {
        let p = VoiceBarPresentation.notchPresentation(from: .init(mode: .idle, transientNote: Self.quitRefusal))
        XCTAssertEqual(p.visualState, .hoverLauncher)
        XCTAssertEqual(p.geometry.bodyWidth, VoiceBarNotchContract.coreWidth)
        XCTAssertLessThan(p.geometry.bodyWidth, p.geometry.topWidth, "Narrower than the wings: not a slab")
        let f = try XCTUnwrap(p.feedback, "The refusal wraps, so it carries its grown height")
        XCTAssertEqual(f.noteText, Self.quitRefusal)
        XCTAssertGreaterThan(f.noteHeight, VoiceBarNotchContract.transientNoteBandHeight)
    }

    /// N3: long text wraps and the note grows down; the text is never shortened, line-limited or ellipsized.
    func testLongTextWrapsDownWithNoEllipsis() throws {
        let texts = [Self.quitRefusal, Self.long, "Select text first", "fu… " + Self.long]
        var previousHeight: CGFloat = 0
        for text in texts.sorted(by: { $0.count < $1.count }) {
            let p = VoiceBarPresentation.notchPresentation(from: .init(mode: .error, statusText: text))
            let f = try XCTUnwrap(p.feedback)
            XCTAssertEqual(f.statusText, text, "Stored copy is the full text")
            XCTAssertGreaterThanOrEqual(f.statusHeight, previousHeight, "Longer copy never gets a shorter note")
            previousHeight = f.statusHeight
            let host = NSHostingView(rootView: VoiceBarNotchFeedbackBand(feedback: f, onOpenHistory: {})
                .foregroundStyle(.white).background(.black))
            host.frame = NSRect(x: 0, y: 0, width: f.width, height: f.height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            VLOrderTestWindow(window)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            let label = try XCTUnwrap(mountedText(host, matching: text), "The complete string is mounted: \(text)")
            let frame = label.convert(label.bounds, to: host)
            let column = VoiceBarNotchFeedback.messageWidth(f.width, opensHistory: true)
            if VoiceBarNotchFeedback.textHeight(text, width: column) <= VoiceBarNotchFeedback.maximumTextHeight {
                XCTAssertTrue(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(text): inside the note")
            } else {
                // Past the bounded height the full text scrolls inside the note; it is still never cut.
                XCTAssertEqual(f.statusHeight, VoiceBarNotchFeedback.maximumTextHeight + 10, text)
            }
            let lineHeight = ceil(NSFont.systemFont(ofSize: 12, weight: .medium).boundingRectForFont.height)
            let measured = (text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]).width
            if measured > column {
                XCTAssertGreaterThan(frame.height, lineHeight * 1.5, "\(text): wraps onto more lines")
                XCTAssertGreaterThan(f.statusHeight, VoiceBarNotchContract.transientNoteBandHeight)
            }
            if let native = label as? NSTextView, let manager = native.layoutManager,
               let container = native.textContainer {
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(for: container)
                XCTAssertEqual(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).length,
                               (text as NSString).length, "Every character is laid out")
                manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
                    XCTAssertEqual(manager.truncatedGlyphRange(inLineFragmentForGlyphAt: range.location).location,
                                   NSNotFound, "No line truncates")
                }
            }
        }
    }

    /// N5: the History action trails the message on its own row; the note gains no action row.
    func testOpenHistorySharesTheMessageRow() throws {
        for text in ["Busy", Self.long] {
            let p = VoiceBarPresentation.notchPresentation(from: .init(mode: .error, statusText: text))
            let f = try XCTUnwrap(p.feedback)
            XCTAssertTrue(f.opensHistory)
            // No extra row: the height is the message's own, whatever the action.
            XCTAssertEqual(f.statusHeight, max(VoiceBarNotchContract.transientNoteBandHeight,
                min(VoiceBarNotchFeedback.maximumTextHeight, VoiceBarNotchFeedback.textHeight(
                    text, width: VoiceBarNotchFeedback.messageWidth(f.width, opensHistory: true))) + 10), text)
            let host = NSHostingView(rootView: VoiceBarNotchFeedbackBand(feedback: f, onOpenHistory: {})
                .foregroundStyle(.white).background(.black))
            host.frame = NSRect(x: 0, y: 0, width: f.width, height: f.height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            VLOrderTestWindow(window)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            let message = try XCTUnwrap(mountedText(host, matching: text))
            let mounted = message.convert(message.bounds, to: host)
            // Top-left points, matching the bitmap rows.
            let messageFrame = host.isFlipped ? mounted
                : CGRect(x: mounted.minX, y: host.bounds.height - mounted.maxY, width: mounted.width, height: mounted.height)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            // Ink to the right of the message is the action; it must sit beside the text, not under it.
            let column = VoiceBarNotchFeedback.messageWidth(f.width, opensHistory: true)
            let columnMaxX = (host.bounds.width - f.width) / 2 + VoiceBarNotchContract.transientNoteHorizontalInset + column
            XCTAssertLessThanOrEqual(messageFrame.maxX, columnMaxX + 0.5, "\(text): the message keeps to its column")
            let trailing = CGRect(x: columnMaxX + 1, y: 0,
                                  width: host.bounds.width - columnMaxX - 1, height: host.bounds.height)
            let ink = try XCTUnwrap(inkBounds(image, in: trailing, scale: CGFloat(image.width) / host.bounds.width),
                                    "\(text): the action renders trailing the message")
            XCTAssertGreaterThan(min(messageFrame.maxY, ink.maxY), max(messageFrame.minY, ink.minY),
                                 "\(text): the action shares the message's row")
            XCTAssertLessThanOrEqual(ink.width, VoiceBarNotchFeedback.historyButtonWidth + 2, text)
            XCTAssertLessThanOrEqual(ink.maxX, host.bounds.width - VoiceBarNotchContract.transientNoteHorizontalInset + 1,
                                     "\(text): the action stays inside the tab")
        }
        XCTAssertEqual(VoiceBarNotchFeedback.historyActionTitle, "Open History", "VoiceOver and the tooltip name it")
    }

    /// The tab drops straight down from under the notch and rises back into it: the spring never sweeps a
    /// wing-wide slab inward. History and the teleprompter keep their flush start.
    func testTheTabMorphNeverSweepsASlab() {
        for state in [VoiceBarNotchVisualState.hoverLauncher, .recording, .compactStatus] {
            let base = input(for: state, coreWidth: 185)
            var noted = base
            noted.transientNote = Self.quitRefusal
            let rest = VoiceBarPresentation.notchPresentation(from: base).geometry
            let tab = VoiceBarPresentation.notchPresentation(from: noted).geometry
            let open = VoiceBarNotchShellTransition.morphEndpoints(from: rest, to: tab)
            XCTAssertTrue(open.start.drawsIdentically(to: rest), "\(state): the rewrite is invisible")
            XCTAssertEqual(open.start.bodyLeadingExtent, tab.bodyLeadingExtent, "\(state)")
            XCTAssertEqual(open.start.bodyTrailingExtent, tab.bodyTrailingExtent, "\(state)")
            XCTAssertEqual(open.end, tab)
            let close = VoiceBarNotchShellTransition.morphEndpoints(from: tab, to: rest)
            XCTAssertEqual(close.start, tab)
            XCTAssertTrue(close.end.drawsIdentically(to: rest), "\(state): lands on the resting shell")
            XCTAssertEqual(close.end.bodyLeadingExtent, tab.bodyLeadingExtent, "\(state)")
            for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                var delta = VoiceBarNotchGeometryAnimatableData(geometry: open.end)
                    - VoiceBarNotchGeometryAnimatableData(geometry: open.start)
                delta.scale(by: progress)
                let frame = (VoiceBarNotchGeometryAnimatableData(geometry: open.start) + delta).geometry
                XCTAssertEqual(frame.bodyWidth, tab.bodyWidth, accuracy: 0.001, "\(state) @\(progress): no sweep")
            }
        }
        var historyInput = input(for: .history, coreWidth: 185)
        historyInput.isHistoryPanelOpen = true
        let launcher = VoiceBarPresentation.notchPresentation(from: input(for: .hoverLauncher, coreWidth: 185)).geometry
        let history = VoiceBarPresentation.notchPresentation(from: historyInput).geometry
        XCTAssertEqual(VoiceBarNotchShellTransition.morphEndpoints(from: launcher, to: history).start,
                       launcher.bodyFlushWithWings, "History still opens flush with its wings")
    }

    private func mountedText(_ view: NSView, matching text: String) -> NSView? {
        if let label = view as? NSTextField, label.stringValue == text { return label }
        if let label = view as? NSTextView, label.string == text { return label }
        if view.accessibilityValue() as? String == text { return view }
        return view.subviews.compactMap { mountedText($0, matching: text) }.first
    }

    /// Bounding box (view points, top-left origin) of bright pixels inside `rect`.
    private func inkBounds(_ image: CGImage, in rect: CGRect, scale: CGFloat) throws -> CGRect? {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0 ..< crop.height {
            for column in 0 ..< crop.width {
                let offset = (row * crop.width + column) * 4
                let luminance = (54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1]) + 19 * Int(bytes[offset + 2])) / 256
                guard luminance > 120 else { continue }
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // CGImage rows start at the top, as the view's flipped points do.
        return CGRect(x: rect.minX + CGFloat(minX) / scale, y: rect.minY + CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
