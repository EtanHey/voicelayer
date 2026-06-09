import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchV8VisualArtifactTests: XCTestCase {
    final class SnapshotCommandRouter: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
    }

    func testWritesV8LightAndDarkStateArtifacts() throws {
        let outputDirectory = repoRoot()
            .appendingPathComponent("docs")
            .appendingPathComponent("visual-qa")
            .appendingPathComponent("voicebar-notch-v8")
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        for scheme in [ColorScheme.light, .dark] {
            for scenario in Scenario.allCases {
                let state = scenario.state()
                let layout = VoiceBarPanelLayout.make(
                    mode: state.mode,
                    isCollapsed: state.isCollapsed,
                    previewText: VoiceBarPresentation.transcriptPreviewText(
                        mode: state.mode,
                        confirmationText: state.confirmationText,
                        commandModeState: state.commandModeState,
                        activeClipMarker: state.activeClipMarker
                    ),
                    statusText: VoiceBarPresentation.liveStatusText(
                        mode: state.mode,
                        transcript: state.transcript,
                        confirmationText: state.confirmationText,
                        hotkeyPhase: state.hotkeyPhase,
                        hotkeyEnabled: state.hotkeyEnabled,
                        errorMessage: state.errorMessage,
                        transcribingStatusText: state.transcribingStatusText,
                        commandModeState: state.commandModeState,
                        activeClipMarker: state.activeClipMarker
                    ),
                    idleAccessoryButtonCount: VoiceBarPresentation.idleAccessoryButtonCount(
                        recentTranscriptions: state.recentTranscriptions,
                        transcriptionVocabularyTerms: state.transcriptionVocabularyTerms,
                        transcriptionVocabularyAliases: state.transcriptionVocabularyAliases,
                        canReplay: state.canReplay
                    ),
                    queueItemCount: state.queueItems.count,
                    padding: Theme.panelPadding
                )

                let view = ArtifactFrame(
                    title: scenario.rawValue,
                    layout: layout,
                    content: BarView(state: state, commandRouter: SnapshotCommandRouter())
                )
                .environment(\.colorScheme, scheme)
                .frame(width: 560, height: 180)

                let renderer = ImageRenderer(content: view)
                renderer.proposedSize = ProposedViewSize(width: 560, height: 180)
                renderer.scale = 2
                guard let cgImage = renderer.cgImage else {
                    XCTFail("ImageRenderer did not produce a CGImage for \(scenario.rawValue)")
                    continue
                }

                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let data = bitmap.representation(using: .png, properties: [:]) else {
                    XCTFail("Could not encode PNG for \(scenario.rawValue)")
                    continue
                }

                let fileName = "\(scenario.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                let outputURL = outputDirectory.appendingPathComponent(fileName)
                try data.write(to: outputURL, options: .atomic)
                XCTAssertGreaterThan(data.count, 1000)
            }
        }
    }

    private enum Scenario: String, CaseIterable {
        case idleRest = "idle-rest"
        case idleHover = "idle-hover"
        case recording
        case speaking
        case terms
        case history

        @MainActor
        func state() -> VoiceState {
            let state = VoiceState(recentTranscriptionsLoader: { [] })
            state.setConnectionStatus(true)
            state.hotkeyEnabled = true
            switch self {
            case .idleRest:
                state.isCollapsed = true
            case .idleHover:
                state.isCollapsed = false
                state.setHovering(true)
            case .recording:
                state.mode = .recording
                state.audioLevel = 0.48
                state.speechDetected = true
            case .speaking:
                state.mode = .speaking
                state.statusText = "Okay, I cropped it and everything looks right."
                state.wordBoundaries = [
                    (0, 240, "Okay"),
                    (260, 180, "I"),
                    (460, 380, "cropped"),
                    (860, 180, "it"),
                ]
                state.isBlockingQuestionWaitingForUser = true
            case .terms:
                state.transcriptionVocabularyTerms = ["Domica", "VoiceLayer"]
                state.transcriptionVocabularyAliases = [
                    STTVocabularyAliasPreview(from: "domekin", to: "Domica"),
                    STTVocabularyAliasPreview(from: "claude bar", to: "ClaudeBar"),
                ]
            case .history:
                state.recentTranscriptions = ["Okay, it did - the cropping looks right."]
                state.recentHistoryItems = [
                    TranscriptionHistoryItem(
                        text: "Okay, it did - the cropping looks right.",
                        createdAt: Date(timeIntervalSinceNow: -120),
                        audioDurationMs: 8000
                    ),
                ]
            }
            return state
        }
    }

    private struct ArtifactFrame<Content: View>: View {
        var title: String
        var layout: VoiceBarPanelLayout
        var content: Content

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 0) {
                    HStack {
                        Text("Finder")
                        Text("File")
                        Text("Edit")
                        Spacer()
                        Text(title)
                        Spacer()
                        Text("14:43")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(height: 24)
                    .padding(.horizontal, 12)
                    Spacer()
                }
                content
                    .frame(width: layout.panelSize.width, height: layout.panelSize.height)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .offset(y: -1)
            }
        }
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
