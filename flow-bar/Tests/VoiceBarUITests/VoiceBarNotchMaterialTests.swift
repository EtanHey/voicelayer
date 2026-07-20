import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchMaterialTests: XCTestCase {
    func testCollapsedIdlePaintsNoGlassSurface() {
        let descriptor = VoiceBarNotchMaterialDescriptor.resolve(for: .idle)

        XCTAssertEqual(descriptor.surfaceCount, 0)
        XCTAssertFalse(descriptor.usesFilledBackdropMaterial)
    }

    func testEveryVisibleStateUsesOneDirectContinuousSurface() {
        for state in [VoiceBarNotchVisualState.hoverLauncher, .recording, .compactStatus] {
            let descriptor = VoiceBarNotchMaterialDescriptor.resolve(for: state)

            XCTAssertEqual(descriptor.topology, .directContinuousSurface)
            XCTAssertEqual(descriptor.surfaceCount, 1)
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

    func testPaintedCoreSeamRampIsAbsentFromTheMaterialPath() throws {
        let source = try notchMaterialSource()

        XCTAssertFalse(source.contains("VoiceBarNotchCoreSeamDescriptor"))
        XCTAssertFalse(source.contains("VoiceBarNotchCoreSeamStop"))
        XCTAssertFalse(source.contains("VoiceBarNotchCoreSeamPlacement"))
        XCTAssertFalse(source.contains("VoiceBarBlackToGlassFade"))
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
        let materialStart = try XCTUnwrap(source.range(of: "private func materialBody"))
        let paletteStart = try XCTUnwrap(
            source.range(
                of: "private var notchPalette",
                range: materialStart.upperBound ..< source.endIndex
            )
        )
        let materialBody = source[materialStart.lowerBound ..< paletteStart.lowerBound]

        XCTAssertTrue(materialBody.contains("shape.fill(notchPalette.surfaceOverlay.color)"))
        XCTAssertTrue(materialBody.contains(".allowsHitTesting(false)"))
    }

    func testNativeGlassStaysOnTheContentBearingViewAndDoesNotShadowItsGlyphAlpha() throws {
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

        XCTAssertTrue(material.contains("content.clipShape(shape)"))
        XCTAssertTrue(material.contains(".glassEffect("))
        XCTAssertFalse(material.contains("shape.fill(.clear).glassEffect("))
        XCTAssertFalse(material.contains(".shadow("))
    }

    func testCompactContentChangesDoNotMaterializeTheGlassSurfaceAgain() throws {
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

        XCTAssertTrue(material.contains(".glassEffectTransition(.identity)"))
        XCTAssertFalse(material.contains(".glassEffectTransition(.materialize)"))
    }

    func testGlassMaterialConsumesTheSettledAppearanceExplicitly() throws {
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

        XCTAssertTrue(material.contains("public let appearance: VoiceBarNotchAppearance"))
        XCTAssertFalse(material.contains("@Environment(\\.voiceBarNotchAppearance)"))
        XCTAssertTrue(material.contains("VoiceBarNotchContrastPalette.resolve(for: appearance)"))
    }

    private func notchMaterialSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchMaterial.swift"),
            encoding: .utf8
        )
    }
}
