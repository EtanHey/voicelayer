import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// #968 CodeRabbit: the drawer switch's knob must move between off and on. A bare `Circle` filled the padded frame
/// and stayed centred, so the switch said its state by track colour alone.
@MainActor
final class SettingsSwitchKnobTests: XCTestCase {
    func testTheKnobSitsLeadingWhenOffAndTrailingWhenOn() throws {
        for appearance in [VoiceBarNotchAppearance.dark, .light] {
            let off = try knobCentreX(isOn: false, appearance)
            let on = try knobCentreX(isOn: true, appearance)
            let width = SettingsSwitch.size.width
            XCTAssertLessThan(off, width / 2 - 4, "\(appearance): off knob is on the leading side (\(off))")
            XCTAssertGreaterThan(on, width / 2 + 4, "\(appearance): on knob is on the trailing side (\(on))")
            XCTAssertEqual(on - off, width - SettingsSwitch.size.height, accuracy: 1.5,
                           "\(appearance): the knob travels the track")
        }
    }

    func testTheKnobIsAFixedSquareInsideTheInset() {
        XCTAssertEqual(SettingsSwitch.knobDiameter, SettingsSwitch.size.height - 2 * SettingsSwitch.knobInset)
    }

    /// Mean x (in points) of the knob's near-white pixels in the rendered switch.
    private func knobCentreX(isOn: Bool, _ appearance: VoiceBarNotchAppearance) throws -> CGFloat {
        let scheme: ColorScheme = appearance == .dark ? .dark : .light
        let view = Toggle("Switch", isOn: .constant(isOn))
            .labelsHidden()
            .toggleStyle(.settingsSwitch)
            .environment(\.notchPaneInk, NotchPaneInk(appearance))
            .environment(\.colorScheme, scheme)
            .frame(width: SettingsSwitch.size.width, height: SettingsSwitch.size.height)
            .background(appearance == .dark ? Color(white: 0.16) : Color(white: 0.73))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsSwitch.size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        var sum = 0.0, count = 0.0
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.97, c.greenComponent > 0.97, c.blueComponent > 0.97 {
                    sum += Double(x); count += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 20, "\(appearance) isOn \(isOn): the knob paints")
        let scale = Double(bitmap.pixelsWide) / Double(SettingsSwitch.size.width)
        return CGFloat(sum / max(count, 1) / scale)
    }
}
