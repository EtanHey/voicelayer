import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchArmingClockTests: XCTestCase {
    func testArmingDoesNotReadCaptureClockAndDrawsInkInLiveFrame() throws {
        var calls = 0
        func render(_ open: Bool) throws -> NSBitmapImageRep {
            let view = VoiceBarRecordingTimeRegion(elapsedMilliseconds: { calls += 1; return 9000 },
                isCaptureOpen: open, microphoneName: nil, color: .white)
                .frame(width: 50, height: 32).background(Color.black)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 50, height: 32)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let arming = try render(false)
        XCTAssertEqual(calls, 0, "displaying zero must not sample the capture clock")
        let live = try render(true)
        XCTAssertGreaterThan(calls, 0)
        func ink(_ rep: NSBitmapImageRep) -> Int {
            (0..<rep.pixelsWide).reduce(0) { sum, x in
                sum + (0..<rep.pixelsHigh).filter { y in
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return c.redComponent > 0.2
                }.count
            }
        }
        XCTAssertGreaterThan(ink(arming), 5, "zero is visible before capture")
        XCTAssertGreaterThan(ink(live), 5)
        XCTAssertEqual(arming.pixelsWide, live.pixelsWide)
    }
}
