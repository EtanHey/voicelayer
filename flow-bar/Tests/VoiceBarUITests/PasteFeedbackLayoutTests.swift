import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision
@testable import VoiceBarUI
import XCTest

@MainActor
final class PasteFeedbackLayoutTests: XCTestCase {
    private var messages: [String] {
        let selectionFailures: [SelectionCaptureResult] = [
            .clipboardChanged, .copyTimedOut, .copyEmpty, .copyFailed,
        ]
        return [PasteRecoveryFeedback.notInserted, PasteRecoveryFeedback.unverified,
                PasteRecoveryFeedback.partial] + selectionFailures.map { result in
            let state = VoiceState()
            state.sendCommand = { _ in XCTFail("Capture failure must send no commands") }
            state.selectionTextCaptureHandler = { $0(result) }
            state.speakSelection()
            return state.confirmationText ?? ""
        }
    }

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    // This test has no OCR dependency and must never skip on a hosted runner.
    func testEveryRecoveryMessageIsFullyRenderedInBothAppearances() throws {
        try forEveryRender { _, _, _ in }
    }

    func testEveryRecoveryMessageAndBadgeHasVisibleWordsWhenOCRIsAvailable() throws {
        try requireOCR()
        try forEveryRender(checksOCR: true) { image, textFrame, message in
            let visible = try [0, 1].map { line in
                let crop = try XCTUnwrap(image.cropping(to: CGRect(
                    x: textFrame.minX, y: CGFloat(line) * textFrame.height / 2,
                    width: textFrame.width, height: textFrame.height / 2)))
                return try recognize(crop).joined(separator: " ")
            }.joined(separator: " ")
            XCTAssertEqual(words(visible), words(message), "Full feedback must be visible: \(visible)")
            XCTAssertFalse(visible.contains("…") || visible.contains("..."), "No rendered ellipsis")
        }
    }

    func testEmptyOCRControlSkipsOnlyTheOCRTest() throws {
        var probed = false
        XCTAssertThrowsError(try requireOCR { _ in probed = true; return [] }) { error in
            XCTAssertTrue(error is XCTSkip)
        }
        XCTAssertTrue(probed, "Even the unavailable seam must render and probe a control")
    }

    func testOrdinaryStatusAndTerminalPreviewRemainOneLine() {
        for message in ["Copied", "Preparing speech…", "QA terminal transcript שלום 👋"] {
            let label = NSHostingView(rootView:
                CompactStatusLabel(text: message, mode: .idle, confirmationText: message)
                    .frame(width: 68).fixedSize(horizontal: false, vertical: true))
            XCTAssertLessThanOrEqual(label.fittingSize.height, 15)
        }
    }

