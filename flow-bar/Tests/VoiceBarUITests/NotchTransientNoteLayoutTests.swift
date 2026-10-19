import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// NOTCH1: a transient note (the selection busy/rejection note) renders inside the notch. The notch grows a
/// chin under the top row, through the same shell geometry and spring the teleprompter uses, and drops it
/// when the note clears. Before this, the note was offset into the panel's shadow outset, on the wallpaper.
@MainActor
final class NotchTransientNoteLayoutTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private let notes = [
        "Busy recording. Selection not read",
        "Busy transcribing. Selection not read",
        "Busy with F5. Selection not read",
        "Busy. Selection not read",
        "Selection not read. Try again",
    ]

    private var inputs: [(String, VoiceBarNotchOperationalInput)] {
        var teleprompter = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true)
        teleprompter.statusText = "Speaking..."
        var history = VoiceBarNotchOperationalInput(mode: .idle)
        history.isHistoryPanelOpen = true
        return [
            ("recording", .init(mode: .recording)),
            ("recording + hold", .init(mode: .recording, showsRecordingHold: true)),
            ("transcribing", .init(mode: .transcribing, statusText: "Transcribing...")),
            ("F5 preview", .init(mode: .idle, hotkeyPhase: .pressing, statusText: "Hold to talk")),
            ("speaking, teleprompter hidden",
             .init(mode: .speaking, hasTeleprompterText: true, isTeleprompterDismissed: true, statusText: "Speaking...")),
            ("teleprompter", teleprompter),
            ("launcher", .init(mode: .idle)),
            ("history", history),
            ("collapsed idle", .init(mode: .idle, isCollapsed: true)),
        ]
    }

    func testTheNoteSitsInsideTheNotchAndTheTopRowNeverMoves() throws {
        for (name, input) in inputs {
            for note in notes {
                let plain = VoiceBarPresentation.notchPresentation(from: input)
                var noted = input
                noted.transientNote = note
                let presentation = VoiceBarPresentation.notchPresentation(from: noted)
                let geometry = presentation.geometry
                let label = "\(name) / \(note)"

                // The note never hides the surface: an idle (invisible) notch shows the launcher instead.
                XCTAssertNotEqual(presentation.visualState, .idle, label)
                if plain.visualState != .idle {
                    XCTAssertEqual(presentation.visualState, plain.visualState, label)
                    // No layout jump: the top row (wings around the hardware core) is identical.
                    XCTAssertEqual(geometry.topHeight, plain.geometry.topHeight, label)
                    XCTAssertEqual(geometry.leadingWingWidth, plain.geometry.leadingWingWidth, label)
                    XCTAssertEqual(geometry.trailingWingWidth, plain.geometry.trailingWingWidth, label)
                    XCTAssertEqual(
                        geometry.lowerSurfaceHeight,
                        plain.geometry.lowerSurfaceHeight + VoiceBarNotchContract.transientNoteBandHeight,
                        label
                    )
                }

                let noteRect = try XCTUnwrap(presentation.transientNoteRect, label)
                let surface = VoiceBarNotchShapeLayout(geometry: geometry)
                // Directly under the top row, inside the lower body, inside the whole notch surface.
                XCTAssertEqual(noteRect.minY, geometry.topHeight, label)
                XCTAssertTrue(surface.bodyRect.contains(noteRect), "\(label): \(noteRect) ⊄ \(surface.bodyRect)")
                XCTAssertTrue(
                    CGRect(origin: .zero, size: surface.totalSize).contains(noteRect),
                    "\(label): note outside the notch surface"
                )
                // The full sentence fits with the band's side padding, so it never truncates.
                let textWidth = Theme.intrinsicPillStatusWidth(for: note)
                XCTAssertLessThanOrEqual(
                    textWidth + 2 * VoiceBarNotchContract.transientNoteHorizontalInset,
                    noteRect.width,
                    label
                )

                // The fixed morph canvas (and so the panel) holds the grown notch.
                let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
                XCTAssertGreaterThanOrEqual(canvas.canvasGeometry.totalHeight, geometry.totalHeight, label)
                XCTAssertGreaterThanOrEqual(canvas.canvasGeometry.bodyLeadingExtent, geometry.bodyLeadingExtent, label)
                XCTAssertGreaterThanOrEqual(canvas.canvasGeometry.bodyTrailingExtent, geometry.bodyTrailingExtent, label)
                XCTAssertNil(plain.transientNoteRect, label)
            }
        }
    }

    func testTheResidentPresentationModelResolvesTheSameChin() {
        let input = VoiceBarNotchOperationalInput(mode: .recording, transientNote: notes[0])
        let resolved = VoiceBarPresentation.notchPresentation(from: input)
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false,
            recordingLeadingWingWidth: resolved.geometry.leadingWingWidth,
            recordingTrailingWingWidth: resolved.geometry.trailingWingWidth,
            transientNoteWidth: resolved.transientNoteWidth
        )
        XCTAssertEqual(model.presentation, resolved)
        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false,
            recordingLeadingWingWidth: resolved.geometry.leadingWingWidth,
            recordingTrailingWingWidth: resolved.geometry.trailingWingWidth
        )
        XCTAssertEqual(model.presentation.geometry.lowerSurfaceHeight, 0, "The chin collapses when the note clears")
    }

    func testShowingAndClearingTheNoteAsksThePanelToRelayout() {
        let state = VoiceState()
        state.mode = .recording
        let shown = expectation(description: "note shown relayout")
        shown.assertForOverFulfill = false
        state.onPanelLayoutChange = { shown.fulfill() }
        state.speakSelection()
        XCTAssertEqual(state.selectionFeedbackNote, "Busy recording. Selection not read")
        wait(for: [shown], timeout: 1)

        let cleared = expectation(description: "note cleared relayout")
        cleared.assertForOverFulfill = false
        state.onPanelLayoutChange = { if state.selectionFeedbackNote == nil { cleared.fulfill() } }
        wait(for: [cleared], timeout: 4)
    }

    /// Pixel proof against the original bug: no note ink in the shadow outset under the notch, and the note's
    /// ink lands inside its band in the black pill.
    func testTheRenderedNoteHasNoInkOutsideTheNotch() throws {
        let state = VoiceState()
        state.mode = .recording
        state.sendCommand = { _ in }
        state.speakSelection()
        let note = try XCTUnwrap(state.selectionFeedbackNote)
        let presentation = VoiceBarPresentation.notchPresentation(
            from: .init(mode: .recording, transientNote: note)
        )
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false,
            recordingLeadingWingWidth: presentation.geometry.leadingWingWidth,
            recordingTrailingWingWidth: presentation.geometry.trailingWingWidth,
            transientNoteWidth: presentation.transientNoteWidth
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation)
        let size = CGSize(width: canvas.canvasGeometry.totalWidth + 24, height: canvas.canvasGeometry.totalHeight + 17)
        let host = NSHostingView(rootView:
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, .dark)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let scale = CGFloat(image.height) / size.height

        let outset = CGRect(x: 0, y: canvas.canvasGeometry.totalHeight, width: size.width, height: 17)
        XCTAssertLessThan(try maxLuminance(image, in: outset, scale: scale), 90,
                          "Note text must not paint in the outset below the notch")
        let noteRect = try XCTUnwrap(model.presentation.transientNoteRect)
        let band = noteRect.offsetBy(dx: 12 + canvas.contentOffsetX, dy: 0)
        let bandLuminance = try maxLuminance(image, in: band, scale: scale)
        // Same policy as PasteFeedbackLayoutTests: GitHub's hosted runners draw text over the notch glass
        // at a luminance range of ~11, so only there a dim band skips; the outset check above still ran.
        if bandLuminance <= 160, ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" {
            throw XCTSkip("hosted runner render: band luminance \(bandLuminance) is unreadable")
        }
        XCTAssertGreaterThan(bandLuminance, 160, "The note's text must render inside its band")

        if VisualArtifactTestPolicy.isRegenerationEnabled() {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs.local/NOTCH1")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("after-recording-busy-note.png"))
        }
    }

    /// `rect` is in top-left points; CGImage rows also start at the top.
    private func maxLuminance(_ image: CGImage, in rect: CGRect, scale: CGFloat) throws -> Int {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let crop = try XCTUnwrap(image.cropping(to: pixels))
        let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
            bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var maximum = 0
        for pixel in 0 ..< crop.width * crop.height {
            let offset = pixel * 4
            maximum = max(maximum, (54 * Int(bytes[offset]) + 183 * Int(bytes[offset + 1])
                + 19 * Int(bytes[offset + 2])) / 256)
        }
        return maximum
    }
}
