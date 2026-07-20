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

    func testPresentationModelKeepsIdleExpandedUntilTheDebouncedCollapseStateFires() {
        let model = VoiceBarNotchPresentationModel()

        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            keepsIdleExpanded: true
        )
        model.setHovered(false)
        XCTAssertEqual(model.presentation.visualState, .hoverLauncher)

        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            keepsIdleExpanded: false
        )
        XCTAssertEqual(model.presentation.visualState, .idle)
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
        XCTAssertEqual(recording.lowerSurfaceCount, 0)
        XCTAssertEqual(teleprompter.lowerSurfaceCount, 1)
        XCTAssertTrue(teleprompter.clipsContentToVisibleSurfaces)
        XCTAssertFalse(teleprompter.coreUsesMaterial)
        XCTAssertTrue(teleprompter.usesSequencedSurfaceTransitions)
        XCTAssertTrue(teleprompter.keepsHardwareCoreOutsideAnimatedSurfaces)
        XCTAssertEqual(teleprompter.accessibilityLabel, "VoiceBar teleprompter")
    }

    func testPersistentContainerOwnsOneContentBearingSurfaceAcrossVisibleStates() throws {
        let source = try notchViewSource()
        let body = try bracedScope(after: "public var body: some View", in: source)
        let container = try bracedScope(after: "VoiceBarGlassContainer", in: body)
        let surface = try bracedScope(after: "private var notchSurface", in: source)
        let slots = try bracedScope(after: "private var notchSlots", in: source)

        XCTAssertTrue(container.contains("presentation.visualState != .idle"))
        XCTAssertTrue(container.contains("notchSurface"))
        XCTAssertTrue(surface.contains("VoiceBarNotchContinuousShape"))
        XCTAssertTrue(surface.contains("notchSlots"))
        XCTAssertTrue(surface.contains(".contentShape(shape)"))
        XCTAssertFalse(surface.contains("Color.clear"))
        XCTAssertEqual(surface.components(separatedBy: "VoiceBarGlassMaterial(").count - 1, 1)
        XCTAssertTrue(slots.contains("wingSlot(leadingContent"))
        XCTAssertTrue(slots.contains("wingSlot(trailingContent"))
        XCTAssertTrue(slots.contains("lowerContent"))
        XCTAssertEqual(source.components(separatedBy: "VoiceBarGlassMaterial(").count - 1, 1)
        XCTAssertFalse(source.contains("compactSurface"))
        XCTAssertFalse(source.contains("compactWings"))
        XCTAssertFalse(source.contains("teleprompterSurface"))
        XCTAssertFalse(source.contains("coreEdgeVeils"))
        XCTAssertFalse(source.contains("VoiceBarBlackToGlassFade"))
        XCTAssertFalse(source.contains("coreEdgeVeilCount"))
        XCTAssertTrue(source.contains("fixedHardwareCore"))
        XCTAssertTrue(source.contains(".zIndex(10)"))
    }

    func testCompactSurfaceKeepsOneIdentityForInPlaceIndicatorAndWaveformTransforms() throws {
        let source = try notchViewSource()
        let compactUse = try XCTUnwrap(source.range(of: "notchSurface"))
        let fixedCoreUse = try XCTUnwrap(
            source.range(of: "fixedHardwareCore", range: compactUse.upperBound ..< source.endIndex)
        )
        let bodyCompactBranch = source[compactUse.lowerBound ..< fixedCoreUse.lowerBound]

        XCTAssertFalse(bodyCompactBranch.contains(".id(presentation.visualState)"))
        XCTAssertTrue(
            bodyCompactBranch.contains(".transition(.identity)"),
            "a collapsed shell must not leave an animated detached wing alive in the resized panel"
        )
    }

    func testCollapsedShellKeepsThePhysicalCoreAsAnInvisibleHoverTarget() throws {
        let source = try notchViewSource()

        XCTAssertTrue(source.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(source.contains("presentation.visualState != .idle"))
    }

    func testContinuousContentBearingGlassOwnsTheHoverRegion() throws {
        let source = try notchViewSource()
        let surface = try bracedScope(after: "private var notchSurface", in: source)

        XCTAssertTrue(surface.contains(".contentShape(shape)"))
        XCTAssertFalse(surface.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(surface.contains("Color.clear"))
    }

    func testTeleprompterMaterialAndContentRemovalIsAtomic() throws {
        let source = try notchViewSource()
        let body = try bracedScope(after: "public var body: some View", in: source)
        let surface = try bracedScope(after: "private var notchSurface", in: source)

        XCTAssertTrue(body.contains("notchSurface"))
        XCTAssertTrue(surface.contains("notchSlots"))
        XCTAssertTrue(body.contains(".transition(.identity)"))
        XCTAssertFalse(source.contains("teleprompterSurfaceUnit"))
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

    private func bracedScope(
        after marker: String,
        in source: some StringProtocol
    ) throws -> Substring {
        let source = String(source)
        let markerRange = try XCTUnwrap(source.range(of: marker))
        let openingBrace = try XCTUnwrap(
            source[markerRange.upperBound...].firstIndex(of: "{")
        )
        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return source[openingBrace ... cursor]
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        XCTFail("Unbalanced scope after \(marker)")
        return source[openingBrace...]
    }
}
