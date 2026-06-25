import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class ThemeColorContractTests: XCTestCase {
    func testTranscribingStateUsesSpeakingBlueChrome() {
        assertColor(Theme.stateColor(for: .transcribing), equals: Theme.speakingColor)
    }

    private func assertColor(
        _ actual: Color,
        equals expected: Color,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualComponents = resolvedSRGBComponents(for: actual)
        let expectedComponents = resolvedSRGBComponents(for: expected)

        XCTAssertEqual(actualComponents.red, expectedComponents.red, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualComponents.green, expectedComponents.green, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualComponents.blue, expectedComponents.blue, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actualComponents.alpha, expectedComponents.alpha, accuracy: 0.0001, file: file, line: line)
    }

    private func resolvedSRGBComponents(for color: Color)
        -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
            XCTFail("Could not resolve SwiftUI color in sRGB")
            return (0, 0, 0, 0)
        }

        return (nsColor.redComponent, nsColor.greenComponent, nsColor.blueComponent, nsColor.alphaComponent)
    }
}
