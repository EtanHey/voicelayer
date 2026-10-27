import CoreGraphics
@testable import VoiceBarUI
import XCTest

/// NOTCH2: Etan saw the busy note's notch clipped "when the animation is leaving, or when the animation is on
/// its other side". These sample the shell animation at many progress points and require the shell and the note
/// to stay inside the window and the reveal mask at every one of them.
final class NotchNoteMorphGeometryTests: XCTestCase {
    private let note = "Busy recording. Selection not read"
    private let progressPoints: [CGFloat] = stride(from: 0, through: 1, by: 0.05).map { CGFloat($0) }

    private var inputs: [(String, VoiceBarNotchOperationalInput)] {
        var teleprompter = VoiceBarNotchOperationalInput(mode: .speaking, hasTeleprompterText: true)
        teleprompter.statusText = "Speaking…"
        var history = VoiceBarNotchOperationalInput(mode: .idle)
        history.isHistoryPanelOpen = true
        return [
            ("recording", .init(mode: .recording)),
            ("recording + hold", .init(mode: .recording, showsRecordingHold: true)),
            ("transcribing", .init(mode: .transcribing, statusText: "Transcribing…")),
            ("F5 preview", .init(mode: .idle, hotkeyPhase: .pressing, statusText: "Hold to talk")),
            ("teleprompter", teleprompter),
            ("launcher", .init(mode: .idle, isHovered: true)),
            ("history", history),
        ]
    }

    private func presentation(_ input: VoiceBarNotchOperationalInput, note: String?) -> VoiceBarNotchPresentation {
        var input = input
        input.transientNote = note
        return VoiceBarPresentation.notchPresentation(from: input)
    }

    private func interpolate(
        _ from: VoiceBarNotchGeometry, _ to: VoiceBarNotchGeometry, _ progress: CGFloat
    ) -> VoiceBarNotchGeometry {
        var delta = VoiceBarNotchGeometryAnimatableData(geometry: to) - VoiceBarNotchGeometryAnimatableData(geometry: from)
        delta.scale(by: Double(progress))
        return (VoiceBarNotchGeometryAnimatableData(geometry: from) + delta).geometry
    }

    /// One frame, laid out the way `VoiceBarNotchView` draws it: the shell offset so its core sits on the
    /// canvas core, the reveal mask from `VoiceBarNotchCoreAnchoredRevealLayout` at the same spring progress.
    private func assertFrame(
        _ label: String,
        shell geometry: VoiceBarNotchGeometry,
        noteBand: Bool,
        canvas: VoiceBarNotchGeometry,
        revealProgress: CGFloat
    ) {
        let canvasRect = CGRect(x: 0, y: 0, width: canvas.totalWidth, height: canvas.totalHeight)
        let originX = canvas.coreOriginX - geometry.coreOriginX
        let shellRect = CGRect(x: originX, y: 0, width: geometry.totalWidth, height: geometry.totalHeight)
        let mask = VoiceBarNotchCoreAnchoredRevealLayout.rect(
            progress: revealProgress,
            in: canvasRect,
            coreRect: CGRect(x: canvas.coreOriginX, y: 0, width: canvas.coreWidth, height: canvas.topHeight)
        )
        XCTAssertTrue(canvasRect.contains(shellRect), "\(label): shell \(shellRect) ⊄ window \(canvasRect)")
        // The wings are drawn around the core; they must stay inside the shell's own frame, or the far wing
        // overhangs it and is cut flat.
        XCTAssertGreaterThanOrEqual(geometry.topOriginX, -0.001, "\(label): the leading wing overhangs the shell")
        XCTAssertLessThanOrEqual(geometry.topOriginX + geometry.topWidth, geometry.totalWidth + 0.001,
                                 "\(label): the trailing wing overhangs the shell")
        XCTAssertLessThanOrEqual(
            shellRect.maxY + VoiceBarNotchContract.transientNoteClearance, canvasRect.maxY + 0.001,
            "\(label): the shell's lower curve sits on the window edge"
        )
        XCTAssertTrue(mask.insetBy(dx: -0.001, dy: -0.001).contains(shellRect), "\(label): mask \(mask) cuts the shell \(shellRect)")
        guard noteBand else { return }
        let noteRect = CGRect(
            x: originX + geometry.bodyOriginX,
            y: geometry.topHeight,
            width: geometry.bodyWidth,
            height: VoiceBarNotchContract.transientNoteBandHeight
        )
        XCTAssertTrue(canvasRect.contains(noteRect), "\(label): note \(noteRect) ⊄ window \(canvasRect)")
        XCTAssertTrue(mask.insetBy(dx: -0.001, dy: -0.001).contains(noteRect), "\(label): mask cuts the note")
    }

