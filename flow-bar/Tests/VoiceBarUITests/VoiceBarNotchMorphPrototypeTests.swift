@testable import VoiceBarUI
import XCTest

@MainActor
final class VoiceBarNotchMorphPrototypeTests: XCTestCase {
    func testEnvironmentSelectsEachRuntimePrototypeAndUnknownFallsBackToP1() {
        for variant in VoiceBarNotchMorphVariant.allCases {
            XCTAssertEqual(
                VoiceBarNotchMorphVariant.resolve(
                    environment: [VoiceBarNotchMorphVariant.environmentVariable: variant.rawValue],
                    persistedRawValue: nil
                ),
                variant
            )
        }

        XCTAssertEqual(
            VoiceBarNotchMorphVariant.resolve(
                environment: [VoiceBarNotchMorphVariant.environmentVariable: "unknown"],
                persistedRawValue: VoiceBarNotchMorphVariant.p3SpringDelight.rawValue
            ),
            .p1Matched
        )
    }

    func testPersistedSelectionIsUsedWhenEnvironmentIsAbsent() {
        XCTAssertEqual(
            VoiceBarNotchMorphVariant.resolve(
                environment: [:],
                persistedRawValue: VoiceBarNotchMorphVariant.p2NativeGlass.rawValue
            ),
            .p2NativeGlass
        )
        XCTAssertEqual(
            VoiceBarNotchMorphVariant.resolve(environment: [:], persistedRawValue: nil),
            .p1Matched
        )
    }

    func testP2FallsBackToP1BeforeMacOS26WithoutChangingTheUserSelection() {
        let descriptor = VoiceBarNotchMorphVariant.p2NativeGlass.descriptor(
            nativeGlassAvailable: false,
            reducedMotion: false
        )

        XCTAssertEqual(descriptor.effectiveVariant, .p1Matched)
        XCTAssertTrue(descriptor.usesMatchedGeometry)
        XCTAssertFalse(descriptor.usesNativeGlassContainer)
        XCTAssertFalse(descriptor.usesGlassEffectID)
    }

    func testAllVariantsKeepTheCoreFixedAndTextOutsideTransformEffects() {
        for variant in VoiceBarNotchMorphVariant.allCases {
            let descriptor = variant.descriptor(
                nativeGlassAvailable: true,
                reducedMotion: false
            )

            XCTAssertEqual(descriptor.fixedCoreTranslation, .zero)
            XCTAssertFalse(descriptor.transformsContent)
            XCTAssertFalse(descriptor.blursContent)
            XCTAssertTrue(descriptor.usesMatchedGeometry)
        }
    }

    func testNativeVariantUsesBothSwiftUIIdentityAndTheAppKitContainerWithoutSwiftUIGlassPixels() {
        let descriptor = VoiceBarNotchMorphVariant.p2NativeGlass.descriptor(
            nativeGlassAvailable: true,
            reducedMotion: false
        )

        XCTAssertTrue(descriptor.usesNativeGlassContainer)
        XCTAssertTrue(descriptor.usesGlassEffectID)
        XCTAssertGreaterThan(descriptor.nativeGlassSpacing, 0)
        XCTAssertFalse(descriptor.usesSwiftUIGlassMaterial)
    }

    func testSpringDelightStaysInsideResearchBoundsAndReducedMotionDisablesIt() {
        let delight = VoiceBarNotchMorphVariant.p3SpringDelight.descriptor(
            nativeGlassAvailable: true,
            reducedMotion: false
        )

        XCTAssertGreaterThanOrEqual(delight.maximumMaterialScaleDelta, 0.02)
        XCTAssertLessThanOrEqual(delight.maximumMaterialScaleDelta, 0.04)
        XCTAssertLessThanOrEqual(delight.maximumOvershoot, 4)
        XCTAssertGreaterThanOrEqual(delight.childStagger, 0.03)
        XCTAssertLessThanOrEqual(delight.childStagger, 0.06)
        XCTAssertLessThanOrEqual(delight.totalDuration, 0.35)
        XCTAssertEqual(delight.heroDampingFraction, 0.75, accuracy: 0.001)

        let reduced = VoiceBarNotchMorphVariant.p3SpringDelight.descriptor(
            nativeGlassAvailable: true,
            reducedMotion: true
        )
        XCTAssertEqual(reduced.maximumMaterialScaleDelta, 0)
        XCTAssertEqual(reduced.maximumOvershoot, 0)
    }

    func testSelectionModelUpdatesLiveAndPersistsTheRawValue() throws {
        let suiteName = "VoiceBarNotchMorphPrototypeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = VoiceBarNotchMorphSelection(
            environment: [:],
            defaults: defaults
        )

        selection.select(.p3SpringDelight)

