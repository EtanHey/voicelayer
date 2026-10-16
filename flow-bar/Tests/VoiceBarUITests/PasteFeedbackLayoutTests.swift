import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision
@testable import VoiceBarUI
import XCTest

@MainActor
final class PasteFeedbackLayoutTests: XCTestCase {
    private let messages = [
        PasteRecoveryFeedback.notInserted,
        PasteRecoveryFeedback.unverified,
        "Part pasted\nHistory: full",
    ]

    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    func testEveryRecoveryMessageIsFullyRenderedInBothAppearances() throws {
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
                        XCTAssertEqual(model.presentation.geometry, presentation.geometry,
                                       "The resident presentation model must preserve the feedback width")
                        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation)
                        let screen = screenGeometry(width: screenWidth)
                        let layout = VoiceBarPanelLayout.make(presentation: model.presentation, canvasGeometry: canvas.canvasGeometry)
                        XCTAssertTrue(screen.screenFrame.contains(layout.windowFrame(anchoredTo: screen)))
                        XCTAssertLessThanOrEqual(model.presentation.geometry.trailingWingWidth,
                                                 VoiceBarNotchContract.morphCanvasWingCapacity)
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
                        // Vision merges these closely spaced 12 pt lines when given the whole
                        // notch. Read each visible half of the 32 pt wing independently.
                        let image = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
                        let scale = CGFloat(image.height) / size.height
                        let queueWidth = queueDepth > 0 ? Theme.intrinsicPillStatusWidth(for: "\(queueDepth)") + 16 : 0
                        // The lane budgets the badge at 12 pt, while its rounded glyphs
                        // render at 10 pt. Keep slack so the crop never clips the text.
                        let cropInset = max(0, queueWidth - 4)
                        let textX = 12 + canvas.canvasGeometry.coreOriginX + presentation.geometry.coreWidth
                            + WaveformLayout.coreGap + cropInset
                        let visible = try [0, 1].map { line in
                            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: textX * scale,
                                y: CGFloat(line) * 16 * scale,
                                width: (presentation.geometry.trailingWingWidth - 32 - cropInset) * scale,
                                height: 16 * scale)))
                            let request = VNRecognizeTextRequest()
                            request.recognitionLevel = .accurate
                            request.usesLanguageCorrection = false
                            try VNImageRequestHandler(cgImage: crop).perform([request])
                            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                                .joined(separator: " ")
                        }.joined(separator: " ")
                        XCTAssertEqual(words(visible), words(message), "Full feedback must be visible: \(visible)")
                        XCTAssertFalse(visible.contains("…") || visible.contains("..."), "No ellipsis in feedback")
                        if queueDepth > 0 {
                            let badge = try XCTUnwrap(image.cropping(to: CGRect(
                                x: (textX - cropInset) * scale, y: 0,
                                width: (queueWidth - 4) * scale, height: 32 * scale)))
                            let request = VNRecognizeTextRequest()
                            request.recognitionLevel = .accurate
                            try VNImageRequestHandler(cgImage: badge).perform([request])
                            XCTAssertEqual((request.results ?? []).compactMap { $0.topCandidates(1).first?.string },
                                           ["12"], "The feedback must not squeeze out the queue badge")
                        }
                        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                            .appendingPathComponent("docs.local/P1E")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try png.write(to: directory.appendingPathComponent(
                            "r2-feedback-\(Int(screenWidth))-\(index)-queue\(queueDepth)-\(light ? "light" : "dark").png"))
                        let geometry = presentation.geometry
                        let slot = VoiceBarNotchContract.material.wingContentLayout(for: .trailing,
                            state: .compactStatus, visibleCoreOcclusionInset: 0)
                        let width = geometry.trailingWingWidth - slot.coreInset - slot.outerInset
                            - queueWidth
                        let required = (message as NSString).boundingRect(
                            with: CGSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
                        )
                        XCTAssertLessThanOrEqual(ceil(required.height), geometry.topHeight,
                                                 "Full feedback must fit the wing vertically")
                        XCTAssertLessThanOrEqual(geometry.topOriginX + geometry.topWidth,
                                                 canvas.canvasGeometry.totalWidth - canvas.contentOffsetX)
                        XCTAssertEqual(geometry.leadingWingWidth, VoiceBarNotchContract.compactIndicatorLaneWidth)
                        XCTAssertEqual(geometry.topHeight, 32)
                    }
                }
            }
        }
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
                    XCTAssertTrue(screen.screenFrame.contains(frame), "Panel must stay on a \(screenWidth) pt display")
                    XCTAssertLessThanOrEqual(geometry.trailingWingWidth,
                        VoiceBarNotchContract.morphCanvasWingCapacity, "Never grow into menu-bar space")
                    XCTAssertEqual(canvas.canvasGeometry.totalWidth, 465, "Keep the ordinary canvas")
                }
            }
        }
    }

    private func screenGeometry(width: CGFloat) -> VoiceBarNotchScreenGeometry {
        VoiceBarNotchScreenGeometry.resolve(metrics: .init(
            frame: CGRect(x: 0, y: 0, width: width, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: 1085), safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: width / 2 - 92.5, height: 32),
            auxiliaryTopRightArea: CGRect(x: width / 2 + 92.5, y: 1085,
                                         width: width / 2 - 92.5, height: 32)
        ))
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
