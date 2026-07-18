import CoreGraphics
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchShapeTests: XCTestCase {
    func testRecordingGlassFillsBothWingsButNeverTheHardwareCore() {
        let geometry = VoiceBarNotchContract.geometry(for: .recording)
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        let path = VoiceBarNotchContinuousShape(geometry: geometry).path(
            in: CGRect(origin: .zero, size: layout.totalSize)
        )

        XCTAssertEqual(layout.coreRect, CGRect(x: 72, y: 0, width: 185, height: 32))
        XCTAssertTrue(path.contains(CGPoint(x: 20, y: 16)))
        XCTAssertTrue(path.contains(CGPoint(x: 320, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: layout.coreRect.midX, y: 16)))
    }

    func testTeleprompterKeepsTheHousingCenteredInsideAnAsymmetricTopBar() {
        let geometry = VoiceBarNotchContract.geometry(for: .teleprompter)
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)

        XCTAssertEqual(layout.totalSize, CGSize(width: 465, height: 228))
        XCTAssertEqual(layout.coreRect, CGRect(x: 140, y: 0, width: 185, height: 32))
        XCTAssertEqual(layout.leadingWingRect, CGRect(x: 64, y: 0, width: 76, height: 32))
        XCTAssertEqual(layout.trailingWingRect, CGRect(x: 325, y: 0, width: 88, height: 32))
        XCTAssertEqual(layout.bodyRect, CGRect(x: 0, y: 32, width: 465, height: 196))
        XCTAssertEqual(layout.inverseJoinRadius, 5)
        XCTAssertEqual(layout.lowerCornerRadius, 18)
        XCTAssertEqual(layout.coreRect.midX, layout.bodyRect.midX)
    }

    func testTeleprompterUsesOneContinuousGlassPathAroundTheCore() {
        let geometry = VoiceBarNotchContract.geometry(for: .teleprompter)
        let layout = VoiceBarNotchShapeLayout(geometry: geometry)
        let path = VoiceBarNotchContinuousShape(geometry: geometry).path(
            in: CGRect(origin: .zero, size: layout.totalSize)
        )

        XCTAssertFalse(path.contains(CGPoint(x: layout.coreRect.midX, y: 16)))
        XCTAssertTrue(path.contains(CGPoint(x: layout.bodyRect.midX, y: 64)))
        XCTAssertTrue(path.contains(CGPoint(x: layout.leadingWingRect.midX, y: 16)))
        XCTAssertTrue(path.contains(CGPoint(x: layout.trailingWingRect.midX, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: 10, y: 16)))
        XCTAssertFalse(path.contains(CGPoint(x: 455, y: 16)))
        XCTAssertEqual(path.moveElementCount, 1)
    }
}

private extension Path {
    var moveElementCount: Int {
        var count = 0
        cgPath.applyWithBlock { element in
            if element.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
    }
}
