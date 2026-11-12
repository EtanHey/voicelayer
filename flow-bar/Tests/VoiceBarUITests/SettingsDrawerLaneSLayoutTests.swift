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
        var audit: [SettingsTextAuditEntry] = []
        let view = SettingsDrawerLaneSSnapshotTests.drawer(.general, updates: updates)
            .onPreferenceChange(SettingsTextAuditKey.self) { audit = $0 }
        let lines = try Self.paintedLines(view, height: 470)
        let usedFrame = try XCTUnwrap(audit.first { $0.text == "MacBook Pro Microphone" }).frame
        let nextFrame = try XCTUnwrap(audit.first { $0.text == "Master iPhone’s AirPods Pro #2" }).frame
        let usbFrame = try XCTUnwrap(audit.first { $0.text == "USB Audio Device" }).frame
        let usedPitch = nextFrame.minY - usedFrame.minY
        let plainPitch = usbFrame.minY - nextFrame.minY
        print("Mic title-frame pitch: used=\(usedPitch) plain=\(plainPitch)")
        // Measure row pitch from equal-font layout frames. OCR ink tops differ between capital letters and
        // punctuation (the AirPods label alone adds a 3 pt bias); the 3 pt row-spacing limit stays unchanged.
        XCTAssertLessThan(abs(usedPitch - plainPitch), 3,
                          "[S1] in-use and plain rows share their two-line pitch (\(usedPitch) vs \(plainPitch))")
        let title = try Self.line(lines, containing: "macbook pro microphone")
        let pill = try Self.line(lines, containing: "used for dictation")
        // OCR may read "Connected Used for dictation" as one line; either way its centre is the status line's.
        let statusLineY = title.box.maxY + 4
        XCTAssertLessThan(abs(pill.box.midY - (statusLineY + pill.box.height / 2)), 6,
                          "[S1] the pill must sit on the status line right under the name: title \(title.box), pill \(pill.box)")
    }

    /// Shot 5: "Unavailable with Parakeet." led the Smart chunks description. At rest the row now paints only what it
    /// does; the reason shows when the switch is hovered (SettingsDrawerLaneSSnapshotTests renders that state).
    func testSmartChunksNeverPaintsItsLockReasonInItsText() throws {
        let lines = try Self.paintedLines(SettingsDrawerLaneSSnapshotTests.drawer(.transcription, updates: nil), height: 1100)
        _ = try Self.line(lines, containing: "smart chunks")
        _ = try Self.line(lines, containing: "splits long")
        XCTAssertFalse(lines.contains { $0.text.contains("unavailable with parakeet") },
                       "[S4] the lock reason is painted in the row: \(lines.map(\.text))")
        // Lead review (c7 07:55Z): with the Experimental badge on the title line the description uses the full text
        // column instead of wrapping beside a reserved badge.
        XCTAssertTrue(lines.contains { $0.text.contains("splits long whisper recordings at pauses") },
                      "[S4] the description wraps in a narrow column: \(lines.map(\.text))")
    }

    /// The first x (pt) on a pixel row where the drawer's paint differs from its backdrop.
    static func firstPaintedX(_ bitmap: NSBitmapImageRep, atY y: CGFloat) -> CGFloat? {
        let scale = CGFloat(bitmap.pixelsWide) / SettingsDrawerLaneSSnapshotTests.drawerWidth
        let row = Int(y * scale)
        guard let backdrop = bitmap.colorAt(x: 1, y: row) else { return nil }
        for x in 2 ..< bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: row) else { continue }
            if abs(color.redComponent - backdrop.redComponent) > 0.015 { return CGFloat(x) / scale }
        }
        return nil
    }

    /// Item 3 ("the gutters on the sides are still huge"): a section card's left edge is the tab bar's left edge
    /// (8 pt), in every grouped-Form tab. On 8e1d5352 the cards started 28 pt in.
    func testSectionCardsLineUpWithTheTabBarEdges() async throws {
        let updates = await SettingsDrawerLaneSSnapshotTests.updates()
        for tab in [SettingsTab.general, .transcription] {
            let view = SettingsDrawerLaneSSnapshotTests.drawer(tab, updates: tab == .general ? updates : nil)
            let bitmap = try SettingsDrawerLaneSSnapshotTests.render(view, height: 470, name: "gutter-scratch")
            let lines = try Self.paintedLines(view, height: 470)
            let anchor = try Self.line(lines, containing: tab == .general ? "wireless mic" : "parakeet")
            let cardEdge = try XCTUnwrap(Self.firstPaintedX(bitmap, atY: anchor.box.midY))
            // The tab bar spans the drawer minus its inset; its selected-tab fill starts there (General shows it).
            let tabEdge = NotchSettingsDrawerPresentation.horizontalInset
            if tab == .general {
                XCTAssertEqual(try XCTUnwrap(Self.firstPaintedX(bitmap, atY: 20)), tabEdge, accuracy: 1,
                               "fixture: the selected General tab's fill marks the tab bar's left edge")
            }
            XCTAssertEqual(cardEdge, tabEdge, accuracy: 1.5,
                           "[S3] \(tab.title): card starts at \(cardEdge) pt, the tab bar at \(tabEdge) pt")
        }
    }

    /// Item 2 (shot 3, "still very jumbled"): each shortcut's description starts on its title's left edge, under it,
    /// not right-aligned beside it; the shortcuts are their own section, not a bare "Gestures" line in Advanced.
    func testGeneralShortcutsUseOneLeftAlignedRowAnatomy() async throws {
        let updates = await SettingsDrawerLaneSSnapshotTests.updates()
        let lines = try Self.paintedLines(SettingsDrawerLaneSSnapshotTests.drawer(.general, advanced: true, updates: updates),
                                          height: 1500)
        XCTAssertFalse(lines.contains { $0.text == "gestures" }, "[S2] the bare Gestures line is gone")
        _ = try Self.line(lines, containing: "shortcuts")
        let title = try Self.line(lines, containing: "shift+f5")
        let description = try Self.line(lines, containing: "re-paste last transcript")
        XCTAssertEqual(description.box.minX, title.box.minX, accuracy: 2,
                       "[S2] description starts under its title: \(description.box) vs \(title.box)")
        XCTAssertGreaterThan(description.box.minY, title.box.minY, "[S2] and below it")
    }

    /// Item 5 (footer "cramped"): the update status runs on one line under the build line, from the same left edge
    /// as "VoiceBar", instead of two short lines squeezed beside Check for updates.
    func testTheVersionFooterStatusIsOneLineOnTheTitleEdge() async throws {
        let updates = await SettingsDrawerLaneSSnapshotTests.updates()
        let lines = try Self.paintedLines(SettingsDrawerLaneSSnapshotTests.drawer(.general, updates: updates), height: 470)
        let status = try Self.line(lines, containing: "no newer release")
        XCTAssertFalse(lines.contains { $0.text.contains("commits") || $0.text.contains("8e1d535") })
        let build = try Self.line(lines, containing: "2.4.0")
        XCTAssertEqual(status.box.minX, build.box.minX, accuracy: 2, "[S5] status and build line share an edge")
    }

    /// Lead review (c7 07:55Z): "no truncated copy anywhere". In the drawer, row copy wraps in full; on 8e1d5352
    /// Read Clipboard, Unload when idle and Start with VoiceBar ended in an ellipsis at 420 pt.
    func testNoRowCopyIsTruncatedInTheDrawer() async throws {
        let updates = await SettingsDrawerLaneSSnapshotTests.updates()
        for tab in [SettingsTab.general, .transcription, .speech] {
            let lines = try Self.paintedLines(SettingsDrawerLaneSSnapshotTests.drawer(tab, advanced: true,
                                                                                      updates: tab == .general ? updates : nil),
                                              height: 1500)
            let cut = lines.filter { $0.text.hasSuffix("…") || $0.text.hasSuffix("...") }
            XCTAssertTrue(cut.isEmpty, "[S2] \(tab.title) truncates: \(cut.map(\.text))")
        }
    }
}
