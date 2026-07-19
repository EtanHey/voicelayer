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

    func testCoreSeamFadeIsMirroredAndUsesTheTightenedHardwareJoinWidth() {
        let leading = VoiceBarNotchCoreSeamDescriptor.resolve(for: .leading)
        let trailing = VoiceBarNotchCoreSeamDescriptor.resolve(for: .trailing)

        XCTAssertEqual(leading.width, 10)
        XCTAssertEqual(trailing.width, 10)
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

    func testAppearanceOverlayNeverInterceptsNotchControlClicks() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchMaterial.swift"),
            encoding: .utf8
        )
        let materialStart = try XCTUnwrap(source.range(of: "private var materialBody"))
        let paletteStart = try XCTUnwrap(
            source.range(
                of: "private var notchPalette",
                range: materialStart.upperBound ..< source.endIndex
            )
        )
        let materialBody = source[materialStart.lowerBound ..< paletteStart.lowerBound]

        XCTAssertTrue(materialBody
            .contains("shape.fill(notchPalette.surfaceOverlay.color)\n                    .allowsHitTesting(false)"))
    }

    func testSharedPanelShadowBelongsToTheMaterialSurfaceNotTheClippedIconComposite() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchMaterial.swift"),
            encoding: .utf8
        )
        let materialStart = try XCTUnwrap(source.range(of: "public struct VoiceBarGlassMaterial"))
        let wingStart = try XCTUnwrap(source.range(of: "public struct VoiceBarGlassWing"))
        let material = source[materialStart.lowerBound ..< wingStart.lowerBound]

        XCTAssertTrue(material.contains("private var materialSurface"))
        XCTAssertTrue(material.contains("content.clipShape(shape)"))
        XCTAssertFalse(
            material.contains("materialBody(content: content)"),
            "shadowing the content composite casts icon alpha into the clipped wing"
        )
    }
}
