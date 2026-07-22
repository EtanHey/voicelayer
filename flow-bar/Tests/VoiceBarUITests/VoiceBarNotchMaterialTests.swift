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
            XCTAssertEqual(recipe.nativeHost, .appKitGlassEffectView)
        }
    }

    func testNativeBranchBypassesSwiftUIGlassThroughOneAppKitGlassHost() throws {
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

        XCTAssertTrue(nativeBranch.contains("VoiceBarAppKitGlassHost"))
        XCTAssertTrue(nativeBranch.contains("tint: recipe.tint"))
        XCTAssertFalse(nativeBranch.contains(".glassEffect("))
        XCTAssertFalse(nativeBranch.contains(".ultraThinMaterial"))
        XCTAssertTrue(fallbackBranch.contains(".background(.ultraThinMaterial, in: shape)"))
        XCTAssertTrue(fallbackBranch.contains("recipe.fallbackOverlay.color"))
        XCTAssertTrue(fallbackBranch.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(source.contains("NSViewRepresentable"))
        XCTAssertTrue(source.contains("NSGlassEffectView"))
        XCTAssertFalse(source.contains("NSVisualEffectView"))
    }

    func testAppKitGlassEmbedsTheContentAndMasksOutTheOpaqueHardwareCore() throws {
        let material = try glassMaterialSource()

        XCTAssertTrue(material.contains("content.clipShape(shape)"))
        XCTAssertTrue(material.contains("VoiceBarAppKitGlassHost"))
        XCTAssertTrue(material.contains("contentView = hostingView"))
        XCTAssertTrue(material.contains("CAShapeLayer"))
        XCTAssertTrue(material.contains("shape.path(in: rect).cgPath"))
        XCTAssertFalse(material.contains(".glassEffect("))
        XCTAssertFalse(material.contains(".shadow("))
    }

    func testNativeGlassLeavesHoverTrackingToTheAuthoritativePanelPath() throws {
        let source = try notchMaterialSource()
        let glassView = try bracedScope(
            after: "private final class VoiceBarTrackedGlassEffectView",
            in: source
        )
        let glassContainer = try bracedScope(
            after: "private final class VoiceBarTrackedGlassContainerView",
            in: source
        )

        for nativeHost in [glassView, glassContainer] {
            XCTAssertFalse(nativeHost.contains("NSTrackingArea"))
            XCTAssertFalse(nativeHost.contains("updateTrackingAreas"))
            XCTAssertFalse(nativeHost.contains("mouseEntered"))
            XCTAssertFalse(nativeHost.contains("mouseExited"))
        }
    }

    func testNativeGlassDisablesImplicitAppKitOrderOutUntilTheExplicitMorphRound() throws {
        let source = try notchMaterialSource()

        XCTAssertTrue(source.contains("override func animation(forKey"))
        XCTAssertTrue(source.contains("NSAnimatablePropertyKey"))
        XCTAssertTrue(source.contains("-> Any? {\n        nil\n    }"))
    }

    func testP2WrapsTheProvenAppKitHostWithoutRestoringSwiftUIGlassMaterial() throws {
        let source = try notchMaterialSource()

        XCTAssertTrue(source.contains("GlassEffectContainer(spacing:"))
        XCTAssertTrue(source.contains(".glassEffectID("))
        XCTAssertTrue(source.contains("NSGlassEffectContainerView"))
        XCTAssertTrue(source.contains("VoiceBarAppKitGlassHost"))
        XCTAssertTrue(source.contains("useNativeContainer: nativeContainerEnabled"))
        XCTAssertTrue(source.contains("if useNativeContainer"))
        XCTAssertFalse(source.contains(".glassEffect(.regular"))
        XCTAssertFalse(source.contains("NSVisualEffectView"))
    }

    func testP1AndP3KeepTheDirectPhaseOneGlassHost() throws {
        let source = try notchMaterialSource()
        let host = try bracedScope(after: "private struct VoiceBarAppKitGlassHost", in: source)

        XCTAssertTrue(host.contains("let useNativeContainer: Bool"))
        XCTAssertTrue(host.contains("return glassView"))
        XCTAssertTrue(host.contains("VoiceBarTrackedGlassContainerView"))
        XCTAssertTrue(source.contains("private var nativeContainerEnabled: Bool"))
    }

    func testLiveVariantSelectionRebuildsTheAppKitHostTopology() throws {
        let material = try glassMaterialSource()

        XCTAssertTrue(material.contains(".id(morphVariant.rawValue)"))
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

    private func bracedScope(after marker: String, in source: String) throws -> Substring {
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(
            source[markerRange.upperBound...].firstIndex(of: "{")
        )
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source[openingBrace ... cursor]
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        throw NSError(domain: "VoiceBarNotchMaterialTests", code: 1)
    }
}
