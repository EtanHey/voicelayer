import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision

@testable import VoiceBarUI
import XCTest

@MainActor final class DictionaryActionCapAlignmentTests: XCTestCase {
    func testActionsCentreOnTitleInkWithAndWithoutVariants() throws {
        for large in [false, true] {
            let entries = [STTDictionaryEntry(canonical: "SWIFTUI", variants: []),
                           STTDictionaryEntry(canonical: "TYPESCRIPT", variants: ["typed script"])]
            let preview = STTVocabularyPreview(updatedAt: nil, entries: entries)
            let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
                selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                vocabularyPreview: { preview }, vocabularyRevision: { 0 }, initialTab: .dictionary,
                initialDictionaryPreview: preview)
            let view = pane.notchDrawerPane(.dictionary).environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            let bitmap = try SettingsDrawerLaneSSnapshotTests.render(view, height: 700, name: "action-caps")
            let dir = ProcessInfo.processInfo.environment["DESIGN_R1_PIXELS"]
            if let dir { try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: dir).appendingPathComponent("dictionary-\(large).png")) }
            // Locate actual capital ink, then independently measure the pencil and ellipsis ink in that row.
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            for entry in entries {
                let row = try XCTUnwrap(request.results?.first { $0.topCandidates(1).first?.string.contains(entry.canonical) == true })
                let titleY = (1-row.boundingBox.midY)*700
                let title = try XCTUnwrap(NotchDesignPixels.inkBounds(bitmap,
                    rect: CGRect(x: 15, y: titleY-9, width: 100, height: 18)))
                for rect in [CGRect(x: 368, y: title.midY-15, width: 24, height: 30),
                             CGRect(x: 394, y: title.midY-15, width: 24, height: 30)] {
                    let glyph = try XCTUnwrap(NotchDesignPixels.inkBounds(bitmap, rect: rect))
                    print("CAP_R1 \(entry.canonical) large=\(large) title=\(title) action=\(glyph)")
                    XCTAssertEqual(glyph.midY, title.midY, accuracy: 1, "action ink must centre on the capital title ink")
                }
            }
        }
    }
}
