import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import Vision
import XCTest

/// c7 lane S (Etan QA 2026-11-11 on candidate 6, shots 1, 2 and 5): reads what the drawer really paints at his
/// 420 pt width. Both tests fail on candidate source 8e1d5352.
@MainActor
final class SettingsDrawerLaneSLayoutTests: XCTestCase {
    struct Word { let text: String; let box: CGRect }

    /// OCR lines with their boxes in points, origin top-left.
    static func paintedLines(_ view: some View, height: CGFloat) throws -> [Word] {
        let bitmap = try SettingsDrawerLaneSSnapshotTests.render(view, height: height, name: "ocr-scratch")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let size = CGSize(width: SettingsDrawerLaneSSnapshotTests.drawerWidth, height: height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Word(text: text.lowercased(), box: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                                             width: box.width * size.width, height: box.height * size.height))
        }
    }

    static func line(_ lines: [Word], containing text: String) throws -> Word {
        try XCTUnwrap(lines.first { $0.text.contains(text) }, "OCR did not read '\(text)': \(lines.map(\.text))")
    }

    /// Shots 1-2: "Used for dictation" sat on a third line under "Connected" (beside an invisible Make default).
    /// It now shares the status line, so the row is two lines tall like its neighbours.
    func testTheInUseMicShowsItsPillOnTheStatusLineNotUnderIt() async throws {
        let updates = await SettingsDrawerLaneSSnapshotTests.updates()
        let lines = try Self.paintedLines(SettingsDrawerLaneSSnapshotTests.drawer(.general, updates: updates), height: 470)
        let title = try Self.line(lines, containing: "macbook pro microphone")
        let pill = try Self.line(lines, containing: "used for dictation")
        let nextTitle = try Self.line(lines, containing: "airpods")
        // OCR may read "Connected Used for dictation" as one line; either way its centre is the status line's.
        let statusLineY = title.box.maxY + 4
        XCTAssertLessThan(abs(pill.box.midY - (statusLineY + pill.box.height / 2)), 6,
                          "[S1] the pill must sit on the status line right under the name: title \(title.box), pill \(pill.box)")
        let usb = try Self.line(lines, containing: "usb audio device")
        let rowPitchUsed = nextTitle.box.minY - title.box.minY
        let rowPitchPlain = usb.box.minY - nextTitle.box.minY
        XCTAssertLessThan(abs(rowPitchUsed - rowPitchPlain), 3,
                          "[S1] the in-use row is as tall as a plain two-line row (\(rowPitchUsed) vs \(rowPitchPlain))")
    }

    /// Shot 5: "Unavailable with Parakeet." led the Smart chunks description. At rest the row now paints only what it
    /// does; the reason shows when the switch is hovered (SettingsDrawerLaneSSnapshotTests renders that state).
    func testSmartChunksNeverPaintsItsLockReasonInItsText() throws {
        let lines = try Self.paintedLines(SettingsDrawerLaneSSnapshotTests.drawer(.transcription, updates: nil), height: 1100)
        _ = try Self.line(lines, containing: "smart chunks")
        _ = try Self.line(lines, containing: "splits long")
        XCTAssertFalse(lines.contains { $0.text.contains("unavailable with parakeet") },
                       "[S4] the lock reason is painted in the row: \(lines.map(\.text))")
    }
}
