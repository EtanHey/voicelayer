import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// c11-Q: the transcribing spinner's colour and geometry tokens, computed (WCAG 2.x). The render-side twins are in
/// TranscribingSpinnerRenderTests.
final class TranscribingSpinnerTokenTests: XCTestCase {
    private typealias RGB = (r: Double, g: Double, b: Double)

    /// The M4's grey glass as recorded on 2026-11-12 (c9-P report; where #4A90D9's arc read 1.27:1).
    private static let m4Glass: RGB = (106.3, 114.8, 125.0)
    /// The M1's darker pill: `Theme.pillBackground` (black at 0.82) over a mid-grey menu bar (128).
    private static let m1Pill: RGB = (23.0, 23.0, 23.0)
    /// The light wing as the offscreen render draws it (TranscribingSpinnerRenderTests measured 171).
    private static let lightWing: RGB = (171, 171, 171)

    func testDarkSpinnerIsSaturatedBlueAndItsEdgeCarriesThreeToOneOnTheM4Grey() throws {
        let blue = try rgb(Theme.transcribingSpinnerColor(for: .dark))
        let edge = composite(try rgba(VoiceBarNotchGlyphContrastTreatment.resolve(for: .dark).color), over: Self.m4Glass)
        let (hue, saturation) = Self.hueSaturation(blue)
        XCTAssertEqual(hue, Self.hueSaturation(try rgb(Theme.speakingColor)).0, accuracy: 2, "the processing hue")
        XCTAssertGreaterThanOrEqual(saturation, 0.72, "reads as BLUE")
        // The fill by itself beats candidate 9's on the M4 grey; no saturated blue reaches 3:1 there alone.
        let fillOnM4 = Self.contrast(blue, Self.m4Glass)
        XCTAssertGreaterThan(fillOnM4, Self.contrast(try rgb(Theme.speakingColor), Self.m4Glass))
        XCTAssertGreaterThanOrEqual(Self.contrast(blue, edge), 3, "the arc against its own edge")
        XCTAssertGreaterThanOrEqual(Self.contrast(edge, Self.m4Glass), 3, "the edge against the M4 grey")
        XCTAssertGreaterThanOrEqual(Self.contrast(blue, Self.m1Pill), 3, "the arc on the M1's darker pill")
        print(String(format: "C11Q dark token hue %.1f sat %.2f fill-on-M4 %.2f arc-on-edge %.2f edge-on-M4 %.2f on-M1 %.2f",
                     hue, saturation, fillOnM4, Self.contrast(blue, edge), Self.contrast(edge, Self.m4Glass),
                     Self.contrast(blue, Self.m1Pill)))
    }

    func testLightSpinnerIsDeepBlueAtThreeToOneOnTheLightWing() throws {
        let blue = try rgb(Theme.transcribingSpinnerColor(for: .light))
        let (hue, saturation) = Self.hueSaturation(blue)
        XCTAssertTrue((205.0 ... 217.0).contains(hue))
        XCTAssertGreaterThanOrEqual(saturation, 0.9)
        XCTAssertGreaterThanOrEqual(Self.contrast(blue, Self.lightWing), 3)
        print(String(format: "C11Q light token hue %.1f sat %.2f on-171 %.2f on-230 %.2f", hue, saturation,
                     Self.contrast(blue, Self.lightWing), Self.contrast(blue, (230, 230, 230))))
    }

    /// Heavier and larger, a full track ring, the band's glyph edge, and still inside candidate 9's 20 pt slot.
    func testTranscribingStyleIsMorePresentAndFitsTheSlot() {
        let old = ProcessingSpinnerStyle()
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let style = ProcessingSpinnerStyle.transcribing(for: appearance)
            XCTAssertGreaterThan(style.lineWidth, old.lineWidth)
            XCTAssertGreaterThan(style.diameter, old.diameter)
            XCTAssertGreaterThan(style.trackOpacity, 0)
            XCTAssertNotNil(style.edgeColor)
            XCTAssertLessThanOrEqual(style.inkExtent, VoiceBarNotchContract.material.compactControlSize)
        }
        XCTAssertEqual(old, ProcessingSpinnerStyle(diameter: ProcessingSpinner.defaultDiameter, showsTrack: false),
                       "every other spinner keeps candidate 9's look")
    }

    func testArmingTextIsTheLiveClocksZeroInItsWidthClass() {
        XCTAssertEqual(VoiceBarRecordingTimeRegion.armingText, VoiceBarReadingTimeLabel.text(elapsedMilliseconds: 0))
        XCTAssertEqual(VoiceBarRecordingWingLabel.clockWidth(for: VoiceBarRecordingTimeRegion.armingText),
                       VoiceBarRecordingWingLabel.clockWidth(for: VoiceBarReadingTimeLabel.text(elapsedMilliseconds: 9_000)))
    }

    // MARK: - Colour maths

    private func rgba(_ color: Color) throws -> (RGB, Double) {
        let c = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return ((Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255),
                Double(c.alphaComponent))
    }

    private func rgb(_ color: Color) throws -> RGB { try rgba(color).0 }

    private func composite(_ fg: (RGB, Double), over bg: RGB) -> RGB {
        let (c, a) = fg
        return (c.r * a + bg.r * (1 - a), c.g * a + bg.g * (1 - a), c.b * a + bg.b * (1 - a))
    }

    private static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func hueSaturation(_ c: RGB) -> (Double, Double) {
        let r = c.r / 255, g = c.g / 255, b = c.b / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return (0, 0) }
        let h: Double = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d
        return ((h * 60 + 360).truncatingRemainder(dividingBy: 360), d / mx)
    }
}