    func testTheNoteNeverResizesTheWindow() {
        for (name, input) in inputs {
            let plain = presentation(input, note: nil)
            let noted = presentation(input, note: note)
            XCTAssertEqual(
                VoiceBarNotchMorphCanvasLayout.resolve(for: plain).canvasGeometry,
                VoiceBarNotchMorphCanvasLayout.resolve(for: noted).canvasGeometry,
                "\(name): AppKit would resize the panel under the animating shell"
            )
            XCTAssertEqual(
                VoiceBarPanelLayout.make(
                    presentation: plain,
                    canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: plain).canvasGeometry
                ).panelSize,
                VoiceBarPanelLayout.make(
                    presentation: noted,
                    canvasGeometry: VoiceBarNotchMorphCanvasLayout.resolve(for: noted).canvasGeometry
                ).panelSize,
                name
            )
        }
    }

    func testNoteEnterAndLeaveStayInsideTheWindowAndMaskAtEveryFrame() {
        for (name, input) in inputs {
            let plain = presentation(input, note: nil)
            let noted = presentation(input, note: note)
            for (direction, from, to) in [("enter", plain, noted), ("leave", noted, plain)] {
                // The window commits the destination size before the shell finishes; test both canvases.
                for canvasSource in [from, to] {
                    let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: canvasSource).canvasGeometry
                    for progress in progressPoints {
                        assertFrame(
                            "\(name) \(direction) @\(progress)",
                            shell: interpolate(from.geometry, to.geometry, progress),
                            noteBand: true,
                            canvas: canvas,
                            revealProgress: 1
                        )
                    }
                }
            }
        }
    }

    /// The far-wing cut: from a collapsed notch the mask and the shell open on one spring, so at every shared
    /// progress the mask is outside the shell on both wings.
    func testOpeningFromIdleWithANoteKeepsTheMaskOutsideTheShell() {
        let idle = VoiceBarPresentation.notchPresentation(from: .init(mode: .idle, isCollapsed: true))
        XCTAssertEqual(idle.visualState, .idle)
        for (name, input) in inputs {
            let noted = presentation(input, note: note)
            let transition = VoiceBarNotchShellTransition.resolve(
                from: idle.geometry, to: noted.geometry, visualState: noted.visualState
            )
            XCTAssertEqual(transition.delay, 0, "\(name): opening never waits")
            XCTAssertEqual(transition.revealProgress, 1, name)
            let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: noted).canvasGeometry
            for progress in progressPoints {
                assertFrame(
                    "\(name) open @\(progress)",
                    shell: interpolate(idle.geometry, noted.geometry, progress),
                    noteBand: false,
                    canvas: canvas,
                    revealProgress: progress * transition.revealProgress
                )
            }
        }
    }

    /// On leave the note fades first, then the shell eases up: the shell's delay covers the note's fade.
    func testTheShellWaitsForTheNoteToFadeBeforeItCloses() {
        for (name, input) in inputs {
            let plain = presentation(input, note: nil)
            let noted = presentation(input, note: note)
            let leave = VoiceBarNotchShellTransition.resolve(
                from: noted.geometry, to: plain.geometry, visualState: plain.visualState
            )
            XCTAssertGreaterThanOrEqual(leave.delay, VoiceBarNotchContract.motion.contentExitDuration, name)
            XCTAssertEqual(leave.revealProgress, 1, "\(name): the mask stays open while a visible shell shrinks")
            let enter = VoiceBarNotchShellTransition.resolve(
                from: plain.geometry, to: noted.geometry, visualState: noted.visualState
            )
            XCTAssertEqual(enter.delay, 0, name)
        }
    }
}
