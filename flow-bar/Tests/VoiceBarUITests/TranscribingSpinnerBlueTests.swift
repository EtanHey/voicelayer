import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Owner r1 (S): the transcribing ring's blue. The dark ring had become the darkest it has been (`#3D9BFF`), so it
/// moves a step lighter (`#66B2FF`): still a saturated processing blue, clearly not the old pale wash
/// (rgb 160/211/251). The light ring (`#0050B2`) is already within 0.3 of the 3:1 floor on the light glass, so it
/// stays. The band tones are the glass as the real captures measured it (light rgb 171, dark rgb 35).
@MainActor
final class TranscribingSpinnerBlueTests: XCTestCase {
    static let lightBand = VoiceBarRGB(red: 171 / 255, green: 171 / 255, blue: 171 / 255)
    static let darkBand = VoiceBarRGB(red: 35 / 255, green: 35 / 255, blue: 35 / 255)
    /// The three blues per appearance the owner chooses from: today's, the pick, one step lighter still.
    static let candidates: [(VoiceBarNotchAppearance, [(String, UInt32)])] = [
        (.dark, [("today", 0x3D9BFF), ("pick", 0x66B2FF), ("lighter", 0x8AC4FF)]),
        (.light, [("today", 0x0050B2), ("pick", 0x0050B2), ("lighter", 0x0A5CC2)]),
    ]

    static func rgb(_ color: Color) throws -> VoiceBarRGB {
        let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        return VoiceBarRGB(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }

    static func hsv(_ c: VoiceBarRGB) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(c.red, c.green, c.blue), minC = min(c.red, c.green, c.blue), delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == c.blue { hue = 60 * ((c.red - c.green) / delta + 4) }
            else if maxC == c.green { hue = 60 * ((c.blue - c.red) / delta + 2) }
            else { hue = 60 * ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6) }
        }
        return ((hue + 360).truncatingRemainder(dividingBy: 360), maxC == 0 ? 0 : delta / maxC, maxC)
    }

    func testTheRingIsAClearBlueAboveTheControlRuleOnItsBand() throws {
        for appearance in [VoiceBarNotchAppearance.light, .dark] {
            let band = appearance == .light ? Self.lightBand : Self.darkBand
            let ring = try Self.rgb(Theme.transcribingSpinnerColor(for: appearance))
            let ratio = VoiceBarContrast.ratio(foreground: ring, background: band)
            let shape = Self.hsv(ring)
            print("SPINNER_BLUE \(appearance) ratio=\(String(format: "%.2f", ratio)) hue=\(Int(shape.hue)) sat=\(String(format: "%.2f", shape.saturation))")
            XCTAssertGreaterThanOrEqual(ratio, VoiceBarContrast.minimumControlRatio, "the \(appearance) ring on its band")
            XCTAssertEqual(shape.hue, 211, accuracy: 4, "the processing hue")
            XCTAssertGreaterThanOrEqual(shape.saturation, 0.55, "a working blue, not the old pale wash (0.36)")
        }
    }

    /// Fails on 708d57de: the dark ring was `#3D9BFF`. A step lighter, still short of the old pale ring.
    func testTheDarkRingIsAStepLighterThanBeforeButNotTheOldPaleWash() throws {
        let ring = VoiceBarContrast.relativeLuminance(try Self.rgb(Theme.transcribingSpinnerColor(for: .dark)))
        let before = VoiceBarContrast.relativeLuminance(VoiceBarRGB(red: 0x3D / 255, green: 0x9B / 255, blue: 1))
        let oldPale = VoiceBarContrast.relativeLuminance(VoiceBarRGB(red: 160 / 255, green: 211 / 255, blue: 251 / 255))
        XCTAssertGreaterThan(ring, before * 1.2, "a visible step lighter than #3D9BFF")
        XCTAssertLessThan(ring, oldPale * 0.85, "still clearly short of the old pale ring")
    }

    /// Opt-in: the candidates rendered as the band draws the ring, at 6x, for the owner's picture
    /// (`OWNER_R1_SHOTS=<directory>`). Labels are added by the picture's composer from `SPINNER_CANDIDATE` lines.
    func testSaveCandidateRingsWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["OWNER_R1_SHOTS"] else {
            throw XCTSkip("Set OWNER_R1_SHOTS to save the spinner candidates")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (appearance, blues) in Self.candidates {
            let band = appearance == .light ? Self.lightBand : Self.darkBand
            for (name, hex) in blues {
                let color = Color(hex: hex)
                let ratio = VoiceBarContrast.ratio(foreground: try Self.rgb(color), background: band)
                print("SPINNER_CANDIDATE \(appearance) \(name) #\(String(format: "%06X", hex)) \(String(format: "%.2f", ratio))")
                let ring = ProcessingSpinnerFrame(angle: 1.25 * 360, diameter: 15, showsTrack: true, color: color,
                                                  lineWidth: 2.6, trackOpacity: 0.24)
                    .frame(width: 32, height: 32)
                    .background(Color(red: band.red, green: band.green, blue: band.blue))
                try NotchGlyphNoEdgeTests.savePNG(ring, size: CGSize(width: 32, height: 32),
                    to: directory.appendingPathComponent("spinner-\(appearance)-\(name).png"))
            }
        }
    }
}
