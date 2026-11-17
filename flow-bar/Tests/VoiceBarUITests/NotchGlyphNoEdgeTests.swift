import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// Owner r1 (2.4.3): no glyph in the notch wears an outline. Until this branch every band glyph, the drawer's tab
/// glyphs and the transcribing spinner were drawn through `notchAdaptiveGlyphEdge`, four hard 0.75 pt shadows in the
/// opposite tone (white on the light band, black on the dark one), which read as a halo around every icon.
///
/// The check is about the far side of the background. Ink drawn straight onto a flat band only ever blends towards
/// the background: on the light band every pixel is as dark as the band or darker, on the dark band as light or
/// lighter. A pixel clearly lighter than the light band (or darker than the dark one) is an edge. The real views are
/// rendered over the band tones measured so far, in both appearances; legibility comes from the glyph's own colour.
@MainActor
final class NotchGlyphNoEdgeTests: XCTestCase {
    /// The flat band tones each appearance is checked on: the light glass as rendered (171 grey), the M4's measured
    /// grey glass and the offscreen dark band (35 grey).
    static let backdrops: [(VoiceBarNotchAppearance, String, VoiceBarRGB)] = [
        (.light, "light-glass-171", VoiceBarRGB(red: 171 / 255, green: 171 / 255, blue: 171 / 255)),
        (.dark, "dark-m4-glass", VoiceBarRGB(red: Theme.measuredM4GlassRGB.red / 255,
                                             green: Theme.measuredM4GlassRGB.green / 255,
                                             blue: Theme.measuredM4GlassRGB.blue / 255)),
        (.dark, "dark-band-35", VoiceBarRGB(red: 35 / 255, green: 35 / 255, blue: 35 / 255)),
    ]

    /// Relative luminance step towards the ink that counts as an ink pixel.
    static let edgeStep = 0.06
    /// Contrast ratio beyond the background, away from the ink, that counts as an edge pixel. Relative to the
    /// background (CodeRabbit on #936): a fixed 0.06 luminance step can never be reached below the dark-band-35
    /// backdrop (luminance 0.0168), so even a black outline passed there. 1.12 sits clear of antialiasing and the glass
    /// fallback's grain on every backdrop; a black edge on 35 grey is 1.34, the old white edge on 171 grey 2.1.
    static let edgeContrast = 1.12

    func testBandControlsHaveNoEdgeInEitherAppearance() throws {
        for (appearance, label, backdrop) in Self.backdrops {
            let bitmap = try NotchDesignPixels.render(Self.bandControlStrip(appearance: appearance, backdrop: backdrop),
                                                     size: Self.stripSize)
            for (index, control) in Self.bandControls.enumerated() {
                let count = Self.edgePixels(bitmap, in: Self.slotRect(index), appearance: appearance)
                print("NO_EDGE band \(label) \(control.name) edge_pixels=\(count.edge) ink_pixels=\(count.ink)")
                XCTAssertGreaterThan(count.ink, 8, "fixture: \(control.name) drew no ink on \(label)")
                XCTAssertEqual(count.edge, 0, "\(control.name) is outlined on \(label): \(count.edge) edge pixels")
            }
        }
    }

    func testTranscribingSpinnerHasNoEdgeInEitherAppearance() throws {
        for (appearance, label, backdrop) in Self.backdrops {
            let view = ProcessingSpinner(transcribing: appearance)
                .environment(\.visualRenderTime, 1.25)
                .frame(width: 30, height: 30)
                .background(Color(red: backdrop.red, green: backdrop.green, blue: backdrop.blue))
            let bitmap = try NotchDesignPixels.render(view, size: CGSize(width: 30, height: 30))
            let count = Self.edgePixels(bitmap, in: CGRect(x: 0, y: 0, width: 30, height: 30), appearance: appearance)
            print("NO_EDGE spinner \(label) edge_pixels=\(count.edge) ink_pixels=\(count.ink)")
            XCTAssertGreaterThan(count.ink, 40, "fixture: the spinner drew no arc on \(label)")
            XCTAssertEqual(count.edge, 0, "the transcribing spinner is outlined on \(label): \(count.edge) edge pixels")
        }
    }

