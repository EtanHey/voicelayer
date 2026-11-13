import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// C7 L3 before/after diagrams for V09 and V10 (opt-in: VOICEBAR_L3_SHOTS_DIR). Synthetic, from the real models; the
/// M1 cannot render the glass material, so V10 draws the shell's own shape as a flat fill standing in for it.
@MainActor
final class ReadingSeekMaterialShotsL3Tests: XCTestCase {
    func testWriteBeforeAfterShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_L3_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_L3_SHOTS_DIR to write the C7 L3 V09/V10 diagrams")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeV09(directory)
        try writeV10(directory)
    }

    // MARK: V09: which words can be clicked while the read is still synthesizing

    private func writeV09(_ directory: URL) throws {
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(TeleprompterSeekTargetsL3Tests.payload.utf8)) as? [String: Any])
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
                               recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        state.isConnected = true
        state.sendCommand = { _ in }
        state.handleEvent(["type": "state", "state": "speaking", "text": fixture["text"] as Any, "duration_ms": 39_000,
                           "playback_id": "v09", "generation": 1, "utteranceId": "u-v09",
                           "long_read": ["id": "u-v09", "chunk_index": 0, "chunk_count": 1, "chunk_start_ms": 0,
                                         "display": fixture["display"] as Any]])
        var words = try XCTUnwrap(fixture["words"] as? [String: Any])
        words["words"] = Array(try XCTUnwrap(words["words"] as? [[String: Any]]).prefix(25)) // first chunk timed
        state.handleEvent(words)
        let model = TeleprompterAModelCache().model(text: try XCTUnwrap(state.teleprompterText),
            boundaries: state.teleprompterWordBoundaries, blocks: state.teleprompterDisplayBlocks,
            complete: state.teleprompterHasCompleteDisplay, column: TeleprompterA.columnWidth)
        let table = try XCTUnwrap(state.speechWords)
        // Candidate rule (8e1d5352): only a word the daemon already timed, with the same text, is a target.
        let candidate: (Int) -> Bool = { word in
            guard let token = model.tokenOfWord?[word] else { return false }
            return table.isTimed(token) && table.words[token]?.text == model.tokens[token]
        }
        let branch: (Int) -> Bool = { model.seekTarget(for: $0, table: table) != nil }
        for (name, rule, title) in [("before-V09-seek-targets", candidate, "Candidate: words ahead of the timed chunk are dead"),
                                    ("after-V09-seek-targets", branch, "This branch: every word of the read is a target")] {
            try render(V09Diagram(model: model, isTarget: rule, title: title), size: CGSize(width: 520, height: 300),
                       to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private struct V09Diagram: View {
        let model: TeleprompterAModel
        let isTarget: (Int) -> Bool
        let title: String
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Green: clicking seeks. Red: a click does nothing. First chunk (25 words) timed, as at 0:03.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 4) {
                        ForEach(Array(line), id: \.self) { word in
                            Text(model.layouts[word].displayText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 2)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(isTarget(word) ? Color.green.opacity(0.45) : Color.red.opacity(0.6)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 520, height: 300, alignment: .topLeading)
            .background(Color(white: 0.12))
        }
    }

    // MARK: V10: a mid-collapse shell frame inside the canvas it is drawn in

    private func writeV10(_ directory: URL) throws {
        func presentation(dismissed: Bool) -> VoiceBarNotchPresentation {
            var input = VoiceBarNotchOperationalInput(
                mode: .speaking, hasTeleprompterText: true, isTeleprompterDismissed: dismissed,
                readQueueLeadingSlotCount: 4, isCollapsed: false)
            input.teleprompterLines = 8 // as in Etan's recording
            return VoiceBarPresentation.notchPresentation(from: input)
        }
        let open = presentation(dismissed: false), hidden = presentation(dismissed: true)
        let branchCanvas = VoiceBarNotchMorphCanvasLayout.resolve(for: hidden).canvasGeometry.totalHeight
        // Candidate (8e1d5352): a compact state's canvas held only its own body plus the note reserve (258 pt).
        let candidateCanvas = hidden.geometry.totalHeight - hidden.feedbackHeight + VoiceBarNotchContract.transientNoteCanvasReserve
        // 10 % into the collapse (probe frames 0-3 are cut on the candidate): the shell is still nearly full height.
        let mid = VoiceBarNotchGeometry(coreWidth: open.geometry.coreWidth, topHeight: open.geometry.topHeight,
            leadingWingWidth: open.geometry.leadingWingWidth, trailingWingWidth: open.geometry.trailingWingWidth,
            bodyLeadingExtent: open.geometry.bodyLeadingExtent, bodyTrailingExtent: open.geometry.bodyTrailingExtent,
            lowerSurfaceHeight: open.geometry.lowerSurfaceHeight * 0.9)
        for (name, canvas, title) in [("before-V10-collapse-frame", candidateCanvas, "Candidate: canvas shrinks at once; the shell is cut flat"),
                                      ("after-V10-collapse-frame", branchCanvas, "This branch: the read keeps its canvas; corners stay round")] {
            try render(V10Diagram(geometry: mid, canvasHeight: canvas, fullHeight: open.geometry.totalHeight, title: title),
                       size: CGSize(width: mid.totalWidth + 40, height: open.geometry.totalHeight + 90),
                       to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private struct V10Diagram: View {
        let geometry: VoiceBarNotchGeometry
        let canvasHeight: CGFloat
        let fullHeight: CGFloat
        let title: String
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("Frame 10% into an 8-line teleprompter → hidden. Gray = the shell's shape (glass stand-in: the M1 cannot render glass). Dashed = the canvas/window bottom.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                ZStack(alignment: .topLeading) {
                    VoiceBarNotchContinuousShape(geometry: geometry, compactOuterCornerRadius: 18)
                        .fill(Color(white: 0.55))
                        .frame(width: geometry.totalWidth, height: geometry.totalHeight, alignment: .topLeading)
                        .frame(width: geometry.totalWidth, height: min(canvasHeight, fullHeight), alignment: .topLeading)
                        .clipped()
                    Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.orange)
                        .frame(width: geometry.totalWidth, height: min(canvasHeight, fullHeight))
                }
                .frame(width: geometry.totalWidth, height: fullHeight, alignment: .topLeading)
            }
            .padding(14)
            .background(Color(white: 0.12))
        }
    }

    private func render(_ view: some View, size: CGSize, to url: URL) throws {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(white: 0.12)))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}
