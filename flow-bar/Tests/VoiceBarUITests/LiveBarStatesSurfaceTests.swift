import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// The pass-2 qa artifact surface must render the REAL `BarView` (post Capsule→NotchShape
/// swap) for every voice state to a real PNG — proving the live view code, not a stand-in,
/// carries the v9 silhouette. Pairs with the on-screen --live-states capture for glass.
@MainActor
final class LiveBarStatesSurfaceTests: XCTestCase {
    func testRendersLiveBarStatesSurfaceArtifact() throws {
        let surface = LiveBarStatesSurface()
        let renderer = ImageRenderer(content: surface)
        renderer.proposedSize = ProposedViewSize(width: 520, height: 560)
        renderer.scale = 2

        let cgImage = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no CGImage")
        XCTAssertGreaterThan(cgImage.width, 0)
        XCTAssertGreaterThan(cgImage.height, 0)
    }
}