    func testSettingsDrawerTabGlyphsHaveNoEdgeInEitherAppearance() throws {
        for (appearance, label, backdrop) in Self.backdrops {
            let size = CGSize(width: 420, height: 120)
            let view = NotchSettingsDrawer(selectedTab: .general, appearance: appearance,
                                           context: NotchSettingsDrawerContext(updates: nil), onSelectTab: { _ in })
                .frame(width: size.width, height: size.height)
                .background(Color(red: backdrop.red, green: backdrop.green, blue: backdrop.blue))
                .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            let bitmap = try NotchDesignPixels.render(view, size: size)
            // The tab bar is the drawer's top row: five glyphs over their titles.
            let count = Self.edgePixels(bitmap, in: CGRect(x: 0, y: 0, width: size.width, height: 34),
                                        appearance: appearance)
            print("NO_EDGE drawer-tabs \(label) edge_pixels=\(count.edge) ink_pixels=\(count.ink)")
            XCTAssertGreaterThan(count.ink, 80, "fixture: the drawer drew no tab glyphs on \(label)")
            XCTAssertEqual(count.edge, 0, "the drawer's tab glyphs are outlined on \(label): \(count.edge) edge pixels")
        }
    }

    /// CodeRabbit on #936: the classifier itself must catch an outline on every band tone. A glyph wearing the old
    /// treatment (four hard 0.75 pt shadows in the opposite tone) is drawn on each backdrop; the dark-band-35 check
    /// used to need a 0.06 luminance step, which even pure black cannot reach below a 0.0168 background.
    func testTheClassifierCatchesAKnownOutlineOnEveryBackdrop() throws {
        for (appearance, label, backdrop) in Self.backdrops {
            let outline: Color = appearance == .light ? .white : .black
            let glyph = Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(VoiceBarNotchGlyphForegroundRole.primaryLabel.color(for: appearance))
                .shadow(color: outline, radius: 0, x: 0.75, y: 0)
                .shadow(color: outline, radius: 0, x: -0.75, y: 0)
                .shadow(color: outline, radius: 0, x: 0, y: 0.75)
                .shadow(color: outline, radius: 0, x: 0, y: -0.75)
                .frame(width: 20, height: 20)
                .padding(6)
                .background(Color(red: backdrop.red, green: backdrop.green, blue: backdrop.blue))
            let bitmap = try NotchDesignPixels.render(glyph, size: CGSize(width: 32, height: 32))
            let count = Self.edgePixels(bitmap, in: CGRect(x: 6, y: 6, width: 20, height: 20), appearance: appearance)
            print("NO_EDGE known-outline \(label) edge_pixels=\(count.edge) ink_pixels=\(count.ink)")
            XCTAssertGreaterThan(count.ink, 8, "fixture: the outlined glyph drew no ink on \(label)")
            XCTAssertGreaterThan(count.edge, 8, "the classifier missed a known outline on \(label)")
        }
    }

    /// Opt-in renders for the owner's picture: `OWNER_R1_SHOTS=<directory>` (band controls, spinner and drawer tabs on
    /// each band tone, at 6x so an outline is visible).
    func testSaveRendersWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["OWNER_R1_SHOTS"] else {
            throw XCTSkip("Set OWNER_R1_SHOTS to save the glyph renders")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (appearance, label, backdrop) in Self.backdrops {
            let fill = Color(red: backdrop.red, green: backdrop.green, blue: backdrop.blue)
            let strip = HStack(spacing: 0) {
                Self.bandControlStrip(appearance: appearance, backdrop: backdrop)
                ProcessingSpinner(transcribing: appearance)
                    .environment(\.visualRenderTime, 1.25)
                    .frame(width: 20, height: 20)
                    .frame(width: 32, height: Self.stripSize.height)
            }
            .background(fill)
            try Self.savePNG(strip, size: CGSize(width: Self.stripSize.width + 32, height: Self.stripSize.height),
                             to: directory.appendingPathComponent("glyphs-\(label).png"))
            let tabs = NotchSettingsDrawer(selectedTab: .general, appearance: appearance,
                                           context: NotchSettingsDrawerContext(updates: nil), onSelectTab: { _ in })
                .frame(width: 420, height: 40, alignment: .top).clipped()
                .background(fill)
                .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            try Self.savePNG(tabs, size: CGSize(width: 420, height: 40),
                             to: directory.appendingPathComponent("tabs-\(label).png"))
        }
    }

    // MARK: - Rendering

    struct BandControl {
        let name: String
        let icon: String
        let role: VoiceBarNotchGlyphForegroundRole
        var isSelected = false
    }

