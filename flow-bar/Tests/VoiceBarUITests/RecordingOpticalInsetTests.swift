import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision

@testable import VoiceBarUI
import XCTest

@MainActor final class RecordingOpticalInsetTests: XCTestCase {
    func testCancelInkGapAndReservedContentWidths() throws {
        let bearing = try Self.cancelInkBearing()
        for inset: CGFloat in [0, 8.5, 12, 24] {
            for earlier in [false, true] {
                let p = VoiceBarPresentation.notchPresentation(from: .init(mode: .recording,
                    visibleCoreOcclusionInset: inset, showsEarlierTakeProcessing: earlier))
                let layout = VoiceBarNotchContract.material.wingContentLayout(for: .leading, state: .recording,
                    visibleCoreOcclusionInset: inset)
                let gap = layout.coreInset + bearing
                print("OPTICAL_R1 occlusion=\(inset) X_ink_gap=\(gap) glyph_bearing=\(bearing)")
                // 8.5 is the real capture's calibration. Keep calibration in the equation on other screens.
                XCTAssertEqual(gap, 16.5 + inset - 8.5, accuracy: 0.5)
                XCTAssertEqual(layout.coreInset, inset + 2.5)
                XCTAssertEqual(p.geometry.leadingWingWidth, (earlier ? 114.5 : 88.5) + inset)
                XCTAssertEqual(p.geometry.trailingWingWidth, 102 + inset)
                XCTAssertEqual(layout.outerInset, 14)
                let fallback = VoiceBarNotchInteractionConfiguration.fallback(for: p)
                XCTAssertEqual(fallback.leadingCoreInset, layout.coreInset)
                let region = VoiceBarNotchHitRegion(geometry: p.geometry, configuration: fallback)
                XCTAssertEqual(region.rects.first?.maxX, p.geometry.coreOriginX - layout.coreInset,
                               "the innermost fallback hit rectangle follows Cancel's slot")
                XCTAssertEqual(VoiceBarPresentation.recordingLeadingCoreInset(wingWidth: p.geometry.leadingWingWidth,
                    showsEarlierTakeProcessing: earlier, visibleCoreOcclusionInset: inset), layout.coreInset,
                    "hit rectangles and wing dabs use the painted row's core inset")
            }
        }
    }
    static func cancelInkBearing() throws -> CGFloat {
        let button = VoiceBarPillControlButton(icon: "xmark", optics: .resolve(for: "xmark"), foreground: .white,
            halo: .black, isSelected: false, isDestructive: false, accessibilityLabel: "Cancel", accessibilityHint: "", action: {})
        let bitmap = try NotchDesignPixels.render(button.frame(width: 20, height: 20).padding(10).background(.black),
                                                 size: CGSize(width: 40, height: 40))
        let ink = try XCTUnwrap(NotchDesignPixels.inkBounds(bitmap, rect: CGRect(x: 10, y: 10, width: 20, height: 20)))
        return 30 - ink.maxX
    }

}
