import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Owner r1: notch glyphs wear no outline, so each glyph colour alone must hold the 3:1 control contrast on the
/// band. The band tones are the glass as the real captures measured it (light rgb 171 over a black menu bar, dark
/// rgb 35). The M4's grey dark glass (`Theme.measuredM4GlassRGB`, the glass over a bright backdrop) is printed for
/// the report: the neutral ink clears 3:1 there too, a saturated colour cannot without an outline.
final class VoiceBarNotchGlyphTokenTests: XCTestCase {
    static let lightBand = VoiceBarRGB(red: 171 / 255, green: 171 / 255, blue: 171 / 255)
    static let darkBand = VoiceBarRGB(red: 35 / 255, green: 35 / 255, blue: 35 / 255)
    static let m4Glass = VoiceBarRGB(red: Theme.measuredM4GlassRGB.red / 255, green: Theme.measuredM4GlassRGB.green / 255,
                                     blue: Theme.measuredM4GlassRGB.blue / 255)

    static func band(_ appearance: VoiceBarNotchAppearance) -> VoiceBarRGB {
        appearance == .light ? lightBand : darkBand
    }

    static func rgb(_ color: Color) throws -> VoiceBarRGBA {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return VoiceBarRGBA(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                            blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }

    static func ratio(_ color: Color, on background: VoiceBarRGB) throws -> Double {
        VoiceBarContrast.ratio(foreground: try rgb(color).composited(over: background), background: background)
    }

    func testEveryBandGlyphColourClearsTheControlRuleWithoutAnOutline() throws {
        for appearance in [VoiceBarNotchAppearance.light, .dark] {
            let palette = VoiceBarNotchContrastPalette.resolve(for: appearance)
            let glyphs: [(String, Color)] = [
                ("primary (band controls, notes)", VoiceBarNotchGlyphForegroundRole.primaryLabel.color(for: appearance)),
                ("secondary (drawer tabs)", palette.secondary.color),
                ("status: recording", Theme.notchStateGlyphColor(for: .recording, appearance: appearance)),
                ("status: speaking", Theme.notchStateGlyphColor(for: .speaking, appearance: appearance)),
                ("status: transcribing", Theme.notchStateGlyphColor(for: .transcribing, appearance: appearance)),
                ("status: disconnected", Theme.notchStateGlyphColor(for: .disconnected, appearance: appearance)),
            ]
            for (name, color) in glyphs {
                let onBand = try Self.ratio(color, on: Self.band(appearance))
                let onM4 = try Self.ratio(color, on: Self.m4Glass)
                print("GLYPH_TOKEN \(appearance) \(name) band=\(String(format: "%.2f", onBand)) m4=\(String(format: "%.2f", onM4))")
                XCTAssertGreaterThanOrEqual(onBand, VoiceBarContrast.minimumControlRatio,
                                            "\(name) on the \(appearance) band without an outline")
            }
        }
    }

    /// An engaged Lock or Pause draws its red glyph on its own 30 % red plate (`VoiceBarPillControlButton`), so the
    /// glyph is measured against that plate over the band.
    func testEngagedRecordingGlyphClearsTheControlRuleOnItsPlate() throws {
        for appearance in [VoiceBarNotchAppearance.light, .dark] {
            let glyph = VoiceBarNotchGlyphForegroundRole.stateAccent.color(for: appearance)
            let red = try Self.rgb(Theme.recordingColor)
            let platedBand = VoiceBarRGBA(red: red.red, green: red.green, blue: red.blue, alpha: 0.30)
                .composited(over: Self.band(appearance))
            let onPlate = try Self.ratio(glyph, on: platedBand)
            print("GLYPH_TOKEN \(appearance) engaged red on plate=\(String(format: "%.2f", onPlate))")
            XCTAssertGreaterThanOrEqual(onPlate, VoiceBarContrast.minimumControlRatio,
                                        "the engaged recording glyph on its plate, \(appearance)")
            let stillRed = try Self.rgb(glyph)
            XCTAssertGreaterThan(stillRed.red - max(stillRed.green, stillRed.blue), 0.35, "it stays recognisably red")
        }
    }

    /// The old red on its plate is what failed without the outline; this pins why the token moved.
    func testThePreviousRecordingRedFailsOnItsPlateWithoutAnOutline() throws {
        let plate = VoiceBarRGBA(red: 229 / 255, green: 77 / 255, blue: 77 / 255, alpha: 0.30).composited(over: Self.lightBand)
        XCTAssertLessThan(try Self.ratio(Theme.recordingColor, on: plate), VoiceBarContrast.minimumControlRatio)
    }
}
