import AppKit
import Darwin
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Look receipts for the booting -> live capture transition. Skipped unless
/// VOICEBAR_REGENERATE_VISUAL_ARTIFACTS=1, and writes into gitignored
/// docs.local, matching the other visual-artifact tests.
@MainActor
final class CaptureBootingArtifactTests: XCTestCase {
    private final class NoOpCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath: String) {}
    }

    func testWritesBootingAndLiveCaptureArtifacts() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("design")
            .appendingPathComponent("2026-09-06-capture-booting-pill")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let booting = VoiceState()
        booting.setConnectionStatus(true)
        booting.sendCommand = { _ in }
        booting.isCollapsed = false
        booting.record(pressToTalk: true)
        XCTAssertFalse(booting.captureLive)
        try writeNotchPNG(
            state: booting,
            to: outputDirectory.appendingPathComponent("1-booting.png")
        )

        // The same press, one frame after the recorder handed over audio.
        booting.handleEvent(["type": "audio_level", "rms": 0.75])
        booting.handleEvent(["type": "speech", "detected": true])
        XCTAssertTrue(booting.captureLive)
        try writeNotchPNG(
            state: booting,
            to: outputDirectory.appendingPathComponent("2-live.png")
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func writeNotchPNG(state: VoiceState, to outputURL: URL) throws {
        let presentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: state.mode == .recording,
            hasCompactStatus: false,
            isHovered: false,
            isKeyboardFocused: false
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: presentation)
        let layout = VoiceBarPanelLayout.make(
            presentation: presentation,
            canvasGeometry: canvas.canvasGeometry
        )
        let host = NSHostingView(
            rootView: BarView(
                state: state,
                commandRouter: NoOpCommandRouter(),
                includesPanelOutsets: true
            )
        )
        host.frame = CGRect(origin: .zero, size: layout.panelSize)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        guard let cgImage = captureWindowImage(windowNumber: window.windowNumber) else {
            throw NSError(domain: "CaptureBootingArtifactTests", code: 1)
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CaptureBootingArtifactTests", code: 2)
        }
        try data.write(to: outputURL, options: .atomic)
    }

    private func captureWindowImage(windowNumber: Int) -> CGImage? {
        typealias CaptureFunction = @convention(c) (
            CGRect,
            UInt32,
            UInt32,
            UInt32
        ) -> Unmanaged<CGImage>?
        guard let defaultLookup = UnsafeMutableRawPointer(bitPattern: -2),
              let symbol = dlsym(defaultLookup, "CGWindowListCreateImage") else {
            return nil
        }
        let capture = unsafeBitCast(symbol, to: CaptureFunction.self)
        return capture(.null, 1 << 3, UInt32(windowNumber), 1 << 0)?.takeRetainedValue()
    }
}