    private func forEveryRender(checksOCR: Bool = false, checkWords: (CGImage, CGRect, String) throws -> Void) throws {
        for screenWidth in [800.0, 1024.0, 1728.0] {
            for (index, message) in messages.enumerated() {
                for queueDepth in [0, 12] {
                    for light in [false, true] {
                        let state = VoiceState()
                        state.mode = .idle
                        state.isCollapsed = false
                        state.confirmationText = message
                        state.queueDepth = queueDepth
                        state.sendCommand = { _ in XCTFail("Layout must send no commands") }
                        let presentation = VoiceBarPresentation.notchPresentation(from: .init(
                            mode: .idle, confirmationText: message, queueDepth: queueDepth, statusText: message
                        ))
                        let model = VoiceBarNotchPresentationModel()
                        model.updateOperationalEnvelope(
                            hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
                            compactStatusLeadingWingWidth: presentation.geometry.leadingWingWidth,
                            compactStatusTrailingWingWidth: presentation.geometry.trailingWingWidth
                        )
                        XCTAssertEqual(model.presentation.geometry, presentation.geometry)
                        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation)
                        let screen = screenGeometry(width: screenWidth)
                        let layout = VoiceBarPanelLayout.make(presentation: model.presentation, canvasGeometry: canvas.canvasGeometry)
                        XCTAssertTrue(screen.screenFrame.contains(layout.windowFrame(anchoredTo: screen)))
                        let geometry = presentation.geometry
                        XCTAssertLessThanOrEqual(geometry.trailingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity)
                        XCTAssertEqual(canvas.canvasGeometry.totalWidth, 465, "Keep the ordinary canvas")
                        XCTAssertEqual(geometry.leadingWingWidth, VoiceBarNotchContract.compactIndicatorLaneWidth)
                        XCTAssertEqual(geometry.topHeight, 32)
                        let size = CGSize(width: canvas.canvasGeometry.totalWidth + 24, height: 49)
                        let host = NSHostingView(rootView:
                            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                                    presentationModel: model, includesPanelOutsets: true)
                                .environment(\.colorScheme, light ? .light : .dark)
                        )
                        host.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: .borderless, backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        defer { window.close() }
                        window.contentView = host
                        VLOrderTestWindow(window)
                        host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        let image = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
                        let scale = CGFloat(image.height) / size.height
                        let queueWidth = queueDepth > 0 ? Theme.intrinsicPillStatusWidth(for: "\(queueDepth)") + 16 : 0
                        let slot = VoiceBarNotchContract.material.wingContentLayout(for: .trailing,
                            state: .compactStatus, visibleCoreOcclusionInset: 0)
                        let availableWidth = geometry.trailingWingWidth - slot.coreInset - slot.outerInset - queueWidth
                        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                        let lines = message.components(separatedBy: "\n")
                        let label = NSHostingView(rootView:
                            CompactStatusLabel(text: message, mode: state.mode, confirmationText: state.confirmationText)
                                .frame(width: availableWidth).fixedSize(horizontal: false, vertical: true))
                        let textSize = label.fittingSize
                        XCTAssertEqual(lines.count, 2, "Feedback must have two explicit lines: \(message)")
                        XCTAssertFalse(message.contains("…") || message.contains("..."))
                        // Unwrapped line widths plus the two-line height prove that fitting
                        // this copy cannot require truncation, even when Vision is unavailable.
                        for line in lines {
                            XCTAssertLessThanOrEqual(ceil((line as NSString).size(withAttributes: [.font: font]).width),
                                                     availableWidth, "No ellipsis budget: \(line)")
                            XCTAssertLessThanOrEqual((line as NSString).size(withAttributes: [.font: font]).width,
                                                     textSize.width + 0.5, "Full line must fit the rendered frame")
                        }
                        let required = (message as NSString).boundingRect(
                            with: CGSize(width: availableWidth, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
                        XCTAssertLessThanOrEqual(ceil(required.height), geometry.topHeight)
                        XCTAssertLessThanOrEqual(ceil(required.height), textSize.height + 0.5,
                                                 "A one-line rendered label must not pass a two-line fit check")
                        let lineHeight = ceil(font.ascender - font.descender + font.leading)
                        XCTAssertEqual(Int((textSize.height / lineHeight).rounded()), 2,
                                       "Actual rendered line count, independent of Vision")
                        XCTAssertLessThanOrEqual(geometry.topOriginX + geometry.topWidth,
                                                 canvas.canvasGeometry.totalWidth - canvas.contentOffsetX)
                        // Badge's actual rounded 10 pt glyphs + padding + HStack spacing
                        // must fit the budget reserved before the text, independently of OCR.
                        let badgeFont = NSFont.systemFont(ofSize: 10, weight: .bold)
                        let roundedBadgeFont = NSFont(descriptor: badgeFont.fontDescriptor.withDesign(.rounded)!, size: 10)!
                        let badgeWidth = ("12" as NSString).size(withAttributes: [.font: roundedBadgeFont]).width + 12
                        if queueDepth > 0 {
                            XCTAssertLessThanOrEqual(ceil(badgeWidth) + 4, queueWidth)
                            XCTAssertLessThanOrEqual(ceil(roundedBadgeFont.ascender - roundedBadgeFont.descender) + 4,
                                                     geometry.topHeight)
                        }
                        // Vision merges adjacent 12 pt lines in the whole notch. Preserve
                        // P1e's per-line crop and slack for the smaller rounded badge glyphs.
                        let cropInset = max(0, queueWidth - 4)
                        let textX = 12 + canvas.canvasGeometry.coreOriginX + geometry.coreWidth
                            + slot.coreInset + cropInset
                        try checkWords(image, CGRect(x: textX * scale, y: 0,
                            width: (geometry.trailingWingWidth - slot.coreInset - slot.outerInset - cropInset) * scale,
                            height: 32 * scale), message)
                        if queueDepth > 0, checksOCR {
                            let badge = try XCTUnwrap(image.cropping(to: CGRect(
                                x: (textX - cropInset) * scale, y: 0,
                                width: (queueWidth - 4) * scale, height: 32 * scale)))
                            XCTAssertEqual(try recognize(badge), ["12"], "Badge must remain visible")
                        }
                        if VisualArtifactTestPolicy.isRegenerationEnabled() {
                            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                                .appendingPathComponent("docs.local/P1F")
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            try png.write(to: directory.appendingPathComponent(
                                "feedback-\(Int(screenWidth))-\(index)-queue\(queueDepth)-\(light ? "light" : "dark").png"))
                        }
                    }
                }
            }
        }
    }