    /// Every outlined glyph the band draws through its control view, with the foreground the band gives it: the
    /// launcher's mic and microphone chevron, History and Settings, the recording controls (Mute, Cancel, Lock
    /// engaged in red), and reading's transport.
    static let bandControls: [BandControl] = [
        BandControl(name: "Start dictation", icon: "mic.fill", role: .primaryLabel),
        BandControl(name: "Choose microphone", icon: "chevron.down", role: .primaryLabel),
        BandControl(name: "History", icon: "clock.arrow.circlepath", role: .primaryLabel),
        BandControl(name: "Settings", icon: "gearshape", role: .primaryLabel),
        BandControl(name: "Mute microphone", icon: "mic.fill", role: .primaryLabel),
        BandControl(name: "Cancel recording", icon: "xmark", role: .primaryLabel),
        BandControl(name: "Lock engaged", icon: "lock.fill", role: .stateAccent, isSelected: true),
        BandControl(name: "Previous read", icon: "backward.end.fill", role: .primaryLabel),
        BandControl(name: "Pause read", icon: "pause.fill", role: .primaryLabel),
        BandControl(name: "Next read", icon: "forward.fill", role: .primaryLabel),
    ]

    static let slotPitch: CGFloat = 28
    static var stripSize: CGSize { CGSize(width: CGFloat(bandControls.count) * slotPitch, height: 32) }
    static func slotRect(_ index: Int) -> CGRect {
        CGRect(x: CGFloat(index) * slotPitch + 4, y: 6, width: 20, height: 20)
    }

    /// The band's controls in a row of 20 pt slots on a flat band tone, each drawn as the band draws it
    /// (`BarView.notchButton`: the role's foreground for this appearance).
    static func bandControlStrip(appearance: VoiceBarNotchAppearance, backdrop: VoiceBarRGB) -> some View {
        HStack(spacing: slotPitch - 20) {
            ForEach(Array(bandControls.enumerated()), id: \.offset) { _, control in
                VoiceBarPillControlButton(
                    icon: control.icon, optics: .resolve(for: control.icon),
                    foreground: control.role.color(for: appearance),
                    isSelected: control.isSelected,
                    selectionStyle: control.role == .stateAccent ? .recordingState : .navigation,
                    isDestructive: false, accessibilityLabel: control.name, accessibilityHint: "", action: {})
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, (slotPitch - 20) / 2)
        .frame(width: stripSize.width, height: stripSize.height)
        .background(Color(red: backdrop.red, green: backdrop.green, blue: backdrop.blue))
    }

    static func savePNG(_ view: some View, size: CGSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; VLOrderTestWindow(window)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host, scale: 6)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: - Pixels

    struct EdgeCount { let edge: Int; let ink: Int }

    /// Counts, inside `rect` (points, top-left origin), pixels beyond the local background away from the ink
    /// (`edge`) and pixels towards the ink (`ink`). The local background is the median luminance of the rect's
    /// one-point border ring, so the check holds whatever the glass fallback painted behind the control.
    static func edgePixels(_ bitmap: NSBitmapImageRep, in rect: CGRect,
                           appearance: VoiceBarNotchAppearance) -> EdgeCount {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let minX = max(0, Int(rect.minX * scale)), maxX = min(bitmap.pixelsWide, Int(rect.maxX * scale))
        let minY = max(0, Int(rect.minY * scale)), maxY = min(bitmap.pixelsHigh, Int(rect.maxY * scale))
        guard maxX - minX > 4, maxY - minY > 4 else { return EdgeCount(edge: 0, ink: 0) }
        func luminance(_ x: Int, _ y: Int) -> Double? {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { return nil }
            return VoiceBarContrast.relativeLuminance(VoiceBarRGB(red: Double(c.redComponent),
                                                                  green: Double(c.greenComponent),
                                                                  blue: Double(c.blueComponent)))
        }
        let ring = Int(scale)
        var border: [Double] = []
        for y in minY ..< maxY {
            for x in minX ..< maxX where x < minX + ring || x >= maxX - ring || y < minY + ring || y >= maxY - ring {
                if let l = luminance(x, y) { border.append(l) }
            }
        }
        guard !border.isEmpty else { return EdgeCount(edge: 0, ink: 0) }
        let background = border.sorted()[border.count / 2]
        var edge = 0, ink = 0
        for y in minY ..< maxY {
            for x in minX ..< maxX {
                guard let l = luminance(x, y) else { continue }
                let towardsInk = appearance == .light ? background - l : l - background
                // Away from the ink: lighter than the light band, darker than the dark band, by a contrast ratio.
                let beyond = appearance == .light ? (l + 0.05) / (background + 0.05) : (background + 0.05) / (l + 0.05)
                if towardsInk >= edgeStep { ink += 1 } else if towardsInk < 0, beyond >= edgeContrast { edge += 1 }
            }
        }
        return EdgeCount(edge: edge, ink: ink)
    }
}
