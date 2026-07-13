import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class TeleprompterSecondWaveArtifactTests: XCTestCase {
    final class ArtifactCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private let pillSize = CGSize(width: Theme.panelWidth, height: Theme.teleprompterViewportHeight + 8)

    func testWritesSecondWaveTeleprompterArtifacts() async throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs.local")
            .appendingPathComponent("ux-second-wave-teleprompter")
            .appendingPathComponent("after")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        try await writeEscapeTransitionArtifact(to: outputDirectory)
        try await writeUnhideResumeArtifact(to: outputDirectory)
        try await writeFreshBriefArtifact(to: outputDirectory)
        try writeBottomClampArtifact(to: outputDirectory)
        try writeTrailingControlsArtifact(to: outputDirectory)
    }

    private func writeEscapeTransitionArtifact(to directory: URL) async throws {
        let state = speakingState(
            text: "Outgoing teleprompter words must be gone before the idle controls appear"
        )
        let host = pillHost(state: state)
        try await settle(for: .milliseconds(350), host: host)

        state.mode = .idle
        state.statusText = ""
        try await settle(for: .milliseconds(50), host: host)
        try writePNG(host, named: "SPEC-1-speaking-to-idle-at-50ms.png", in: directory)
    }

    private func writeUnhideResumeArtifact(to directory: URL) async throws {
        let text = "zero one two three four five six seven eight nine"
        let state = speakingState(text: text, boundaryStepMs: 200)
        let host = pillHost(state: state)
        try await settle(for: .milliseconds(850), host: host)

        state.dismissTeleprompter()
        try await settle(for: .milliseconds(600), host: host)
        state.showTeleprompter()
        try await settle(for: .milliseconds(50), host: host)
        try writePNG(host, named: "SPEC-2-unhide-resumes-current-word.png", in: directory)
    }

    private func writeFreshBriefArtifact(to directory: URL) async throws {
        let firstText = "old zero old one old two old three old four old five old six old seven old eight old nine"
        let state = speakingState(text: firstText, boundaryStepMs: 100)
        let host = pillHost(state: state)
        try await settle(for: .milliseconds(1250), host: host)

        let replacement = "NEW START appears before any middle replacement words can flash inside the teleprompter viewport"
        state.statusText = replacement
        state.wordBoundaries = boundaries(for: replacement, stepMs: 180)
        try await settle(for: .milliseconds(20), host: host)
        try writePNG(host, named: "SPEC-3-new-brief-first-paint.png", in: directory)
    }

    private func writeBottomClampArtifact(to directory: URL) throws {
        let canvasSize = CGSize(width: 500, height: 180)
        let state = speakingState(
            text: "All four teleprompter lines remain inside the bottom edge of the visible screen"
        )
        let plan = PillResizePlan.makeAnchored(
            visibleFrame: CGRect(origin: .zero, size: canvasSize),
            horizontalOffset: 0.5,
            verticalOffset: 0,
            topPadding: Theme.topPadding,
            pillSize: pillSize,
            from: .idle,
            to: .speaking,
            padding: 0
        )
        let swiftUIY = canvasSize.height - plan.frame.midY
        let artifact = ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle()
                .fill(Color.red.opacity(0.8))
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
            BarView(state: state, commandRouter: ArtifactCommandRouter())
                .frame(width: pillSize.width, height: pillSize.height)
                .position(x: plan.frame.midX, y: swiftUIY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)

        try writePNG(
            NSHostingView(rootView: AnyView(artifact)),
            size: canvasSize,
            named: "SPEC-4a-bottom-edge-clamped.png",
            in: directory
        )
    }

    private func writeTrailingControlsArtifact(to directory: URL) throws {
        let state = speakingState(
            text: "Both speaking controls fit fully inside the rounded trailing edge"
        )
        try writePNG(
            pillHost(state: state),
            named: "SPEC-4b-trailing-controls-inset.png",
            in: directory
        )
    }

    private func speakingState(
        text: String,
        boundaryStepMs: Int = 220
    ) -> VoiceState {
        let state = VoiceState()
        state.mode = .speaking
        state.isConnected = true
        state.hotkeyEnabled = true
        state.isCollapsed = false
        state.statusText = text
        state.wordBoundaries = boundaries(for: text, stepMs: boundaryStepMs)
        return state
    }

    private func boundaries(
        for text: String,
        stepMs: Int
    ) -> [(offsetMs: Int, durationMs: Int, text: String)] {
        text.split(whereSeparator: { $0.isWhitespace }).enumerated().map { index, word in
            (index * stepMs, max(80, stepMs - 20), String(word))
        }
    }

    private func pillHost(state: VoiceState) -> NSHostingView<AnyView> {
        let host = NSHostingView(
            rootView: AnyView(
                BarView(state: state, commandRouter: ArtifactCommandRouter())
                    .frame(width: pillSize.width, height: pillSize.height)
            )
        )
        host.frame = NSRect(origin: .zero, size: pillSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func settle(
        for duration: Duration,
        host: NSHostingView<AnyView>
    ) async throws {
        try await Task.sleep(for: duration)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func writePNG(
        _ host: NSHostingView<AnyView>,
        named name: String,
        in directory: URL
    ) throws {
        try writePNG(host, size: host.frame.size, named: name, in: directory)
    }

    private func writePNG(
        _ host: NSHostingView<some View>,
        size: CGSize,
        named name: String,
        in directory: URL
    ) throws {
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not create bitmap for \(name)")
            return
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode PNG for \(name)")
            return
        }

        let outputURL = directory.appendingPathComponent(name)
        try data.write(to: outputURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(
            try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int ?? 0,
            0
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
