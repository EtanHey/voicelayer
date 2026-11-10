import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SmallNotchFixTests: XCTestCase {
    func testN13HintPaintsFullTextInsideNarrowGripProposal() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let ink = VoiceBarNotchContrastPalette.resolve(for: appearance).primary.color
            for width: CGFloat in [300, 420, 680] {
                let view = NotchSettingsPullHint(ink: ink)
                    .frame(width: NotchHistoryMorph.handleHitWidth, height: 18)
                    .frame(width: width, height: 40)
                    .background(appearance == .dark ? Color.black : Color.white)
                let (text, _) = try EtanQA0510Tests.paintedText(view, size: CGSize(width: width, height: 40))
                XCTAssertTrue(text.contains("release for settings"), "[N13] width=\(width) appearance=\(appearance): \(text)")
            }
        }
    }
}
