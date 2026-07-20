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

    func testNativeGlassRecipeUsesNeutralTintWithoutAFilledOverlay() {
        let expectedTint = VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06)
        let expectedFallbackOverlay = VoiceBarRGBA(red: 1, green: 1, blue: 1, alpha: 0.06)

        for appearance in [VoiceBarNotchAppearance.light, .dark] {
            let recipe = VoiceBarNotchGlassRecipe.resolve(for: appearance)

            XCTAssertEqual(recipe.tint, expectedTint)
            XCTAssertNil(recipe.nativeOverlay)
            XCTAssertEqual(recipe.fallbackOverlay, expectedFallbackOverlay)
        }
    }

    func testNativeAndFallbackBranchesStayInsideSwiftUIMaterialSystem() throws {
        let source = try notchMaterialSource()
        let nativeStart = try XCTUnwrap(source.range(of: "else if #available(macOS 26.0, *)"))
        let fallbackStart = try XCTUnwrap(
            source.range(
                of: "} else {",
                range: nativeStart.upperBound ..< source.endIndex
            )
        )
        let nativeBranch = source[nativeStart.lowerBound ..< fallbackStart.lowerBound]
        let fallbackBranch = source[fallbackStart.lowerBound ..< source.endIndex]

        XCTAssertTrue(nativeBranch.contains(".regular.tint(recipe.tint.color)"))
        XCTAssertEqual(nativeBranch.components(separatedBy: ".glassEffect(").count - 1, 1)
        XCTAssertFalse(nativeBranch.contains(".background {"))
        XCTAssertFalse(nativeBranch.contains("surfaceOverlay"))
        XCTAssertTrue(fallbackBranch.contains(".background(.ultraThinMaterial, in: shape)"))
        XCTAssertTrue(fallbackBranch.contains("recipe.fallbackOverlay.color"))
        XCTAssertTrue(fallbackBranch.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(source.contains("NSVisualEffectView"))
    }

    func testNativeGlassStaysOnTheContentBearingViewAndDoesNotShadowItsGlyphAlpha() throws {
        let material = try glassMaterialSource()

        XCTAssertTrue(material.contains("content.clipShape(shape)"))
        XCTAssertTrue(material.contains(".glassEffect("))
        XCTAssertFalse(material.contains("shape.fill(.clear).glassEffect("))
        XCTAssertFalse(material.contains(".shadow("))
    }

    func testCompactContentChangesDoNotMaterializeTheGlassSurfaceAgain() throws {
        let material = try glassMaterialSource()

        XCTAssertTrue(material.contains(".glassEffectTransition(.identity)"))
        XCTAssertFalse(material.contains(".glassEffectTransition(.materialize)"))
    }

    func testGlassMaterialConsumesTheSettledAppearanceExplicitly() throws {
        let material = try glassMaterialSource()

        XCTAssertTrue(material.contains("public let appearance: VoiceBarNotchAppearance"))
        XCTAssertFalse(material.contains("@Environment(\\.voiceBarNotchAppearance)"))
        XCTAssertTrue(material.contains("VoiceBarNotchGlassRecipe.resolve(for: appearance)"))
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

    private func glassMaterialSource() throws -> Substring {
        let source = try notchMaterialSource()
        let materialStart = try XCTUnwrap(source.range(of: "public struct VoiceBarGlassMaterial"))
        return source[materialStart.lowerBound...]
    }
}
