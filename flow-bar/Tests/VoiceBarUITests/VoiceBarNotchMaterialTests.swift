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

    @MainActor
    func testRenderedCoreSeamsCarryAVisibleGradualSixteenPointFade() throws {
        let leading = try renderFade(.leading)
        let trailing = try renderFade(.trailing)

        let leadingResult = VoiceBarNotchCaptureAudit.seamFade(
            in: leading,
            blackEdge: .trailing
        )
        let trailingResult = VoiceBarNotchCaptureAudit.seamFade(
            in: trailing,
            blackEdge: .leading
        )

        XCTAssertTrue(leadingResult.passed, "\(leadingResult)")
        XCTAssertTrue(trailingResult.passed, "\(trailingResult)")
        XCTAssertGreaterThanOrEqual(leadingResult.progressingColumnCount, 4)
        XCTAssertGreaterThanOrEqual(trailingResult.progressingColumnCount, 4)
    }

    @MainActor
    private func renderFade(_ side: VoiceBarNotchSide) throws -> VoiceBarLumaImage {
        let size = CGSize(
            width: VoiceBarNotchContract.material.blackToGlassFadeWidth,
            height: VoiceBarNotchContract.topHeight
        )
        let host = NSHostingView(
            rootView: VoiceBarBlackToGlassFade(wing: side)
                .frame(width: size.width, height: size.height)
                .background(Color(white: 0.62))
        )
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "VoiceBarNotchMaterialTests", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let brightness = (0 ..< bitmap.pixelsHigh).flatMap { y in
            (0 ..< bitmap.pixelsWide).map { x -> Double in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    return 0
                }
                return Double(
                    (color.redComponent + color.greenComponent + color.blueComponent) / 3 * 255
                )
            }
        }
        return VoiceBarLumaImage(
            width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh,
            brightness: brightness
        )
    }
}
