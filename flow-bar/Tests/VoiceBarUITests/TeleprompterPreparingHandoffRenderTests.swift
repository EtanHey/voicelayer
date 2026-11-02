import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// R2-04 on the real view (review round 2): the production `BarView`, driven by the daemon's own speaking events,
/// sampled every few milliseconds through the handoff. Offscreen, `cacheDisplay` draws the model layer tree (the
/// end state from the first frame) and `render(in:)` draws nothing for SwiftUI's layers, so the sampler reads what
/// Core Animation draws: each content layer's presentation opacity, multiplied up its ancestors. "Preparing
/// speech…" is centred in the teleprompter body; the reading text starts at its leading edge, so the two are told
/// apart by column. No sample may show both, in either direction or when a new read reverses the handoff before
/// the text's entrance delay, and the end state must show the current content only (no stale text). This caught
/// the real overlap: 30 ms into preparing -> text the status was at 0.65 and the text already at 1.00.
@MainActor
final class TeleprompterPreparingHandoffRenderTests: XCTestCase {
    private final class Router: BarCommandRouting {
        func handlePrimaryTap() {}
        func handleCancel() {}
        func handleStop() {}
        func handleReplay() {}
        func handleRetranscribeHistoryEntry(recordingPath _: String) {}
    }

    private struct Sample {
        let elapsed: TimeInterval
        let status: Int
        let text: Int
    }

    private final class Rig {
        let state: VoiceState
        let host: NSHostingView<AnyView>
        let window: NSWindow
        let scale: CGFloat
        let statusRect: CGRect
        let textRect: CGRect

        init(state: VoiceState, host: NSHostingView<AnyView>, window: NSWindow, scale: CGFloat,
             statusRect: CGRect, textRect: CGRect) {
            self.state = state
            self.host = host
            self.window = window
            self.scale = scale
            self.statusRect = statusRect
            self.textRect = textRect
        }
    }

    private func preparing(_ id: String) -> [String: Any] {
        ["type": "state", "state": "speaking", "text": "Preparing speech…",
         "long_read": ["id": id, "chunk_start_ms": 0, "preparing": true]]
    }

    /// The first chunk: one short word, so its ink stays at the body's leading edge, clear of the centred status.
    private func firstChunk(_ id: String, _ word: String) -> [String: Any] {
        ["type": "state", "state": "speaking", "text": word,
         "long_read": ["id": id, "chunk_start_ms": 0]]
    }

    private func makeRig() throws -> Rig {
        let state = VoiceState(playbackAmplitudeClock: { 100 })
        state.isConnected = true
        state.isCollapsed = false
        state.sendCommand = { _ in }
        state.handleEvent(preparing("r1"))
        XCTAssertTrue(state.isPreparingSpeech)
        let model = VoiceBarNotchPresentationModel()
        model.updateOperationalEnvelope(hasTeleprompter: true, isRecording: false, hasCompactStatus: false)
        let canvas = VoiceBarNotchMorphCanvasLayout.resolve(for: model.presentation).canvasGeometry
        let size = CGSize(width: canvas.totalWidth + 24, height: canvas.totalHeight + 17)
        let host = NSHostingView(rootView: AnyView(
            BarView(state: state, commandRouter: Router(), onOpenSettings: {}, onOpenHistory: {},
                    presentationModel: model, includesPanelOutsets: true)
                .environment(\.colorScheme, .dark)
        ))
        host.appearance = NSAppearance(named: .darkAqua)
        host.wantsLayer = true
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let geometry = model.presentation.geometry
        let mid = size.width / 2
        let top = geometry.topHeight + 8
        let height = Theme.teleprompterViewportHeight + 8
        // Centred status column and the body's leading column (the body is 465 pt wide at a 185 pt core).
        let statusRect = CGRect(x: mid - 70, y: top, width: 140, height: height)
        let textRect = CGRect(x: mid - geometry.bodyWidth / 2, y: top, width: geometry.bodyWidth / 2 - 110,
                              height: height)
        return Rig(state: state, host: host, window: window, scale: 2, statusRect: statusRect, textRect: textRect)
    }

