import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U4 add-on visual receipt (opt-in, `VOICEBAR_U4_SHOTS_DIR`): the open Recording details with its close button,
/// twenty identical Re-transcribe requests folded into one row (closed and opened), light and dark. Synthetic only.
@MainActor
final class SettingsHistoryDetailsShotsTests: XCTestCase {
    func testWriteRecordingDetailsShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_U4_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set VOICEBAR_U4_SHOTS_DIR to write the U4 Recording details shots")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = Date(timeIntervalSince1970: 1_793_000_000)
        var log = SettingsHistoryRunLog()
        let audio = "/synthetic/2026-11-05/take/audio.wav"
        for index in 0 ..< 20 {
            log.begin(id: "r\(index)", path: audio, at: created.addingTimeInterval(Double(60 + index * 9)),
                      priorText: "Synthetic words")
            log.observe(["type": "transcription", "recording_path": audio, "text": "Synthetic words"])
        }
        let snapshot = SettingsHistoryDiagnostics(
            archiveState: .transcribed, savedTextState: .present, selection: audio, summary: "Synthetic",
            savedResult: "Synthetic", capturedAt: created, backend: "parakeet-resident", model: nil, detail: nil,
            warnings: [], languageSetting: "English", inputDeviceName: "Synthetic mic", transcriptWrittenAt: nil
        )
        for (name, opened) in [("folded", false), ("folded-open", true)] {
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let size = CGSize(width: 552, height: opened ? 1000 : 260)
                let panel = SettingsHistoryDiagnosticsPanel(
                    snapshot: snapshot, runs: log.runs, initiallyExpanded: true, recordingID: "2026-11-05T01-44-00-000Z-synthetic"
                ).openingRepeatsForShots(opened ? ["requests-r0"] : [])
                    .frame(width: 520).padding(16)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: panel)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("details-\(name)-\(scheme).png"))
                window.contentView = nil
            }
        }
    }
}
