import AppKit
import OffscreenTestSupport
import SwiftUI
import Vision

@testable import VoiceBarUI
import XCTest

@MainActor final class PreCaptureDotContrastTests: XCTestCase {
    func testLightBootingBedHasContrastWhileDarkAndLiveStayUnchanged() throws {
        func color(_ appearance: VoiceBarNotchAppearance, live: Bool = false) throws -> NSColor {
            let view = VoiceBarNotchWaveform(mode: .recording, isListening: false, isCaptureLive: live,
                recordingLevel: { 0 }, playbackLevel: { nil })
                .environment(\.voiceBarNotchAppearance, appearance)
                .frame(width: 46, height: 24).background(Color(red: 171/255, green: 171/255, blue: 171/255))
            let bitmap = try NotchDesignPixels.render(view, size: CGSize(width: 46, height: 24))
            return try XCTUnwrap(bitmap.colorAt(x: 46, y: 24)?.usingColorSpace(.sRGB))
        }
        let dark = try color(.dark), light = try color(.light)
        XCTAssertGreaterThan(abs(dark.redComponent - light.redComponent), 0.2, "pre-capture ink must follow the glass theme")
        XCTAssertEqual(dark.redComponent, 174/255, accuracy: 0.02)
        func luminance(_ c: NSColor) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
            return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
        }
        let backdrop = luminance(NSColor(srgbRed: 171/255, green: 171/255, blue: 171/255, alpha: 1))
        let contrast = (backdrop + 0.05)/(luminance(light)+0.05)
        print("DOT_R1 dark=\(dark) light=\(light) contrast=\(contrast)")
        XCTAssertGreaterThanOrEqual(contrast, 2.3)
        let liveDark = try color(.dark, live: true), liveLight = try color(.light, live: true)
        XCTAssertEqual(liveDark, liveLight, "live capture's red is independent of theme")
        XCTAssertGreaterThan(liveLight.redComponent - liveLight.greenComponent, 0.4)
    }
}