    private func requireOCR(read: ((CGImage) throws -> [String])? = nil) throws {
        // AppKit control rendering avoids classifying a broken feedback crop as a
        // missing host capability. Vision errors still fail; only empty results skip.
        let control = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: control)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 400, height: 80).fill()
        ("VoiceBar OCR 123" as NSString).draw(at: NSPoint(x: 12, y: 22), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(control.cgImage)
        let result: [String]
        if let read { result = try read(image) }
        else if ProcessInfo.processInfo.environment["VOICEBAR_TEST_FORCE_OCR_UNAVAILABLE"] == "1" { result = [] }
        else { result = try recognize(image) }
        try XCTSkipIf(result.isEmpty, "Vision OCR unavailable on this host")
        XCTAssertEqual(words(result.joined(separator: " ")), words("VoiceBar OCR 123"))
    }

    private func recognize(_ image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    func testRecoveryKeepsTheMicrophoneAndCoreAnchoredWithQueueBadge() {
        for screenWidth in [800.0, 1024.0, 1728.0] {
            let screen = screenGeometry(width: screenWidth)
            var referenceMicFrame: CGRect?
            for message in ["Copied"] + messages {
                for queueDepth in [0, 12] {
                    let presentation = VoiceBarPresentation.notchPresentation(from: .init(
                        mode: .idle, confirmationText: message, queueDepth: queueDepth, statusText: message
                    ))
                    let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
                    let layout = VoiceBarPanelLayout.make(presentation: presentation, canvasGeometry: canvas.canvasGeometry)
                    let frame = layout.windowFrame(anchoredTo: screen)
                    let geometry = presentation.geometry
                    let micFrame = CGRect(
                        x: frame.minX + layout.visibleContentRect.minX + geometry.topOriginX,
                        y: frame.maxY - geometry.topHeight,
                        width: geometry.leadingWingWidth, height: geometry.topHeight
                    )
                    if let referenceMicFrame { XCTAssertEqual(micFrame, referenceMicFrame) }
                    else { referenceMicFrame = micFrame }
                    XCTAssertEqual(frame.minX + layout.visibleContentRect.minX + geometry.coreMidX,
                                   screen.housingFrame.midX)
                    XCTAssertEqual(layout.panelSize.height, 49)
                    XCTAssertTrue(screen.screenFrame.contains(frame))
                    XCTAssertLessThanOrEqual(geometry.trailingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity)
                    XCTAssertEqual(canvas.canvasGeometry.totalWidth, 465)
                }
            }
        }
    }

    private func screenGeometry(width: CGFloat) -> VoiceBarNotchScreenGeometry {
        VoiceBarNotchScreenGeometry.resolve(metrics: .init(
            frame: CGRect(x: 0, y: 0, width: width, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: 1085), safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: width / 2 - 92.5, height: 32),
            auxiliaryTopRightArea: CGRect(x: width / 2 + 92.5, y: 1085, width: width / 2 - 92.5, height: 32)
        ))
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
