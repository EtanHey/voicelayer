import AppKit
import SwiftUI
import Vision
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsRS5ThresholdHoverTests: XCTestCase {
    func testThresholdReasonClearsTheCompleteCandidateTitleAndHelperOnBothSurfaces() throws {
        for (surface, width) in [("drawer", CGFloat(420)), ("window", CGFloat(780))] {
            let pane = surface == "drawer" ? AnyView(SettingsPolishS5Tests.drawer(.speech))
                : AnyView(SettingsPolishS5Tests.pane(.speech))
            let bitmap = try SettingsPolishS5Tests.render(pane.environment(\.settingsHoverPreview,
                SettingsHoverPreview(lockedReasons: true)), width: width, height: 1100,
                name: "r2-threshold-hover-\(surface)")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { result -> (String, CGRect)? in
                guard let text = result.topCandidates(1).first?.string.lowercased() else { return nil }
                return (text, result.boundingBox)
            }
            let reason = try XCTUnwrap(lines.first { $0.0.contains("voice session in progress") }, "\(lines)")
            let title = try XCTUnwrap(lines.first { $0.0.contains("voice threshold") }, "\(lines)")
            // 2.4.6 track S (lead ruling 23 Nov): the space above the threshold row is the engine card's, so the
            // bubble hangs under the row. Vision uses a bottom-left origin: it must start below the title line, and
            // (below) cover no painted line, so the reason and everything around it stay readable.
            XCTAssertLessThan(reason.1.maxY, title.1.minY, surface)
            let bubble = reason.1.insetBy(dx: -8 / width, dy: -5 / 1124)
            for line in lines where !line.0.contains("voice session in progress") {
                XCTAssertFalse(bubble.intersects(line.1), "\(surface): reason covers \(line.0)")
            }
        }
    }
}
