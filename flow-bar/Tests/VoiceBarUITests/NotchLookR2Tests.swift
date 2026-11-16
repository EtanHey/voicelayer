import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class NotchLookR2Tests: XCTestCase {
    func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/VoiceBarUI/" + name + ".swift"))
    }
    func testRecordingWingsHugContentWithOpticalInnerInsets() {
        let m = VoiceBarNotchContract.material
        for inset: CGFloat in [0, 12] {
            for third in [false, true] {
                for earlier in [false, true] {
                    let p = VoiceBarPresentation.notchPresentation(from: VoiceBarNotchOperationalInput(
                        mode: .recording, showsRecordingHold: third, visibleCoreOcclusionInset: inset,
                        showsEarlierTakeProcessing: earlier))
                    let slots: CGFloat = 3 + (earlier ? 1 : 0)
                    let row = slots * m.compactControlSize + (slots - 1) * m.compactControlSpacing
                    let left = p.geometry.leadingWingWidth - m.compactContentInset - row
                    let right = p.geometry.trailingWingWidth - m.compactContentInset - VoiceBarRecordingWingLabel.width
                        - VoiceBarRecordingWingLabel.recordingMeterGap - WaveformLayout.viewportWidth
                    XCTAssertEqual(left + 5.5, right, accuracy: 0.5)
                    XCTAssertEqual(left, inset + 2.5, accuracy: 0.5)
                    XCTAssertEqual(p.geometry.leadingWingWidth, row + inset + 2.5 + m.compactContentInset, accuracy: 0.5)
                }
            }
        }
    }
}
