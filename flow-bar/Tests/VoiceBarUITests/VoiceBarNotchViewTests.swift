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
        let virtualIdlePresentation = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            isHovered: false,
            isKeyboardFocused: false,
            virtualNotchIdleCoreHeight: 24
        )
        let virtualIdle = VoiceBarNotchViewDescriptor.resolve(
            presentation: virtualIdlePresentation
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
        XCTAssertEqual(virtualIdle.fixedCoreCount, 1)
        XCTAssertEqual(virtualIdlePresentation.geometry.topHeight, 24)
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

    func testPresentationModelFlipsFromHardwareIdleToVirtualIdleOnScreenChange() {
        let model = VoiceBarNotchPresentationModel()

        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            virtualNotchIdleCoreHeight: nil
        )
        let hardwareIdle = model.presentation

        model.updateOperationalEnvelope(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            virtualNotchIdleCoreHeight: 24
        )

        XCTAssertNil(hardwareIdle.virtualNotchIdleCoreHeight)
        XCTAssertEqual(hardwareIdle.geometry.topHeight, VoiceBarNotchContract.topHeight)
        XCTAssertEqual(model.presentation.virtualNotchIdleCoreHeight, 24)
        XCTAssertEqual(model.presentation.geometry.topHeight, 24)
        XCTAssertEqual(model.presentation.visualState, .idle)
    }

    func testPersistentContainerOwnsOneContentBearingSurfaceAcrossVisibleStates() throws {
        let source = try notchViewSource()
        let body = try bracedScope(after: "public var body: some View", in: source)
        let container = try bracedScope(after: "VoiceBarGlassContainer", in: body)
        let surface = try bracedScope(after: "private var notchSurface", in: source)
        let slots = try bracedScope(after: "private var notchSlots", in: source)

        XCTAssertFalse(container.contains("if presentation.visualState != .idle"))
        XCTAssertTrue(container.contains("morphingNotchSurface"))
        XCTAssertTrue(container.contains("presentation.visualState == .idle ? 0 : 1"))
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

    func testHeroKeepsOneMountedMatchedGeometryShellWithoutStateIDs() throws {
        let source = try notchViewSource()
        let hero = try bracedScope(after: "private var morphingNotchSurface", in: source)

        XCTAssertFalse(hero.contains("if presentation.visualState"))
        XCTAssertEqual(hero.components(separatedBy: ".matchedGeometryEffect(").count - 1, 1)
        XCTAssertEqual(hero.components(separatedBy: "VoiceBarNotchMorphVariant.sharedShellID").count - 1, 1)
        XCTAssertTrue(hero.contains("properties: .frame"))
        XCTAssertTrue(hero.contains("anchor: .top"))
        XCTAssertFalse(hero.contains("anchor: .topLeading"))
        XCTAssertFalse(hero.contains(".id(presentation.visualState)"))
        XCTAssertTrue(source.contains("@State private var renderedGeometry"))
        XCTAssertTrue(source.contains("withAnimation(shellAnimation.delay("))
        XCTAssertTrue(source.contains("renderedGeometry = nextGeometry"))
    }

    /// NOTCH2: the reveal mask and the shell geometry share one spring. A separate `.task` that re-armed the
    /// mask and yielded a render turn started it a frame late, which showed as a hard cut on the far wing.
    func testTheRevealMaskRidesTheGeometryTransaction() throws {
        let source = try notchViewSource()
        let surface = try bracedScope(after: "private var notchSurface", in: source)
        let geometryChange = try bracedScope(after: ".onChange(of: presentation.geometry)", in: source)
        let transaction = try bracedScope(after: "withAnimation(shellAnimation.delay(transition.delay))", in: geometryChange)

        XCTAssertTrue(source.contains("@State private var surfaceRevealProgress"))
        XCTAssertFalse(source.contains(".task(id: presentation.visualState)"))
        XCTAssertFalse(source.contains("Task.yield()"))
        XCTAssertTrue(transaction.contains("renderedGeometry = nextGeometry"))
        XCTAssertTrue(transaction.contains("surfaceRevealProgress = transition.revealProgress"))
        XCTAssertEqual(source.components(separatedBy: "surfaceRevealProgress =").count - 1, 3,
                       "only init, onAppear and the geometry transaction set the mask")
        XCTAssertTrue(surface.contains("VoiceBarNotchCoreAnchoredRevealMask"))
        XCTAssertTrue(surface.contains(".mask"))
    }

    func testCoreAnchoredRevealPreservesIndependentContentFitExtents() {
        let canvas = CGRect(x: 0, y: 0, width: 500, height: 228)
        let core = CGRect(x: 120, y: 0, width: 185, height: 32)

        let halfway = VoiceBarNotchCoreAnchoredRevealLayout.rect(
            progress: 0.5,
            in: canvas,
            coreRect: core
        )

        XCTAssertEqual(core.minX - halfway.minX, 60)
        XCTAssertEqual(halfway.maxX - core.maxX, 97.5)
        XCTAssertNotEqual(core.minX - halfway.minX, halfway.maxX - core.maxX)
        XCTAssertEqual(halfway.maxY, 130)
    }

    func testCollapsedShellKeepsThePhysicalCoreAsAnInvisibleHoverTarget() throws {
        let source = try notchViewSource()

        XCTAssertTrue(source.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(source.contains("presentation.visualState != .idle"))
        XCTAssertTrue(source.contains("virtualIdleCore"))
        XCTAssertTrue(source.contains("presentation.virtualNotchIdleCoreHeight"))
    }

    func testContinuousContentBearingGlassOwnsTheHoverRegion() throws {
        let source = try notchViewSource()
        let surface = try bracedScope(after: "private var notchSurface", in: source)
        let interactiveSurface = try XCTUnwrap(surface.components(separatedBy: ".overlay").first)

        XCTAssertTrue(surface.contains(".contentShape(shape)"))
        XCTAssertFalse(interactiveSurface.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(interactiveSurface.contains("Color.clear"))
        XCTAssertTrue(surface.contains("VoiceBarNotchMorphDelightEdge"))
        XCTAssertTrue(surface.contains(".allowsHitTesting(false)"))
    }

    func testTeleprompterMaterialAndContentRemovalIsAtomic() throws {
        let source = try notchViewSource()
        let body = try bracedScope(after: "public var body: some View", in: source)
        let surface = try bracedScope(after: "private var notchSurface", in: source)

        XCTAssertTrue(body.contains("morphingNotchSurface"))
        XCTAssertTrue(surface.contains("notchSlots"))
        XCTAssertTrue(body.contains(".transition(.identity)"))
        XCTAssertFalse(source.contains("teleprompterSurfaceUnit"))
    }

    func testFixedCoreAndContentAvoidPrototypeTransformEffects() throws {
        let source = try notchViewSource()
        let core = try bracedScope(after: "private var fixedHardwareCore", in: source)
        let slots = try bracedScope(after: "private var notchSlots", in: source)

        XCTAssertFalse(core.contains("matchedGeometryEffect"))
        XCTAssertFalse(core.contains("scaleEffect"))
        XCTAssertFalse(slots.contains("scaleEffect"))
        XCTAssertFalse(slots.contains("blur"))
        XCTAssertFalse(slots.contains("distortionEffect"))
        XCTAssertFalse(slots.contains("layerEffect"))
        XCTAssertTrue(core.contains("resolvedCanvasGeometry.coreOriginX"))
    }

    func testTeleprompterContentIsSequencedInsideTheMorphingShell() throws {
        let source = try notchViewSource()
        let slots = try bracedScope(after: "private var notchSlots", in: source)
        let transition = try bracedScope(after: "private func surfaceTransition", in: source)

        XCTAssertTrue(slots.contains(".transition("))
        XCTAssertTrue(slots.contains("surfaceTransition("))
        XCTAssertTrue(source.contains("VoiceBarNotchContract.motion.panelDelay * 2"))
        XCTAssertTrue(source.contains("VoiceBarNotchContract.motion.contentExitDuration"))
        XCTAssertTrue(source.contains("shellAnimation.delay(transition.delay"))
        XCTAssertTrue(transition.contains(".opacity"))
        XCTAssertFalse(transition.contains(".scale"))
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
