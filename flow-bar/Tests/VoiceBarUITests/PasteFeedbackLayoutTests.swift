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
                PasteRecoveryFeedback.partial, MicDisconnectFeedback.pill(atMs: 42400)] + selectionFailures.map { result in
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
        try forEveryRender(checksOCR: true) { image, textFrame, message in
            let visible = try [0, 1].map { line in
                let crop = try XCTUnwrap(image.cropping(to: CGRect(
                    x: textFrame.minX, y: CGFloat(line) * textFrame.height / 2,
                    width: textFrame.width, height: textFrame.height / 2)))
                try reportCropInk(crop, label: "line=\(line) message=\(message.debugDescription)")
                try requireReadableCrop(crop)
                try requireOCR(size: CGSize(width: crop.width, height: crop.height), scale: textFrame.height / 32)
                return try recognize(crop).joined(separator: " ")
            }.joined(separator: " ")
            XCTAssertEqual(words(visible), words(message), "Full feedback must be visible: \(visible)")
            XCTAssertFalse(visible.contains("…") || visible.contains("..."), "No rendered ellipsis")
        }
    }

    func testEmptyOCRControlSkipsOnlyTheOCRTest() throws {
        var probed = false
        XCTAssertThrowsError(try requireOCR { image in
            probed = true
            // A 12 pt line's 68 × 16 point crop at 1× backing, enlarged 3×.
            XCTAssertEqual(image.width, 204)
            XCTAssertEqual(image.height, 48)
            return []
        }) { error in
            XCTAssertTrue(error is XCTSkip)
        }
        XCTAssertTrue(probed, "Even the unavailable seam must render and probe a control")
    }

    func testCropInkDistinguishesBlankPixelsFromVisibleInk() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for background in [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1),
                           CGColor(gray: 1, alpha: 1)] {
            context.clear(CGRect(x: 0, y: 0, width: 16, height: 16))
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let blank = try cropInk(XCTUnwrap(context.makeImage()))
            XCTAssertEqual(blank.luminanceRange, 0)
            XCTAssertEqual(blank.variance, 0)
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
        let ink = try cropInk(XCTUnwrap(context.makeImage()))
        XCTAssertEqual(ink.luminanceRange, 255)
        XCTAssertGreaterThan(ink.variance, 0)
    }

    func testSubFloorCropSkipsOnlyOnGitHubActions() throws {
        for range in [0, 23, 63] {
            let crop = try contrastFixture(range: range)
            XCTAssertThrowsError(try requireReadableCrop(crop, githubActions: "true")) { error in
                XCTAssertTrue(error is XCTSkip)
            }
            for environment in [nil, "false", "1", "TRUE"] as [String?] {
                XCTAssertThrowsError(try requireReadableCrop(crop, githubActions: environment)) { error in
                    XCTAssertFalse(error is XCTSkip)
                    XCTAssertEqual((error as? CropContrastFailure)?.range, range)
                }
            }
        }
    }

    func testContrastAtOrAboveFloorStillRequiresOCRInEveryEnvironment() throws {
        for range in [64, 218, 255] {
            let crop = try contrastFixture(range: range)
            for environment in [nil, "false", "true"] as [String?] {
                XCTAssertNoThrow(try requireReadableCrop(crop, githubActions: environment))
            }
        }
    }

    func testOCRSkipStillChecksEveryRender() throws {
        var checked = 0
        XCTAssertThrowsError(try forEveryRender { _, _, _ in
            checked += 1
            throw XCTSkip("Synthetic OCR capability skip")
        }) { error in XCTAssertTrue(error is XCTSkip) }
        XCTAssertEqual(checked, 96, "A skip must preserve all screen/message/queue/appearance renders")
    }

    private func contrastFixture(range: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 1,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: CGFloat(range) / 255, green: CGFloat(range) / 255,
                             blue: CGFloat(range) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    func testOrdinaryStatusAndTerminalPreviewRemainOneLine() {
        for message in ["Copied", "Preparing speech…", "QA terminal transcript שלום 👋", PasteDeliveryFeedback.typed] {
            let label = NSHostingView(rootView:
                CompactStatusLabel(text: message, mode: .idle, confirmationText: message)
                    .frame(width: 68).fixedSize(horizontal: false, vertical: true))
            XCTAssertLessThanOrEqual(label.fittingSize.height, 15)
        }
    }

    // PASTE2: the typed-delivery confirmation renders in the pill on one line, fully visible.
    func testTypedConfirmationRendersFullyInThePillInBothAppearances() throws {
        let message = PasteDeliveryFeedback.typed
        for screenWidth in [800.0, 1728.0] {
            for light in [false, true] {
                let state = VoiceState()
                state.mode = .idle
                state.isCollapsed = false
                state.confirmationText = message
                state.sendCommand = { _ in XCTFail("Layout must send no commands") }
                let presentation = VoiceBarPresentation.notchPresentation(from: .init(
                    mode: .idle, confirmationText: message, queueDepth: 0, statusText: message
                ))
                XCTAssertEqual(presentation.visualState, .compactStatus)
                let model = VoiceBarNotchPresentationModel()
                model.updateOperationalEnvelope(
                    hasTeleprompter: false, isRecording: false, hasCompactStatus: true,
                    compactStatusLeadingWingWidth: presentation.geometry.leadingWingWidth,
                    compactStatusTrailingWingWidth: presentation.geometry.trailingWingWidth
                )
                let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation)
                let layout = VoiceBarPanelLayout.make(presentation: model.presentation, canvasGeometry: canvas.canvasGeometry)
                let screen = screenGeometry(width: screenWidth)
                XCTAssertTrue(screen.screenFrame.contains(layout.windowFrame(anchoredTo: screen)))
                let geometry = presentation.geometry
                let slot = VoiceBarNotchContract.material.wingContentLayout(for: .trailing,
                    state: .compactStatus, visibleCoreOcclusionInset: 0)
                let availableWidth = geometry.trailingWingWidth - slot.coreInset - slot.outerInset
                let font = NSFont.systemFont(ofSize: 12, weight: .medium)
                XCTAssertLessThanOrEqual(ceil((message as NSString).size(withAttributes: [.font: font]).width),
                                         availableWidth, "Typed must fit without an ellipsis")
                let label = NSHostingView(rootView:
                    CompactStatusLabel(text: message, mode: .idle, confirmationText: message)
                        .frame(width: availableWidth).fixedSize(horizontal: false, vertical: true))
                XCTAssertLessThanOrEqual(label.fittingSize.height, 15, "One line")

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
                let textX = 12 + canvas.canvasGeometry.coreOriginX + geometry.coreWidth + slot.coreInset
                let crop = try XCTUnwrap(image.cropping(to: CGRect(x: textX * scale, y: 0,
                    width: availableWidth * scale, height: 32 * scale)))
                XCTAssertGreaterThanOrEqual(try cropInk(crop).luminanceRange, 1, "The label draws visible ink")
                if VisualArtifactTestPolicy.isRegenerationEnabled() {
                    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent("docs.local/PASTE2")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appendingPathComponent(
                        "typed-\(Int(screenWidth))-\(light ? "light" : "dark").png"))
                }
            }
        }
    }

    private func forEveryRender(checksOCR: Bool = false, checkWords: (CGImage, CGRect, String) throws -> Void) throws {
        // A capability skip must not bypass later renders, geometry or readable OCR checks.
        var firstOCRSkip: XCTSkip?
        func checkOCR(_ check: () throws -> Void) throws {
            do { try check() }
            catch let skip as XCTSkip { firstOCRSkip = firstOCRSkip ?? skip }
        }
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
                        try checkOCR {
                            try checkWords(image, CGRect(x: textX * scale, y: 0,
                                width: (geometry.trailingWingWidth - slot.coreInset - slot.outerInset - cropInset) * scale,
                                height: 32 * scale), message)
                        }
                        if queueDepth > 0, checksOCR {
                            let badge = try XCTUnwrap(image.cropping(to: CGRect(
                                x: (textX - cropInset) * scale, y: 0,
                                width: (queueWidth - 4) * scale, height: 32 * scale)))
                            try reportCropInk(badge, label: "badge screen=\(screenWidth) message=\(index) light=\(light)")
                            try checkOCR {
                                try requireReadableCrop(badge)
                                try requireOCR(size: CGSize(width: badge.width, height: badge.height), scale: scale,
                                               font: roundedBadgeFont, text: "12")
                                XCTAssertEqual(try recognize(badge), ["12"], "Badge must remain visible")
                            }
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
        if let firstOCRSkip { throw firstOCRSkip }
    }

    // 210 local crops: range 218–226; the same hosted crops: 11–23 (8-bit luminance).
    nonisolated private static let ocrReadableContrastFloor = 64

    private struct CropContrastFailure: Error, CustomStringConvertible {
        let range: Int
        var description: String { "Local crop range \(range) is below OCR contrast floor \(ocrReadableContrastFloor)" }
    }

    private func requireReadableCrop(_ image: CGImage,
        githubActions: String? = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"]) throws {
        let range = try cropInk(image).luminanceRange
        guard range < Self.ocrReadableContrastFloor else { return }
        if githubActions == "true" {
            throw XCTSkip("hosted runner render contrast <\(Self.ocrReadableContrastFloor) (range \(range)): unreadable by OCR")
        }
        throw CropContrastFailure(range: range)
    }

    private struct CropInk {
        let luminanceRange: Int
        let variance: Double
        let nonzeroLuminancePixels: Int
        let nonzeroAlphaPixels: Int
    }

    private func cropInk(_ image: CGImage) throws -> CropInk {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var minimum = 255, maximum = 0, nonzeroLuminance = 0, nonzeroAlpha = 0
        var sum = 0.0, squaredSum = 0.0
        let count = image.width * image.height
        for pixel in 0..<count {
            let offset = pixel * 4
            // Premultiplied RGB measures visible ink over black, including alpha.
            let luminance = (54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1])
                             + 19 * Int(bytes[offset + 2])) / 256
            minimum = min(minimum, luminance)
            maximum = max(maximum, luminance)
            if luminance > 0 { nonzeroLuminance += 1 }
            if bytes[offset + 3] > 0 { nonzeroAlpha += 1 }
            sum += Double(luminance)
            squaredSum += Double(luminance * luminance)
        }
        let mean = sum / Double(count)
        return CropInk(luminanceRange: maximum - minimum,
                       variance: max(0, squaredSum / Double(count) - mean * mean),
                       nonzeroLuminancePixels: nonzeroLuminance, nonzeroAlphaPixels: nonzeroAlpha)
    }

    private func reportCropInk(_ image: CGImage, label: String) throws {
        let ink = try cropInk(image)
        print("P1H crop \(label) size=\(image.width)x\(image.height) range=\(ink.luminanceRange) "
              + "variance=\(ink.variance) lit=\(ink.nonzeroLuminancePixels) alpha=\(ink.nonzeroAlphaPixels)")
    }

    private func requireOCR(size: CGSize = CGSize(width: 68, height: 16), scale: CGFloat = 1,
                            font: NSFont = .systemFont(ofSize: 12, weight: .medium), text: String = "Ready",
                            read: ((CGImage) throws -> [String])? = nil) throws {
        // Render independently of the product crop: a broken/blank crop must fail,
        // not masquerade as missing OCR. Match its exact pixel dimensions, backing
        // scale and font (12 pt line or rounded 10 pt badge), then use the same OCR path.
        let control = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: control)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        let transform = NSAffineTransform()
        transform.scale(by: scale)
        transform.concat()
        let textHeight = (text as NSString).size(withAttributes: [.font: font]).height
        (text as NSString).draw(at: NSPoint(x: 2, y: (size.height / scale - textHeight) / 2), withAttributes: [
            .font: font, .foregroundColor: NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(control.cgImage)
        let forcedUnavailable = ProcessInfo.processInfo.environment["VOICEBAR_TEST_FORCE_OCR_UNAVAILABLE"] == "1"
        let reader = read ?? (forcedUnavailable ? { _ in [] } : nil)
        let result = try recognize(image, read: reader)
        try XCTSkipIf(result.isEmpty,
                      "Vision OCR unavailable for representative \(Int(size.width))×\(Int(size.height)) crop at \(scale)× backing, \(font.pointSize) pt, upscaled 3×")
        XCTAssertEqual(words(result.joined(separator: " ")), words(text))
    }

    private func recognize(_ image: CGImage, read: ((CGImage) throws -> [String])? = nil) throws -> [String] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width * 3, height: image.height * 3,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let enlarged = try XCTUnwrap(context.makeImage())
        if let read { return try read(enlarged) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: enlarged).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    func testRecoveryKeepsTheMicrophoneAndCoreAnchoredWithQueueBadge() {
        for screenWidth in [800.0, 1024.0, 1728.0] {
            let screen = screenGeometry(width: screenWidth)
            var referenceMicFrame: CGRect?
            for message in ["Copied", PasteDeliveryFeedback.typed] + messages {
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
