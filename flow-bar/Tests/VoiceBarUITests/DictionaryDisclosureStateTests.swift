import AppKit
import SwiftUI
@testable import VoiceBarUI
import Vision
import XCTest

@MainActor
final class DictionaryDisclosureStateTests: XCTestCase {
    func testWhitespaceKeepsBothGroupsCollapsedAndRealSearchOpensBoth() throws {
        let preview = STTVocabularyPreview(updatedAt: nil,
            entries: [.init(canonical: "Typewriter", variants: [])], displayEntries: [
                .init(source: "personal", entry: .init(canonical: "Typewriter", variants: [])),
                .init(source: "bundled", entry: .init(canonical: "TypeScript", variants: []))])
        for (search, visible) in [("   ", false), ("  Type  ", true)] {
            let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
                selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                vocabularyPreview: { preview }, vocabularyRevision: { 0 }, initialTab: .dictionary,
                initialDictionarySearch: search, initialDictionaryPreview: preview,
                initialIncludedTermsExpanded: false, initialYourTermsExpanded: false)
            let lines = try SettingsPolishS5Tests.ocr(SettingsPolishS5Tests.render(pane.notchDrawerPane(.dictionary), height: 470))
            XCTAssertEqual(lines.contains { $0 == "typewriter" }, visible)
            XCTAssertEqual(lines.contains { $0 == "typescript" }, visible)
            if !visible { XCTAssertFalse(lines.contains { $0.contains("of 1") }, "Whitespace is not a filtered search") }
        }
    }

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
            // Sample the chevron's fixed lane (the pane's leading 18 pt), not a window derived from the OCR
            // sub-range box: on the M4 that box started left of the real title in "Included terms (1 of 1)"
            // and clipped the chevron to 7x9 px, failing the search case although the picture was right.
            XCTAssertGreaterThan(titleX, 12, "The title must start right of the chevron lane")
            let x0 = 0, x1 = Int(18 * scale)
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
