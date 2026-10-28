import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// NOTCH2 R2 (Sol): the note no longer resizes the window, so AppKit's hit providers must follow the shell as
/// drawn. While a same-size change settles, nothing the interpolated shell has not reached may be claimed.
final class VoiceBarPanelHitGateTests: XCTestCase {
    private let note = "Busy recording. Selection not read"
    private let progressPoints: [CGFloat] = stride(from: 0, through: 1, by: 0.1).map { CGFloat($0) }

    private var inputs: [(String, VoiceBarNotchOperationalInput)] {
        var teleprompter = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true)
        teleprompter.statusText = "Speaking…"
        var history = VoiceBarNotchOperationalInput(mode: .idle)
        history.isHistoryPanelOpen = true
        return [
            ("recording", .init(mode: .recording)),
            ("recording + hold", .init(mode: .recording, showsRecordingHold: true)),
            ("transcribing", .init(mode: .transcribing, statusText: "Transcribing…")),
            ("teleprompter", teleprompter),
            ("launcher", .init(mode: .idle, isHovered: true)),
            ("history", history),
        ]
    }

    private func layout(_ input: VoiceBarNotchOperationalInput, note: String?) -> VoiceBarPanelLayout {
        var input = input
        input.transientNote = note
        let presentation = VoiceBarPresentation.notchPresentation(from: input)
        return layout(presentation)
    }

    private func layout(_ presentation: VoiceBarNotchPresentation) -> VoiceBarPanelLayout {
        VoiceBarPanelLayout.make(
            presentation: presentation,
            canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
        )
    }

    /// Window-local (AppKit, bottom-up) point at the centre of the note band.
    private func noteBandPoint(_ noted: VoiceBarPanelLayout) -> CGPoint {
        let geometry = noted.presentation.geometry
        return CGPoint(
            x: noted.visibleContentRect.minX + geometry.coreMidX,
            y: noted.visibleContentRect.minY + geometry.totalHeight
                - (geometry.topHeight + VoiceBarNotchContract.transientNoteBandHeight / 2)
        )
    }

    private func corePoint(_ layout: VoiceBarPanelLayout) -> CGPoint {
        let geometry = layout.presentation.geometry
        return CGPoint(
            x: layout.visibleContentRect.minX + geometry.coreMidX,
            y: layout.visibleContentRect.minY + geometry.totalHeight - geometry.topHeight / 2
        )
    }

    func testANoteEnteringClaimsItsBandOnlyOnceTheShellSettles() {
        let plain = layout(.init(mode: .recording), note: nil)
        let noted = layout(.init(mode: .recording), note: note)
        let band = noteBandPoint(noted)
        XCTAssertTrue(noted.containsVisibleSurface(band), "the destination claims the band at once")
        XCTAssertFalse(plain.containsVisibleSurface(band))

        var gate = VoiceBarPanelHitGate(layout: plain)
        XCTAssertTrue(gate.update(to: noted, now: 100))
        XCTAssertFalse(gate.containsVisibleSurface(band, now: 100.05), "the undrawn band must pass clicks through")
        XCTAssertTrue(gate.containsVisibleSurface(corePoint(noted), now: 100.05), "the drawn top row still claims")
        XCTAssertTrue(gate.containsVisibleSurface(band, now: 100 + VoiceBarPanelHitGate.settleDuration))
    }

    func testANoteLeavingStopsClaimingItsBandAtOnce() {
        let plain = layout(.init(mode: .recording), note: nil)
        let noted = layout(.init(mode: .recording), note: note)
        let band = noteBandPoint(noted)
        var gate = VoiceBarPanelHitGate(layout: noted)
        XCTAssertTrue(gate.containsVisibleSurface(band, now: 0))
        gate.update(to: plain, now: 10)
        for now in [10.0, 10.1, 10 + VoiceBarPanelHitGate.settleDuration] {
            XCTAssertFalse(gate.containsVisibleSurface(band, now: now), "t=\(now)")
        }
    }

    /// A note shown and cleared before the shell settles keeps every layout the shell may be drawn between.
    func testAChangeMidTransitionNeverWidensTheClaim() {
        let plain = layout(.init(mode: .recording), note: nil)
        let noted = layout(.init(mode: .recording), note: note)
        let band = noteBandPoint(noted)
        var gate = VoiceBarPanelHitGate(layout: plain)
        gate.update(to: noted, now: 0)
        gate.update(to: plain, now: 0.2)
        gate.update(to: noted, now: 0.3)
        XCTAssertFalse(gate.containsVisibleSurface(band, now: 0.4))
        XCTAssertTrue(gate.containsVisibleSurface(band, now: 0.3 + VoiceBarPanelHitGate.settleDuration))
    }

    /// The animation-progress check: every point the gate claims while settling is inside the shell as drawn at
    /// every sampled spring progress, entering and leaving, for every state a note can join.
    func testEveryClaimedPointIsDrawnAtEveryAnimationProgress() {
        for (name, input) in inputs {
            let plain = layout(input, note: nil)
            let noted = layout(input, note: note)
            XCTAssertEqual(plain.panelSize, noted.panelSize, name)
            for (direction, from, to) in [("enter", plain, noted), ("leave", noted, plain)] {
                var gate = VoiceBarPanelHitGate(layout: from)
                gate.update(to: to, now: 0)
                let frames = progressPoints.map { progress -> VoiceBarPanelLayout in
                    var delta = VoiceBarNotchGeometryAnimatableData(geometry: to.presentation.geometry)
                        - VoiceBarNotchGeometryAnimatableData(geometry: from.presentation.geometry)
                    delta.scale(by: Double(progress))
                    let geometry = (VoiceBarNotchGeometryAnimatableData(geometry: from.presentation.geometry) + delta)
                        .geometry
                    return VoiceBarPanelLayout.make(
                        presentation: to.presentation.drawn(at: geometry),
                        canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: to.presentation).canvasGeometry
                    )
                }
                var claimed = 0
                for x in stride(from: CGFloat(0.5), to: to.panelSize.width, by: 3) {
                    for y in stride(from: CGFloat(0.5), to: to.panelSize.height, by: 3) {
                        let point = CGPoint(x: x, y: y)
                        guard gate.containsVisibleSurface(point, now: 0.01) else { continue }
                        claimed += 1
                        for (index, frame) in frames.enumerated() where !frame.containsVisibleSurface(point) {
                            XCTFail("\(name) \(direction): \(point) claimed but not drawn at progress \(progressPoints[index])")
                            break
                        }
                    }
                }
                XCTAssertGreaterThan(claimed, 0, "\(name) \(direction): the drawn shell still claims clicks")
            }
        }
    }

    func testPlaybackControlsRemainInteractiveThroughoutSettling() {
        // Expanded PLAYING and compact HIDDEN, including a same-size note transition.
        var previouslyDroppedControlPoints = 0
        for expanded in [false, true] {
            var input = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true,
                                                     isTeleprompterDismissed: !expanded)
            func playbackLayout(note: String?) -> VoiceBarPanelLayout {
                input.transientNote = note
                let presentation = VoiceBarPresentation.notchPresentation(from: input)
                return VoiceBarPanelLayout.make(
                    presentation: presentation,
                    interactionConfiguration: .init(
                        leadingControlCount: 1,
                        trailingControlCountFromOuter: expanded ? 0 : 1,
                        trailingOuterInset: WaveformLayout.outerInset,
                        lowerControlCount: expanded ? 2 : 0,
                        lowerSurfaceIsInteractive: expanded
                    ),
                    canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: presentation).canvasGeometry
                )
            }
            func containsControl(_ layout: VoiceBarPanelLayout, _ point: CGPoint) -> Bool {
                VoiceBarNotchHitRegion(
                    geometry: layout.presentation.geometry,
                    configuration: .init(leadingControlCount: 1,
                                         trailingControlCountFromOuter: expanded ? 0 : 1,
                                         trailingOuterInset: WaveformLayout.outerInset,
                                         lowerControlCount: expanded ? 2 : 0)
                ).contains(CGPoint(x: point.x - layout.visibleContentRect.minX,
                                   y: point.y - layout.visibleContentRect.minY))
            }
            let plain = playbackLayout(note: nil)
            let noted = playbackLayout(note: note)
            for (from, to) in [(plain, noted), (noted, plain)] {
                var gate = VoiceBarPanelHitGate(layout: from)
                gate.update(to: to, now: 100)
                for x in stride(from: CGFloat(0.5), to: to.panelSize.width, by: 3) {
                    for y in stride(from: CGFloat(0.5), to: to.panelSize.height, by: 3) {
                        let point = CGPoint(x: x, y: y)
                        if containsControl(from, point) || containsControl(to, point) {
                            if (containsControl(from, point) || containsControl(to, point))
                                && (!from.containsVisibleSurface(point) || !to.containsVisibleSurface(point)) {
                                previouslyDroppedControlPoints += 1
                            }
                            XCTAssertTrue(gate.containsInteractiveContent(point, now: 100.05))
                            XCTAssertTrue(gate.containsMouseTrackingSurface(point, now: 100.05))
                        }
                        if !from.containsVisibleSurface(point) && !to.containsVisibleSurface(point)
                            && !from.containsInteractiveContent(point) && !to.containsInteractiveContent(point) {
                            XCTAssertFalse(gate.containsMouseTrackingSurface(point, now: 100.05))
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(previouslyDroppedControlPoints, 0,
                             "Fixture must reproduce the old window gate dropping actual playback interaction points")
    }

    func testTransparentBodyCornersPassThroughDuringAndAfterSettling() {
        let plain = layout(.init(mode: .speaking, hasTeleprompterText: true), note: nil)
        let noted = layout(.init(mode: .speaking, hasTeleprompterText: true), note: note)
        func interactive(_ base: VoiceBarPanelLayout) -> VoiceBarPanelLayout {
            .make(presentation: base.presentation,
                  interactionConfiguration: .init(lowerControlCount: 2, lowerSurfaceIsInteractive: true),
                  canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: base.presentation).canvasGeometry)
        }
        let destination = interactive(noted)
        var gate = VoiceBarPanelHitGate(layout: interactive(plain))
        gate.update(to: destination, now: 0)
        let corner = CGPoint(x: destination.visibleContentRect.minX + destination.presentation.geometry.bodyOriginX + 0.5,
                             y: destination.visibleContentRect.minY + 0.5)
        XCTAssertFalse(destination.containsVisibleSurface(corner))
        for now in [0.01, VoiceBarPanelHitGate.settleDuration + 0.01] {
            XCTAssertFalse(gate.containsMouseTrackingSurface(corner, now: now))
            XCTAssertFalse(gate.containsInteractiveContent(corner, now: now))
        }
    }

    func testRetentionHasAHardDeadlineAcrossRapidTransitionsAndClearsOnSettle() {
        let plain = layout(.init(mode: .recording), note: nil)
        let noted = layout(.init(mode: .recording), note: note)
        var gate = VoiceBarPanelHitGate(layout: plain)
        gate.update(to: noted, now: 0)
        for index in 1...40 {
            gate.update(to: index.isMultiple(of: 2) ? noted : plain, now: Double(index) * 0.01)
            XCTAssertLessThanOrEqual(gate.settlingFrom.count, 2, "duplicate layouts must not accumulate")
        }
        XCTAssertFalse(gate.isSettling(now: 0.501), "rapid transitions cannot extend the hard deadline")
        // An unchanged layout must still perform expiry and release stored regions.
        gate.update(to: gate.layout, now: 0.501)
        XCTAssertTrue(gate.settlingFrom.isEmpty)
        gate.update(to: gate.layout == plain ? noted : plain, now: 1)
        gate.update(to: gate.layout, now: 1 + VoiceBarPanelHitGate.settleDuration)
        XCTAssertTrue(gate.settlingFrom.isEmpty)
    }

    func testRemovedControlExpiresWhileCurrentPlaybackControlsRemainInteractive() {
        let plain = layout(.init(mode: .speaking, hasTeleprompterText: true), note: nil)
        let noted = layout(.init(mode: .speaking, hasTeleprompterText: true), note: note)
        func configured(_ base: VoiceBarPanelLayout, count: Int) -> VoiceBarPanelLayout {
            .make(presentation: base.presentation,
                  interactionConfiguration: .init(lowerControlCount: count),
                  canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: base.presentation).canvasGeometry)
        }
        let original = configured(plain, count: 3)
        var gate = VoiceBarPanelHitGate(layout: original)
        gate.update(to: configured(noted, count: 1), now: 0)
        let removed = CGPoint(x: original.visibleContentRect.midX - 36,
                              y: original.visibleContentRect.minY + 27)
        XCTAssertTrue(original.containsControl(removed))
        XCTAssertFalse(gate.layout.containsControl(removed))
        XCTAssertTrue(gate.containsInteractiveContent(removed, now: 0.01))
        for index in 1...40 {
            gate.update(to: configured(index.isMultiple(of: 2) ? noted : plain, count: 1),
                        now: Double(index) * 0.01)
        }
        XCTAssertFalse(gate.containsInteractiveContent(removed, now: 0.501))
        let current = CGPoint(x: gate.layout.visibleContentRect.midX,
                              y: gate.layout.visibleContentRect.minY + 27)
        XCTAssertTrue(gate.containsInteractiveContent(current, now: 0.501))
    }

    func testAWindowResizeAppliesTheDestinationAsBefore() {
        let recording = layout(.init(mode: .recording), note: nil)
        var teleprompter = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true)
        teleprompter.statusText = "Speaking…"
        let opened = layout(teleprompter, note: nil)
        XCTAssertNotEqual(recording.panelSize, opened.panelSize)
        var gate = VoiceBarPanelHitGate(layout: recording)
        gate.update(to: opened, now: 0)
        XCTAssertFalse(gate.isSettling(now: 0.01))
    }
}
