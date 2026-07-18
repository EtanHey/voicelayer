@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchMaterialTests: XCTestCase {
    func testCompactStatesUseFilledGlassSiblingsWithASharedContainer() {
        for state in [VoiceBarNotchVisualState.hoverLauncher, .recording, .compactStatus] {
            let descriptor = VoiceBarNotchMaterialDescriptor.resolve(for: state)

            XCTAssertEqual(descriptor.topology, .compactSiblingContainer)
            XCTAssertEqual(descriptor.surfaceCount, 2)
            XCTAssertTrue(descriptor.usesFilledBackdropMaterial)
            XCTAssertTrue(descriptor.hasOuterTopAndBottomEdgeTreatment)
            XCTAssertFalse(descriptor.usesTransparentBorderOnlyShell)
        }
    }

    func testTeleprompterUsesOneDirectGlassLayerWithoutAnInsetFrame() {
        let descriptor = VoiceBarNotchMaterialDescriptor.resolve(for: .teleprompter)

        XCTAssertEqual(descriptor.topology, .directContinuousSurface)
        XCTAssertEqual(descriptor.surfaceCount, 1)
        XCTAssertEqual(descriptor.insetFrameCount, 0)
        XCTAssertTrue(descriptor.usesFilledBackdropMaterial)
    }

    func testCoreSeamFadeIsMirroredAndReservesTheAuditedWidth() {
        let leading = VoiceBarNotchCoreSeamDescriptor.resolve(for: .leading)
        let trailing = VoiceBarNotchCoreSeamDescriptor.resolve(for: .trailing)

        XCTAssertEqual(leading.width, 16)
        XCTAssertEqual(trailing.width, 16)
        XCTAssertEqual(leading.opaqueEdge, .trailing)
        XCTAssertEqual(trailing.opaqueEdge, .leading)
        XCTAssertEqual(leading.stops.last?.opacity, 1)
        XCTAssertEqual(trailing.stops.first?.opacity, 1)
        XCTAssertEqual(leading.stops.first?.opacity, 0)
        XCTAssertEqual(trailing.stops.last?.opacity, 0)
        for (leadingStop, trailingStop) in zip(
            leading.stops,
            trailing.stops.reversed()
        ) {
            XCTAssertEqual(
                leadingStop.location,
                1 - trailingStop.location,
                accuracy: 0.0001
            )
        }
        XCTAssertEqual(
            leading.stops.map(\.opacity),
            trailing.stops.reversed().map(\.opacity)
        )
    }

    func testMaterialFallbackOrderIsNativeThenVisualEffectThenOpaque() {
        XCTAssertEqual(
            VoiceBarNotchMaterialStrategy.resolve(
                nativeGlassAvailable: true,
                visualEffectAvailable: true
            ),
            .nativeGlass
        )
        XCTAssertEqual(
            VoiceBarNotchMaterialStrategy.resolve(
                nativeGlassAvailable: false,
                visualEffectAvailable: true
            ),
            .visualEffectMaterial
        )
        XCTAssertEqual(
            VoiceBarNotchMaterialStrategy.resolve(
                nativeGlassAvailable: false,
                visualEffectAvailable: false
            ),
            .opaque
        )
    }
}
