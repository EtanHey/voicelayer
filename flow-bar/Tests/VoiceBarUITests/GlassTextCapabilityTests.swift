import AppKit
import XCTest

@MainActor
final class GlassTextCapabilityTests: XCTestCase {
    func testDimFixtureSkipsWithMeasuredHostDiagnostic() throws {
        for contrast in [0, 22, 63] {
            let capability = GlassTextCapability(contrast: contrast, macOSVersion: "fixture macOS 26")
            XCTAssertThrowsError(try capability.requireReadableText()) { error in
                XCTAssertTrue(error is XCTSkip)
                let message = (error as? XCTSkip)?.message ?? ""
                XCTAssertTrue(message.contains("fixture macOS 26"))
                XCTAssertTrue(message.contains("contrast \(contrast)"))
                XCTAssertTrue(message.contains("floor 64"))
            }
        }
    }

    func testReadableFixtureRunsAtAndAboveFloor() throws {
        for contrast in [64, 218, 255] {
            let capability = GlassTextCapability(contrast: contrast, macOSVersion: "fixture macOS 27")
            XCTAssertNoThrow(try capability.requireReadableText())
        }
    }
}
