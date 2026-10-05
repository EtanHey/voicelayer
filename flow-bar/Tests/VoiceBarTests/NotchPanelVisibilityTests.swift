import AppKit
@testable import VoiceBar
import VoiceBarUI
import XCTest

final class NotchPanelVisibilityTests: XCTestCase {
    @MainActor private final class Panel: NSPanel {
        var reportedVisible = true, onSpace = true, occluded = false
        var reorders = 0
        override var isVisible: Bool {
            reportedVisible
        }

        override var isOnActiveSpace: Bool {
            onSpace
        }

        override var occlusionState: NSWindow.OcclusionState {
            occluded ? [] : [.visible]
        }

        override func orderFrontRegardless() {
            reorders += 1
            onSpace = true
            occluded = false
        }
    }

    @MainActor func testSelfHealOnlyForActiveVisibleMismatchAndNeverWhenSnoozed() {
        let panel = Panel()
        for mode in VoiceMode.allCases {
            for mask in 0 ..< 16 {
                panel.reportedVisible = mask & 1 != 0
                panel.onSpace = mask & 2 != 0
                panel.occluded = mask & 4 != 0
                panel.reorders = 0
                let hidden = mask & 8 != 0
                let expected = [.recording, .transcribing, .speaking].contains(mode) &&
                    panel.reportedVisible && (!panel.onSpace || panel.occluded) && !hidden
                var logs: [[String: String]] = []
                NotchPanelVisibility.selfHeal(panel, mode: mode, isHidden: hidden) { logs.append($0) }
                XCTAssertEqual(panel.reorders, expected ? 1 : 0, "\(mode) mask=\(mask)")
                XCTAssertEqual(logs.count, expected ? 1 : 0)
                if expected {
                    XCTAssertEqual(logs.first?["beforePanelVisible"], "true")
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
                let deferred = {
                    NotchPanelVisibility.finishHandoffCollapse(isCancelled: cancelled, mode: { currentMode },
                                                               refreshLayout: { layouts += 1 },
                                                               orderOut: { hides += 1 })
                }
                currentMode = mode // A new mode arrived while the collapse was deferred.
                deferred()
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
