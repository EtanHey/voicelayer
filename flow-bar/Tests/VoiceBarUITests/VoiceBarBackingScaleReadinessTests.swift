import AppKit
@testable import VoiceBarUI
import XCTest

final class VoiceBarBackingScaleReadinessTests: XCTestCase {
    func testFirstRenderRequiresRerasterizationWhenTheContentStartedAtOneX() {
        let result = VoiceBarBackingScaleReadiness.evaluate(
            screenScale: 2,
            windowScale: 2,
            contentScale: 1
        )

        XCTAssertEqual(result, .rerasterize(targetScale: 2))
    }

    func testFirstRenderIsReadyOnlyWhenWindowAndContentMatchTheTargetScreen() {
        XCTAssertEqual(
            VoiceBarBackingScaleReadiness.evaluate(
                screenScale: 2,
                windowScale: 2,
                contentScale: 2,
                descendantScales: [2, 2]
            ),
            .ready(scale: 2)
        )
        XCTAssertEqual(
            VoiceBarBackingScaleReadiness.evaluate(
                screenScale: 2,
                windowScale: 1,
                contentScale: 2
            ),
            .rerasterize(targetScale: 2)
        )
    }

    func testFirstRenderRejectsAOneXSwiftUISublayerUnderATwoXRoot() {
        XCTAssertEqual(
            VoiceBarBackingScaleReadiness.evaluate(
                screenScale: 2,
                windowScale: 2,
                contentScale: 2,
                descendantScales: [2, 1, 2]
            ),
            .rerasterize(targetScale: 2)
        )
    }

    func testMissingScreenFailsClosedInsteadOfCertifyingACapture() {
        XCTAssertEqual(
            VoiceBarBackingScaleReadiness.evaluate(
                screenScale: nil,
                windowScale: 2,
                contentScale: 2
            ),
            .waitingForScreen
        )
    }

    @MainActor
    func testSynchronizerUpdatesTheRootAndEveryExistingDescendantLayer() {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        view.wantsLayer = true
        let child = CALayer()
        child.contentsScale = 1
        view.layer?.addSublayer(child)

        VoiceBarBackingScaleSynchronizer.synchronize(view, to: 2)

        XCTAssertEqual(view.layer?.contentsScale, 2)
        XCTAssertEqual(child.contentsScale, 2)
        XCTAssertEqual(
            VoiceBarBackingScaleSynchronizer.layerScales(in: view),
            [2, 2]
        )
    }
}