    /// The strongest drawn content in each column now: presentation opacity of every layer with drawn contents,
    /// times its ancestors' (0 when hidden), keyed by where the layer sits in the host.
    private func luminance(_ rig: Rig) throws -> (status: Int, text: Int) {
        let root = try XCTUnwrap(rig.host.layer)
        var status: Float = 0, text: Float = 0
        func walk(_ layer: CALayer, _ alpha: Float) {
            let shown = layer.presentation() ?? layer
            let effective = shown.isHidden ? 0 : alpha * shown.opacity
            guard effective > 0 else { return }
            if layer.contents != nil {
                let frame = layer.convert(layer.bounds, to: root)
                let flipped = rig.host.isFlipped ? frame
                    : CGRect(x: frame.minX, y: rig.host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                let centre = CGPoint(x: flipped.midX, y: flipped.midY)
                if flipped.width < 300 {
                    if rig.statusRect.contains(centre) { status = max(status, effective) }
                    if rig.textRect.contains(centre) { text = max(text, effective) }
                }
            }
            for child in layer.sublayers ?? [] { walk(child, effective) }
        }
        walk(root, 1)
        return (Int((status * 255).rounded()), Int((text * 255).rounded()))
    }

    /// Applies `events` at their offsets (seconds) and samples the rendered view as fast as it renders.
    private func run(_ rig: Rig, events: [(TimeInterval, [String: Any])], for duration: TimeInterval) throws -> [Sample] {
        var samples: [Sample] = []
        var pending = events
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            while let next = pending.first, next.0 <= elapsed {
                rig.state.handleEvent(next.1)
                pending.removeFirst()
            }
            let (status, text) = try luminance(rig)
            samples.append(Sample(elapsed: elapsed, status: status, text: text))
            if elapsed > duration, pending.isEmpty { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
        }
        return samples
    }

    private func assertNoOverlap(_ name: String, _ samples: [Sample], baseline: (status: Int, text: Int),
                                 file: StaticString = #filePath, line: UInt = #line) {
        let statusInk = baseline.status + 2, textInk = baseline.text + 2
        for sample in samples where sample.status > statusInk && sample.text > textInk {
            XCTFail("\(name): status and text drawn together at \(Int(sample.elapsed * 1000)) ms "
                    + "(status \(sample.status), text \(sample.text); ink above \(statusInk)/\(textInk))",
                    file: file, line: line)
        }
    }

    func testTheRealViewNeverDrawsTheStatusAndTheTextTogether() throws {
        let rig = try makeRig()
        defer { rig.window.close() }
        // Preparing at rest: the status is drawn, the leading column is empty glass.
        let preparingAtRest = try luminance(rig)

        // 1. Preparing -> first chunk.
        let toText = try run(rig, events: [(0, firstChunk("r1", "Go"))], for: 0.6)
        XCTAssertFalse(rig.state.isPreparingSpeech)
        let textAtRest = try luminance(rig)
        let baseline = (status: textAtRest.status, text: preparingAtRest.text)
        XCTAssertEqual(baseline.status, 0, "no status once the text reads")
        XCTAssertEqual(baseline.text, 0, "no text while preparing")
        XCTAssertGreaterThan(preparingAtRest.status, 200, "the status is visible while preparing")
        XCTAssertGreaterThan(textAtRest.text, 200, "the text is visible once it reads")
        assertNoOverlap("preparing -> text", toText, baseline: baseline)

        // 2. A new read: text -> preparing.
        let toPreparing = try run(rig, events: [(0, preparing("r2"))], for: 0.6)
        assertNoOverlap("text -> preparing", toPreparing, baseline: baseline)
        let preparingAgain = try luminance(rig)
        XCTAssertGreaterThan(preparingAgain.status, 200, "final frame: the status")
        XCTAssertEqual(preparingAgain.text, 0, "final frame: no stale text")

        // 3. Reversal before the text's entrance delay: preparing -> text -> preparing (a newer read).
        let delay = TeleprompterPreparingHandoff.enterDelay
        let reversal = try run(rig, events: [(0, firstChunk("r2", "Go")), (delay / 2, preparing("r3"))], for: 0.6)
        assertNoOverlap("preparing -> text -> preparing", reversal, baseline: baseline)
        let final = try luminance(rig)
        XCTAssertTrue(rig.state.isPreparingSpeech)
        XCTAssertGreaterThan(final.status, 200, "final frame after the reversal: the status")
        XCTAssertEqual(final.text, 0, "final frame after the reversal: no stale text")

        // The sampler must actually see the handoff move, or the no-overlap result would mean nothing.
        let all = toText + toPreparing + reversal
        let partial = all.filter {
            ($0.status > 2 && $0.status < preparingAtRest.status - 2)
                || ($0.text > 2 && $0.text < textAtRest.text - 2)
        }
        XCTAssertFalse(partial.isEmpty, "no intermediate frame was captured; the sampler cannot see the transition")
        XCTAssertGreaterThan(all.count, 100)
    }
}
