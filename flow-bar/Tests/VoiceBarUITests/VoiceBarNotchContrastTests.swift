import AppKit
@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchContrastTests: XCTestCase {
    func testLiveAppearanceTrackerFollowsAppKitBothDirectionsWithoutRelaunch() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var tracker = VoiceBarNotchAppearanceTracker(initial: .dark)

        XCTAssertTrue(tracker.receive(effectiveAppearance: aqua))
        XCTAssertEqual(tracker.appearance, .light)
        XCTAssertTrue(tracker.receive(effectiveAppearance: darkAqua))
        XCTAssertEqual(tracker.appearance, .dark)
        XCTAssertTrue(tracker.receive(effectiveAppearance: aqua))
        XCTAssertEqual(tracker.appearance, .light)
        XCTAssertFalse(tracker.receive(effectiveAppearance: aqua))
    }

    @MainActor
    func testEffectiveAppearanceProbePublishesBothDirectionsFromTheSameView() throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let probe = VoiceBarEffectiveAppearanceView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = probe
        var observed: [VoiceBarNotchAppearance] = []
        probe.onAppearanceChange = { observed.append($0) }

        window.appearance = aqua
        probe.reportEffectiveAppearance()
        XCTAssertEqual(observed.last, .light)
        window.appearance = darkAqua
        probe.reportEffectiveAppearance()

        XCTAssertEqual(observed.last, .dark)
    }

    func testNotchContrastKeysOffEffectiveAppearanceInsteadOfSwiftUIColorScheme() throws {
        let flowBarRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = flowBarRoot.appendingPathComponent("Sources/VoiceBarUI")
        let barSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("BarView.swift"),
            encoding: .utf8
        )
        let teleprompterSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("TeleprompterView.swift"),
            encoding: .utf8
        )
        let readerSource = try String(
            contentsOf: sourceRoot.appendingPathComponent("VoiceBarNotchAppearanceReader.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(barSource.contains("@Environment(\\.colorScheme)"))
        XCTAssertFalse(teleprompterSource.contains("@Environment(\\.colorScheme)"))
        XCTAssertTrue(readerSource.contains("viewDidChangeEffectiveAppearance"))
        XCTAssertTrue(readerSource.contains("effectiveAppearance"))
    }

    func testLightAppearanceUsesDarkForegroundsAboveReadableContrast() {
        let palette = VoiceBarNotchContrastPalette.resolve(for: .light)
        let renderedBackdrop = VoiceBarRGB(red: 0.86, green: 0.88, blue: 0.92)

        XCTAssertGreaterThanOrEqual(
            VoiceBarContrast.ratio(
                foreground: palette.primary.composited(over: renderedBackdrop),
                background: renderedBackdrop
            ),
            VoiceBarContrast.minimumTextRatio
        )
        XCTAssertGreaterThanOrEqual(
            VoiceBarContrast.ratio(
                foreground: palette.secondary.composited(over: renderedBackdrop),
                background: renderedBackdrop
            ),
            VoiceBarContrast.minimumControlRatio
        )
    }

    func testDarkAppearanceUsesLightForegroundsAboveReadableContrast() {
        let palette = VoiceBarNotchContrastPalette.resolve(for: .dark)
        let renderedBackdrop = VoiceBarRGB(red: 0.24, green: 0.27, blue: 0.32)

        XCTAssertGreaterThanOrEqual(
            VoiceBarContrast.ratio(
                foreground: palette.primary.composited(over: renderedBackdrop),
                background: renderedBackdrop
            ),
            VoiceBarContrast.minimumTextRatio
        )
        XCTAssertGreaterThanOrEqual(
            VoiceBarContrast.ratio(
                foreground: palette.secondary.composited(over: renderedBackdrop),
                background: renderedBackdrop
            ),
            VoiceBarContrast.minimumControlRatio
        )
    }

    func testPixelAuditRejectsWhiteOnLightAndAcceptsThemeAwareForeground() {
        let lightBackdrop = VoiceBarRGB(red: 0.90, green: 0.91, blue: 0.94)
        let unreadableWhitePixels = Array(
            repeating: VoiceBarRGB(red: 0.98, green: 0.98, blue: 0.99),
            count: 24
        )
        let readableDarkPixels = Array(
            repeating: VoiceBarRGB(red: 0.10, green: 0.11, blue: 0.14),
            count: 24
        )

        XCTAssertFalse(
            VoiceBarContrast.passesPixelSample(
                foregroundPixels: unreadableWhitePixels,
                background: lightBackdrop,
                minimumRatio: VoiceBarContrast.minimumControlRatio
            )
        )
        XCTAssertTrue(
            VoiceBarContrast.passesPixelSample(
                foregroundPixels: readableDarkPixels,
                background: lightBackdrop,
                minimumRatio: VoiceBarContrast.minimumControlRatio
            )
        )
    }

    func testPixelAuditOnlySelectsForegroundInTheAppearanceDirection() {
        let lightBackdrop = VoiceBarRGB(red: 0.86, green: 0.88, blue: 0.92)
        let darkBackdrop = VoiceBarRGB(red: 0.24, green: 0.27, blue: 0.32)
        let darkInk = VoiceBarRGB(red: 0.10, green: 0.11, blue: 0.14)
        let lightInk = VoiceBarRGB(red: 0.96, green: 0.97, blue: 0.99)

        XCTAssertTrue(
            VoiceBarContrast.isForegroundCandidate(
                darkInk,
                against: lightBackdrop,
                appearance: .light
            )
        )
        XCTAssertFalse(
            VoiceBarContrast.isForegroundCandidate(
                lightInk,
                against: lightBackdrop,
                appearance: .light
            )
        )
        XCTAssertTrue(
            VoiceBarContrast.isForegroundCandidate(
                lightInk,
                against: darkBackdrop,
                appearance: .dark
            )
        )
        XCTAssertFalse(
            VoiceBarContrast.isForegroundCandidate(
                darkInk,
                against: darkBackdrop,
                appearance: .dark
            )
        )
    }

    func testTeleprompterMinimumOpacityStaysReadableInBothAppearances() {
        XCTAssertGreaterThanOrEqual(
            VoiceBarNotchContrastPalette.minimumTeleprompterOpacity(for: .light),
            0.70
        )
        XCTAssertGreaterThanOrEqual(
            VoiceBarNotchContrastPalette.minimumTeleprompterOpacity(for: .dark),
            0.56
        )
    }
}
