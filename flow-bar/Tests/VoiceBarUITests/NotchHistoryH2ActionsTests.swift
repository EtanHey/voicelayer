import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchHistoryH2ActionsTests: XCTestCase {
    private func ask(_ text: String) -> NotchHistoryArchiveStore.Row {
        NotchHistoryArchiveStore.row(SettingsAskHistoryEntry(
            id: "synthetic-ask", dayKey: "2026-11-11", askID: "synthetic-ask",
            createdAt: Date(timeIntervalSince1970: 1_794_400_000), questionText: "Synthetic question?",
            questionAudioPath: nil, responseTranscript: text, responseAudioPath: nil))
    }

    private func speech(_ text: String) -> NotchHistoryArchiveStore.Row {
        NotchHistoryArchiveStore.row(SettingsSpeechHistoryEntry(
            id: "synthetic-speech", createdAt: Date(timeIntervalSince1970: 1_794_400_000),
            originalText: text, spokenText: text, voice: "Synthetic voice", status: "completed",
            reason: nil, durationMs: 13000, missingAudioCount: 0, audioPaths: []))
    }

    private func panel(_ row: NotchHistoryArchiveStore.Row, scope: SettingsHistoryScope) -> NotchHistoryPanel {
        NotchHistoryPanel(entries: [row.entry], activeRetranscriptionPath: nil,
            palette: .resolve(for: .dark), onCopy: { _ in true }, onPaste: { _ in }, onRetranscribe: { _ in },
            listHeight: 92, scope: scope, rowHasActionableText: { _ in row.hasActionableText }, forcedHoverIndex: 0)
    }

    func testSpeechHasCopyButNeverPasteAndAskRetainsPaste() {
        let spoken = speech("Synthetic speech text.")
        XCTAssertEqual(panel(spoken, scope: .speech).actions(for: spoken.entry, index: 0).map(\.kind), [.copy])
        let answered = ask("Synthetic answer.")
        XCTAssertEqual(panel(answered, scope: .ask).actions(for: answered.entry, index: 0).map(\.kind), [.copy, .paste])
    }

    func testPlaceholderAndWhitespaceRowsHaveNoActions() {
        for (scope, row) in [(SettingsHistoryScope.ask, ask("")), (.ask, ask("  \n")), (.speech, speech("")), (.speech, speech("  \n"))] {
            XCTAssertFalse(row.hasActionableText, "placeholder prose is display only")
            XCTAssertTrue(panel(row, scope: scope).actions(for: row.entry, index: 0).isEmpty)
        }
    }

    func testSpeechCopiesAllWordsBeyondItsPreview() {
        let text = String(repeating: "Synthetic complete speech. ", count: 20)
        XCTAssertEqual(speech(text).entry.text, text, "copy must not truncate at the archive preview limit")
    }

    func testWriteActionShotsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_H2_SHOTS_DIR"] else {
            throw XCTSkip("Set VOICEBAR_H2_SHOTS_DIR for H2 action pictures")
        }
        let prefix = ProcessInfo.processInfo.environment["VOICEBAR_H2_SHOTS_PREFIX"] ?? "after"
        for (name, scope, row) in [("speech-actions", SettingsHistoryScope.speech, speech("Synthetic speech text.")),
                                  ("ask-placeholder", .ask, ask("")), ("speech-placeholder", .speech, speech(""))] {
            let root = VStack(spacing: 8) {
                Text(scope.title).font(.headline)
                panel(row, scope: scope)
                Text("M1 offscreen, synthetic. Glass unavailable: solid backdrop.").font(.system(size: 9))
            }.padding(8).frame(width: 420, height: 160).background(Color(white: 0.1)).foregroundStyle(.white)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("\(prefix)-\(name).png"))
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
    }
}
