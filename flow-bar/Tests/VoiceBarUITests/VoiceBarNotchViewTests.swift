@testable import VoiceBarUI
import XCTest

@MainActor
final class VoiceBarNotchViewTests: XCTestCase {
    func testPresentationModelTreatsHoverAndKeyboardFocusAsLauncherParity() {
        var invalidationCount = 0
        let model = VoiceBarNotchPresentationModel {
            invalidationCount += 1
        }

        XCTAssertEqual(model.presentation.visualState, .idle)
        model.setHovered(true)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)
        model.setKeyboardFocused(true)
        model.setHovered(false)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)
        model.setKeyboardFocused(false)
        XCTAssertEqual(model.presentation.visualState, .idle)
        XCTAssertEqual(invalidationCount, 2)
    }

    func testPresentationModelUsesOneReplacementTransitionAndReducedMotion() {
        let model = VoiceBarNotchPresentationModel()
        model.setReducedMotion(true)
        model.updateOperationalEnvelope(
            hasTeleprompter: true,
            isRecording: false,
            hasCompactStatus: false
        )
        let firstID = model.activeTransition?.id
        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false
        )

        XCTAssertNotEqual(firstID, model.activeTransition?.id)
        XCTAssertEqual(model.presentation.visualState, .recording)
        XCTAssertEqual(model.motionCoordinator.shellCount, 1)
        XCTAssertTrue(model.activeTransition?.plan.steps.allSatisfy { $0.animation == .opacity } == true)
    }

    func testViewContractHasOneFixedCoreTwoReusableWingsAndOptionalLowerSurface() {
        let idle = VoiceBarNotchViewDescriptor.resolve(
            presentation: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: false,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false
            )
        )
        let recording = VoiceBarNotchViewDescriptor.resolve(
            presentation: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: false,
                isRecording: true,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false
            )
        )
        let teleprompter = VoiceBarNotchViewDescriptor.resolve(
            presentation: VoiceBarNotchPresentation.resolve(
                hasTeleprompter: true,
                isRecording: false,
                hasCompactStatus: false,
                isHovered: false,
                isKeyboardFocused: false
            )
        )

        XCTAssertEqual(recording.shellIdentity, teleprompter.shellIdentity)
        XCTAssertEqual(idle.fixedCoreCount, 0)
        XCTAssertEqual(recording.fixedCoreCount, 1)
        XCTAssertEqual(recording.reusableWingSlotCount, 2)
        XCTAssertEqual(recording.coreEdgeVeilCount, 2)
        XCTAssertEqual(recording.lowerSurfaceCount, 0)
        XCTAssertEqual(teleprompter.lowerSurfaceCount, 1)
        XCTAssertEqual(teleprompter.coreEdgeVeilCount, 2)
        XCTAssertTrue(teleprompter.clipsContentToVisibleSurfaces)
        XCTAssertFalse(teleprompter.coreUsesMaterial)
        XCTAssertTrue(teleprompter.usesSequencedSurfaceTransitions)
        XCTAssertTrue(teleprompter.keepsHardwareCoreOutsideAnimatedSurfaces)
        XCTAssertEqual(teleprompter.accessibilityLabel, "VoiceBar teleprompter")
    }

    func testCompactStatesReuseTheTeleprompterCoreEdgeVeils() throws {
        let source = try notchViewSource()
        let compactStart = try XCTUnwrap(source.range(of: "private var compactSurface"))
        let compactEnd = try XCTUnwrap(
            source.range(
                of: "private var compactWings",
                range: compactStart.upperBound ..< source.endIndex
            )
        )
        let compactSurface = source[compactStart.lowerBound ..< compactEnd.lowerBound]

        XCTAssertTrue(compactSurface.contains("coreEdgeVeils"))
    }

    func testCollapsedShellKeepsThePhysicalCoreAsAnInvisibleHoverTarget() throws {
        let source = try notchViewSource()

        XCTAssertTrue(source.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(source.contains("presentation.visualState != .idle"))
    }

    func testContinuousGlassBackingKeepsBlankSurfaceInsideTheHoverRegion() throws {
        let source = try notchViewSource()
        let surfaceStart = try XCTUnwrap(source.range(of: "private var teleprompterSurface"))
        let surfaceEnd = try XCTUnwrap(
            source.range(
                of: "private var coreEdgeVeils",
                range: surfaceStart.upperBound ..< source.endIndex
            )
        )
        let surface = source[surfaceStart.lowerBound ..< surfaceEnd.lowerBound]

        XCTAssertTrue(surface.contains(".contentShape(shape)"))
        XCTAssertFalse(surface.contains(".allowsHitTesting(false)"))
    }

    private func notchViewSource() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/VoiceBarUI/VoiceBarNotchView.swift"),
            encoding: .utf8
        )
    }
}