        XCTAssertEqual(selection.variant, .p3SpringDelight)
        XCTAssertEqual(
            defaults.string(forKey: VoiceBarNotchMorphSelection.defaultsKey),
            VoiceBarNotchMorphVariant.p3SpringDelight.rawValue
        )
    }

    func testPrototypeCanvasKeepsStableMaximumWidthAndStateSizedHeight() {
        let recording = presentation(.recording)
        let teleprompter = presentation(.teleprompter)
        let recordingCanvas = VoiceBarNotchMorphCanvasLayout.resolve(for: recording)
        let teleprompterCanvas = VoiceBarNotchMorphCanvasLayout.resolve(for: teleprompter)

        XCTAssertEqual(recordingCanvas.canvasGeometry.totalWidth, 520)
        XCTAssertEqual(teleprompterCanvas.canvasGeometry.totalWidth, 520)
        XCTAssertEqual(recordingCanvas.canvasGeometry.totalHeight, 32)
        XCTAssertEqual(teleprompterCanvas.canvasGeometry.totalHeight, 228)
        XCTAssertEqual(
            recording.geometry.coreOriginX + recordingCanvas.contentOffsetX,
            recordingCanvas.canvasGeometry.coreOriginX
        )
        XCTAssertEqual(
            teleprompter.geometry.coreOriginX + teleprompterCanvas.contentOffsetX,
            teleprompterCanvas.canvasGeometry.coreOriginX
        )
    }

    func testStableCanvasContainsRecordingGeometryWithTheVADHoldControl() {
        let recording = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: true,
            hasCompactStatus: false,
            recordingTrailingWingWidth: VoiceBarNotchContract.recordingWingWidthWithHoldControl,
            isHovered: false,
            isKeyboardFocused: false
        )
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: recording)
        let layout = VoiceBarPanelLayout.make(
            presentation: recording,
            canvasGeometry: canvas.canvasGeometry
        )
        let panelBounds = CGRect(origin: .zero, size: layout.panelSize)

        XCTAssertEqual(recording.geometry.totalWidth, 520)
        XCTAssertGreaterThanOrEqual(canvas.canvasGeometry.totalWidth, recording.geometry.totalWidth)
        XCTAssertEqual(canvas.canvasGeometry.lowerSurfaceHeight, 0)
        XCTAssertTrue(panelBounds.contains(layout.activeHitRect))
    }

    func testStateSizedWindowsKeepTheCoreAndTopEdgeInvariant() {
        let recording = presentation(.recording)
        let teleprompter = presentation(.teleprompter)
        let recordingCanvas = VoiceBarNotchMorphCanvasLayout.resolve(for: recording)
        let teleprompterCanvas = VoiceBarNotchMorphCanvasLayout.resolve(for: teleprompter)
        let recordingLayout = VoiceBarPanelLayout.make(
            presentation: recording,
            canvasGeometry: recordingCanvas.canvasGeometry
        )
        let teleprompterLayout = VoiceBarPanelLayout.make(
            presentation: teleprompter,
            canvasGeometry: teleprompterCanvas.canvasGeometry
        )
        let screen = VoiceBarNotchScreenGeometry.resolve(
            metrics: VoiceBarNotchScreenMetrics(
                frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                safeAreaTop: 32,
                auxiliaryTopLeftArea: CGRect(x: 0, y: 1085, width: 771, height: 32),
                auxiliaryTopRightArea: CGRect(x: 956, y: 1085, width: 772, height: 32)
            )
        )
        let recordingFrame = recordingLayout.windowFrame(anchoredTo: screen)
        let teleprompterFrame = teleprompterLayout.windowFrame(anchoredTo: screen)
        let recordingCoreMidX = recordingFrame.minX
            + recordingLayout.visibleContentRect.minX
            + recording.geometry.coreMidX
        let teleprompterCoreMidX = teleprompterFrame.minX
            + teleprompterLayout.visibleContentRect.minX
            + teleprompter.geometry.coreMidX

        XCTAssertEqual(recordingLayout.panelSize.height, 49)
        XCTAssertEqual(teleprompterLayout.panelSize.height, 245)
        XCTAssertNotEqual(recordingFrame, teleprompterFrame)
        XCTAssertEqual(recordingFrame.maxY, teleprompterFrame.maxY)
        XCTAssertEqual(recordingCoreMidX, screen.housingFrame.midX)
        XCTAssertEqual(teleprompterCoreMidX, screen.housingFrame.midX)
        XCTAssertFalse(recordingFrame.contains(CGPoint(x: screen.housingFrame.midX, y: 1060)))
        XCTAssertTrue(teleprompterFrame.contains(CGPoint(x: screen.housingFrame.midX, y: 1060)))
        XCTAssertFalse(
            recordingLayout.containsActiveContent(
                CGPoint(
                    x: recordingLayout.panelSize.width / 2,
                    y: VoiceBarNotchShadowOutsets.material.bottom + 100
                )
            )
        )
    }

    private func presentation(_ state: VoiceBarNotchVisualState) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation.resolve(
            hasTeleprompter: state == .teleprompter,
            isRecording: state == .recording,
            hasCompactStatus: state == .compactStatus,
            isHovered: state == .hoverLauncher,
            isKeyboardFocused: false
        )
    }
}
