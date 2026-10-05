import AppKit
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class NotchPanelVisibilityTests: XCTestCase {
    @MainActor private final class Panel: NSPanel {
        var mask = 3, reorders = 0 // Bits: AppKit visible, active Space, occluded, snoozed.
        override var isVisible: Bool {
            mask & 1 != 0
        }

        override var isOnActiveSpace: Bool {
            mask & 2 != 0
        }

        override var occlusionState: NSWindow.OcclusionState {
            mask & 4 != 0 ? [] : [.visible]
        }

        override func orderFrontRegardless() {
            reorders += 1
            mask = 3
        }
    }

    @MainActor func testSelfHealOnlyForActiveVisibleMismatchAndNeverWhenSnoozed() {
        let panel = Panel()
        for mode in VoiceMode.allCases {
            for mask in 0 ..< 16 {
                panel.mask = mask
                panel.reorders = 0
                let expected = [.recording, .transcribing, .speaking].contains(mode) &&
                    panel
                    .isVisible && (!panel.isOnActiveSpace || !panel.occlusionState.contains(.visible)) && mask & 8 == 0
                var logs: [[String: String]] = []
                NotchPanelVisibility.selfHeal(panel, mode: mode, isHidden: mask & 8 != 0) { logs.append($0) }
                XCTAssertEqual(panel.reorders, expected ? 1 : 0, "\(mode) mask=\(mask)")
                XCTAssertEqual(logs.count, expected ? 1 : 0)
                if expected {
                    XCTAssertEqual(logs.first?["beforePanelWindowNumber"], String(panel.windowNumber))
                    XCTAssertEqual(logs.first?["afterPanelOcclusionVisible"], "true")
                    XCTAssertEqual(logs.first?["afterPanelOnActiveSpace"], "true")
                }
            }
        }
    }

    func testDeferredHandoffNeverOrdersOutInNonIdleModeOrAfterCancellation() {
        for mode in VoiceMode.allCases {
            for cancelled in [false, true] {
                var hides = 0, layouts = 0
                var currentMode = VoiceMode.idle
                currentMode = mode // A new mode arrived while the collapse was deferred.
                NotchPanelVisibility.finishHandoffCollapse(isCancelled: cancelled, mode: { currentMode },
                                                           refreshLayout: { layouts += 1 }, orderOut: { hides += 1 })
                XCTAssertEqual(hides, mode == .idle && !cancelled ? 1 : 0)
                XCTAssertEqual(layouts, hides)
            }
        }
    }

    func testLayoutReentryCannotHideANewRecording() {
        var mode = VoiceMode.idle, hides = 0
        NotchPanelVisibility.finishHandoffCollapse(isCancelled: false, mode: { mode },
                                                   refreshLayout: { mode = .recording }, orderOut: { hides += 1 })
        XCTAssertEqual(hides, 0)
    }
}
