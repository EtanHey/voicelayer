import AppKit
import SwiftUI
@testable import VoiceBarUI
import Vision
import XCTest

@MainActor
final class DictionaryDisclosureStateTests: XCTestCase {
    func testIncludedChevronMatchesCollapsedExpandedAndSearchContent() throws {
        let entry = STTDictionaryEntry(canonical: "TypeScript", variants: [])
        let preview = STTVocabularyPreview(updatedAt: "2026-11-11T00:00:00Z", entries: [],
            displayEntries: [STTDictionaryDisplayEntry(source: "bundled", entry: entry)])
        for (name, expanded, search) in [("collapsed", false, ""), ("expanded", true, ""), ("search", false, "Type")] {
            let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
                selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                vocabularyPreview: { preview }, vocabularyRevision: { 0 }, initialTab: .dictionary,
                initialDictionarySearch: search, initialDictionaryPreview: preview, initialIncludedTermsExpanded: expanded)
            let bitmap = try SettingsPolishS5Tests.render(pane.notchDrawerPane(.dictionary), height: 470,
                name: "included-\(name)")
            let lines = try SettingsPolishS5Tests.ocr(bitmap)
            let visible = lines.contains { $0.contains("typescript") }
            XCTAssertEqual(visible, expanded || !search.isEmpty)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            let candidate = try XCTUnwrap(request.results?.compactMap { $0.topCandidates(1).first }.first {
                $0.string.lowercased().contains("included terms")
            })
            let range = try XCTUnwrap(candidate.string.range(of: "included terms", options: .caseInsensitive))
            let word = try XCTUnwrap(candidate.boundingBox(for: range)).boundingBox
            let titleX = word.minX * 420
            let titleY = (1 - word.midY) * 494
            let scale = CGFloat(bitmap.pixelsWide) / 420
            let x0 = max(0, Int((titleX - 22) * scale)), x1 = Int((titleX - 4) * scale)
            let y0 = Int((titleY - 8) * scale), y1 = Int((titleY + 8) * scale)
            let backdrop = try XCTUnwrap(bitmap.colorAt(x: x0, y: y0))
            var ink: [CGPoint] = []
            for y in y0..<y1 { for x in x0..<x1 {
                let c = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                if abs(c.redComponent - backdrop.redComponent) > 0.12 { ink.append(CGPoint(x: x, y: y)) }
            } }
            XCTAssertFalse(ink.isEmpty, "The included group has a visible chevron")
            let width = (ink.map(\.x).max() ?? 0) - (ink.map(\.x).min() ?? 0)
            let height = (ink.map(\.y).max() ?? 0) - (ink.map(\.y).min() ?? 0)
            if visible { XCTAssertGreaterThan(width, height, "\(name): visible contents require a down chevron") }
            else { XCTAssertGreaterThan(height, width, "collapsed: hidden contents require a right chevron") }
            print("Included \(name): visible=\(visible), chevron ink \(width)x\(height)")
        }
    }
}
