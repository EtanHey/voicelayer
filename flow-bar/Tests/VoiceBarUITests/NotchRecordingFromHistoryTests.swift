import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// R0856-05 (walkthrough 2026-11-02 08:56, 37.2 -> 37.5 s): recording started with History open. The wing had
/// already switched to Stop + Cancel while the shell still held History's geometry: the empty slab stayed and the
/// red Stop was clipped by the old, narrower wing. The shell waited out the content-exit delay because its body
/// was shrinking, though its wing had to grow. These replay the shell's own spring frame by frame.
final class NotchRecordingFromHistoryTests: XCTestCase {
    private let frame: TimeInterval = 1.0 / 120

    private func geometry(_ input: VoiceBarNotchOperationalInput) -> VoiceBarNotchGeometry {
        VoiceBarPresentation.notchPresentation(from: input).geometry
    }

    private var history: VoiceBarNotchGeometry {
        var input = VoiceBarNotchOperationalInput(mode: .idle)
        input.isHistoryPanelOpen = true
        return geometry(input)
    }

    /// Progress of `.interpolatingSpring(mass:stiffness:damping:)` from 0 to 1, integrated finely.
    private func springProgress(at time: TimeInterval) -> CGFloat {
        let motion = VoiceBarNotchContract.motion
        var x = 0.0, v = 0.0, t = 0.0
        let dt = 0.0001
        while t < time {
            let a = (-motion.stiffness * (x - 1) - motion.damping * v) / motion.mass
            v += a * dt
            x += v * dt
            t += dt
        }
        return CGFloat(x)
    }

    private func interpolate(_ from: VoiceBarNotchGeometry, _ to: VoiceBarNotchGeometry,
                             _ progress: CGFloat) -> VoiceBarNotchGeometry {
        var delta = VoiceBarNotchGeometryAnimatableData(geometry: to) - VoiceBarNotchGeometryAnimatableData(geometry: from)
        delta.scale(by: Double(progress))
        return (VoiceBarNotchGeometryAnimatableData(geometry: from) + delta).geometry
    }

    func testAGrowingWingNeverWaitsForTheBodyToEmpty() {
        // 2.3 U2: History and recording share the fixed 73.5 pt left wing, so Stop + Cancel never outgrow it; only
        // an Ask's hold lock (a third control) still grows the wing.
        XCTAssertEqual(geometry(.init(mode: .recording)).leadingWingWidth, history.leadingWingWidth)
        let recording = geometry(.init(mode: .recording, showsRecordingHold: true))
        XCTAssertGreaterThan(recording.leadingWingWidth, history.leadingWingWidth)
        let transition = VoiceBarNotchShellTransition.resolve(from: history, to: recording, visualState: .recording)
        XCTAssertEqual(transition.delay, 0, "the slab shrinks and the wing grows from the first frame")
        // A shrinking body whose wings do not grow still lets its content fade first.
        let launcher = geometry(.init(mode: .idle, isHovered: true))
        XCTAssertEqual(VoiceBarNotchShellTransition.resolve(from: history, to: launcher, visualState: .hoverLauncher).delay,
                       VoiceBarNotchContract.motion.contentExitDuration)
    }

    /// On every frame the entering Stop + Cancel (and the hold control) are drawn, they sit inside the glass.
    func testEnteringRecordingControlsAreNeverClippedByTheOldWing() {
        let material = VoiceBarNotchContract.material
        for (hold, controls) in [(false, 2), (true, 3)] {
            let recording = geometry(.init(mode: .recording, showsRecordingHold: hold))
            for start in [history, geometry(.init(mode: .idle, isHovered: true))] {
                let delay = VoiceBarNotchShellTransition.resolve(from: start, to: recording, visualState: .recording).delay
                var drawnFrames = 0
                for index in 0 ... 60 {
                    let elapsed = Double(index) * frame
                    let growth = recording.leadingWingWidth - start.leadingWingWidth
                    guard VoiceBarNotchWingContentEntry.isVisible(elapsed: elapsed, growth: growth) else { continue }
                    drawnFrames += 1
                    let progress = springProgress(at: max(0, elapsed - delay))
                    let shell = interpolate(start, recording, progress)
                    let layout = VoiceBarNotchShapeLayout(geometry: shell)
                    let radius = 15.0 // hoverLauncher, history and recording share the compact corner
                    let shoulder = material.bodyShoulderCornerRadius(for: .history)
                        + (material.bodyShoulderCornerRadius(for: .recording) - material.bodyShoulderCornerRadius(for: .history))
                        * progress
                    let path = VoiceBarNotchContinuousShape(geometry: shell, compactOuterCornerRadius: radius,
                                                            bodyShoulderCornerRadius: shoulder)
                        .path(in: CGRect(origin: .zero, size: layout.totalSize))
                    // Two placements, both checked: the slot already at the recording width (what the walkthrough
                    // frame shows: controls at their final place against the old glass), and the slot following the
                    // animated wing, its content centred in the padded slot.
                    let wing = layout.leadingWingRect
                    let contentWidth = CGFloat(controls) * material.compactControlSize
                        + CGFloat(controls - 1) * material.compactControlSpacing
                    let padded = wing.width - material.compactContentInset - VoiceBarNotchContract.compactCoreContentInset
                    let animatedMinX = wing.minX + material.compactContentInset + (padded - contentWidth) / 2
                    let targetMinX = shell.coreOriginX - recording.leadingWingWidth + material.compactContentInset
                    for minX in [animatedMinX, targetMinX] {
                        let top = (wing.height - material.compactControlSize) / 2
                        // The outer side is what the old wing clips; the core side sits on the housing.
                        for probe in [CGPoint(x: minX + 1, y: top + 1), CGPoint(x: minX + 1, y: top + material.compactControlSize - 1),
                                      CGPoint(x: minX + 1, y: top + material.compactControlSize / 2)] {
                            XCTAssertTrue(path.contains(probe),
                                          "hold \(hold), frame \(index) (\(Int(elapsed * 1000)) ms): control at \(probe) "
                                          + "outside the wing \(wing) at progress \(progress)")
                        }
                    }
                }
                XCTAssertGreaterThan(drawnFrames, 30)
                XCTAssertLessThanOrEqual(VoiceBarNotchWingContentEntry.delay(forGrowth: recording.leadingWingWidth
                    - start.leadingWingWidth) + VoiceBarNotchWingContentEntry.duration, 0.3, "under 300 ms in all")
            }
        }
    }

    /// The old timing, replayed: the content appeared at once and the shell waited 0.12 s.
    func testTheOldTimingClippedTheStopButton() {
        // 2.3 U2: only the hold lock still widens the wing, so the witness replays that case.
        let recording = geometry(.init(mode: .recording, showsRecordingHold: true))
        let shell = interpolate(history, recording, springProgress(at: 0)) // still waiting out the delay
        let layout = VoiceBarNotchShapeLayout(geometry: shell)
        let path = VoiceBarNotchContinuousShape(geometry: shell, compactOuterCornerRadius: 15,
                                                bodyShoulderCornerRadius: 15)
            .path(in: CGRect(origin: .zero, size: layout.totalSize))
        let material = VoiceBarNotchContract.material
        // The recording controls already at their final place (walkthrough frame, 37.5 s).
        let minX = shell.coreOriginX - recording.leadingWingWidth + material.compactContentInset
        XCTAssertFalse(path.contains(CGPoint(x: minX + 1, y: shell.topHeight / 2)),
                       "regression witness: the outer control sat outside the narrower old wing")
    }
}
