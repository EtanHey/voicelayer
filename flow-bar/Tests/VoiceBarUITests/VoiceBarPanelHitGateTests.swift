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
        teleprompter.statusText = "Speaking..."
        var history = VoiceBarNotchOperationalInput(mode: .idle)
        history.isHistoryPanelOpen = true
        return [
            ("recording", .init(mode: .recording)),
            ("recording + hold", .init(mode: .recording, showsRecordingHold: true)),
            ("transcribing", .init(mode: .transcribing, statusText: "Transcribing...")),
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

    func testAWindowResizeAppliesTheDestinationAsBefore() {
        let recording = layout(.init(mode: .recording), note: nil)
        var teleprompter = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true)
        teleprompter.statusText = "Speaking..."
        let opened = layout(teleprompter, note: nil)
        XCTAssertNotEqual(recording.panelSize, opened.panelSize)
        var gate = VoiceBarPanelHitGate(layout: recording)
        gate.update(to: opened, now: 0)
        XCTAssertFalse(gate.isSettling(now: 0.01))
    }
}
