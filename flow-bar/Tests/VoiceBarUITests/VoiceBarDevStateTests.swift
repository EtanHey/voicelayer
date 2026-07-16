@testable import VoiceBarUI
import XCTest

final class VoiceBarDevStateTests: XCTestCase {
    func testKeepExpandedDefaultsOff() {
        XCTAssertFalse(
            VoiceBarDevState.shouldKeepExpanded(
                environment: [:],
                fileExists: { _ in false }
            )
        )
    }

    func testKeepExpandedAcceptsExplicitEnvironmentOptIn() {
        XCTAssertTrue(
            VoiceBarDevState.shouldKeepExpanded(
                environment: [VoiceBarDevState.keepExpandedEnvironmentVariable: " 1 "],
                fileExists: { _ in false }
            )
        )
    }

    func testKeepExpandedAcceptsTmpFlagOptIn() {
        XCTAssertTrue(
            VoiceBarDevState.shouldKeepExpanded(
                environment: [:],
                fileExists: { $0 == VoiceBarDevState.keepExpandedFlagPath }
            )
        )
    }

    func testEnabledDevStateStaysExpandedPastIdleCollapseDelay() async throws {
        let state = VoiceState(keepsExpandedInDevState: true)
        state.idleCollapseDelay = 0.01

        state.setHovering(false)
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertFalse(didCollapse)
        XCTAssertFalse(state.isCollapsed)
    }

    func testDisabledDevStatePreservesIdleCollapse() async throws {
        let state = VoiceState(keepsExpandedInDevState: false)
        state.idleCollapseDelay = 0.01

        state.setHovering(false)
        let didCollapse = try await waitUntil { state.isCollapsed }

        XCTAssertTrue(didCollapse)
        XCTAssertTrue(state.isCollapsed)
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0 ..< 25 {
            if condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}
