import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class VoiceBarNotchContrastTests: XCTestCase {
    func testAppearanceDeliveryUpdatesTheBindingBeforeTheNextFrame() {
        var renderedAppearance = VoiceBarNotchAppearance.light
        let binding = Binding<VoiceBarNotchAppearance>(
            get: { renderedAppearance },
            set: { renderedAppearance = $0 }
        )

        VoiceBarNotchAppearanceDelivery.publish(.dark, to: binding)

        XCTAssertEqual(renderedAppearance, .dark)
    }

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

    @MainActor
    func testAppearanceChangeRereadsAfterAppKitSettlesInsteadOfLaggingOneToggle() async throws {
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let probe = VoiceBarEffectiveAppearanceView(frame: .zero)
        var reads = [darkAqua, aqua]
        probe.effectiveAppearanceProvider = {
            reads.count > 1 ? reads.removeFirst() : reads[0]
        }
        var observed: [VoiceBarNotchAppearance] = []
        probe.onAppearanceChange = { observed.append($0) }

        probe.handleEffectiveAppearanceChange()
        XCTAssertEqual(observed.first, .dark, "AppKit may still expose the outgoing appearance in its callback")
        for _ in 0 ..< 10 where observed.last != .light {
            await Task.yield()
        }

        XCTAssertEqual(observed.last, .light, "the settled reread must publish the current appearance")
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
        XCTAssertTrue(
            barSource.contains(
                "effectiveAppearance: NSApplication.shared.effectiveAppearance"
            )
        )
        XCTAssertTrue(readerSource.contains("viewDidChangeEffectiveAppearance"))
        XCTAssertTrue(readerSource.contains("effectiveAppearance"))
        XCTAssertTrue(readerSource.contains("scheduleSettledAppearanceRead"))
        XCTAssertTrue(readerSource.contains("await Task.yield()"))
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

    func testDarkAppearanceMaterialKeepsLightTextReadableOverBrightMenuBarContent() {
        let palette = VoiceBarNotchContrastPalette.resolve(for: .dark)
        let brightMenuBarBackdrop = VoiceBarRGB(red: 0.50, green: 0.52, blue: 0.55)
        let renderedGlass = palette.surfaceOverlay.composited(over: brightMenuBarBackdrop)

        XCTAssertGreaterThanOrEqual(
            VoiceBarContrast.ratio(
                foreground: palette.primary.composited(over: renderedGlass),
                background: renderedGlass
            ),
            VoiceBarContrast.minimumTextRatio
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

    func testCompactWingGlyphsAlwaysUseThePrimaryLabelRole() {
        XCTAssertEqual(
            VoiceBarNotchGlyphForegroundRole.resolve(
                isDestructive: false,
                isSelected: false
            ),
            .primaryLabel
        )
        XCTAssertEqual(
            VoiceBarNotchGlyphForegroundRole.resolve(
                isDestructive: true,
                isSelected: false
            ),
            .stateAccent
        )
        XCTAssertEqual(
            VoiceBarNotchGlyphForegroundRole.resolve(
                isDestructive: false,
                isSelected: true
            ),
            .stateAccent
        )
    }

    func testEveryDrivenCompactStatusUsesTheLivePrimaryLabelForeground() throws {
        let tapAgain = VoiceBarPresentation.idleStatusText(
            transcript: "",
            confirmationText: nil,
            hotkeyPhase: .awaitingSecondTap,
            hotkeyEnabled: true
        )
        let transcribing = VoiceBarPresentation.liveStatusText(
            mode: .transcribing,
            transcript: "",
            confirmationText: nil,
            hotkeyPhase: .idle,
            hotkeyEnabled: true,
            errorMessage: nil,
            transcribingStatusText: nil,
            commandModeState: nil,
            activeClipMarker: nil
        )
        let modelLoad = VoiceBarPresentation.liveStatusText(
            mode: .transcribing,
            transcript: "",
            confirmationText: nil,
            hotkeyPhase: .idle,
            hotkeyEnabled: true,
            errorMessage: nil,
            transcribingStatusText: "Loading speech model",
            commandModeState: nil,
            activeClipMarker: nil
        )

        XCTAssertEqual(tapAgain, "Tap again to lock")
        XCTAssertEqual(transcribing, "Transcribing...")
        XCTAssertEqual(modelLoad, "Loading speech model")

        let source = try barViewSource()
        let statusStart = try XCTUnwrap(source.range(of: "private var statusLabel"))
        let textStart = try XCTUnwrap(
            source.range(of: "private var statusText", range: statusStart.upperBound ..< source.endIndex)
        )
        let statusLabel = source[statusStart.lowerBound ..< textStart.lowerBound]
        XCTAssertTrue(statusLabel.contains(".foregroundStyle(notchPrimaryLabelColor)"))
    }

    @MainActor
    func testNotchPalettePrimaryLabelContrastsInBothAppearancesWithoutRelaunch() throws {
        let light = VoiceBarNotchContrastPalette.resolve(for: .light).primary
        let dark = VoiceBarNotchContrastPalette.resolve(for: .dark).primary

        XCTAssertLessThan(light.red, 0.2)
        XCTAssertGreaterThan(dark.red, 0.8)

        let source = try barViewSource()
        XCTAssertTrue(source.contains("notchPalette.primary.color"))
        XCTAssertFalse(source.contains("Color(nsColor: .labelColor)"))
    }

    private func barViewSource() throws -> String {
        let flowBarRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: flowBarRoot.appendingPathComponent("Sources/VoiceBarUI/BarView.swift"),
            encoding: .utf8
        )
    }
}
