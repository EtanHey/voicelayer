@testable import VoiceBarUI
import XCTest

/// AIDEV-NOTE: The clipboard paste race Etan reported on 2026-09-09.
///
/// His words: *"the clipboard route has a race condition where sometimes
/// voicelayer would paste what I coppied instead of the transcript… and even
/// once I saw that it pasted the transcript plus last copied thing on the
/// clipboard."*
///
/// Mechanism: `VoiceState` snapshots the clipboard, writes the transcript,
/// synthesizes Cmd+V, then restores the snapshot after `pasteboardRestoreDelay`
/// (0.5 s). The only guard is `changeCount`, which proves nobody ELSE wrote to
/// the pasteboard. It proves nothing about whether the target app has READ it —
/// Cmd+V is delivered asynchronously to another process, which reads whenever it
/// gets around to it. A busy app, or a machine at 94-96 % swap, reads late.
///
/// Terminal targets take this path unconditionally (`TerminalPasteTargets`, for
/// the bracketed-paste reason documented there), and `com.cmuxterm.app` is where
/// he dictates — so his primary surface has no AX fallback to fall back to.
///
/// Existing paste tests all set `pasteScheduler = { _, block in block() }`, which
/// runs the restore inline and therefore never exercises the ordering at all.
/// These hold the restore block so the target app's read can be placed on either
/// side of it, which is the whole bug.
final class ClipboardPasteRaceTests: XCTestCase {
    /// Shape (a): the app reads AFTER the restore fires. He gets his old
    /// clipboard instead of the transcript.
    func testAppReadingAfterTheRestoreStillSeesTheTranscript() {
        let harness = PasteRaceHarness(previousClipboard: "PREVIOUS COPY")
        harness.deliver(transcript: "the transcript he dictated")

        harness.firePendingRestore() // no restore is scheduled any more
        let pasted = harness.targetAppReadsPasteboard()

        XCTAssertEqual(
            pasted,
            "the transcript he dictated",
            "the target app read the restored clipboard instead of the transcript"
        )
    }

    /// Shape (b): the app reads twice, once each side of the restore. The
    /// transcript and his old clipboard both land.
    func testTwoReadsStraddlingTheRestoreDoNotConcatenate() {
        let harness = PasteRaceHarness(previousClipboard: "PREVIOUS COPY")
        harness.deliver(transcript: "the transcript he dictated")

        // Sanity: the transcript must actually be on the pasteboard before the
        // restore fires, or this test would be asserting the wrong mechanism.
        XCTAssertEqual(
            harness.targetAppReadsPasteboard(),
            "the transcript he dictated",
            "precondition: the transcript is on the pasteboard after delivery"
        )

        let first = harness.targetAppReadsPasteboard()
        harness.firePendingRestore()
        let second = harness.targetAppReadsPasteboard()

        XCTAssertEqual(
            first + second,
            "the transcript he dictated" + "the transcript he dictated",
            "a second read saw something other than the transcript"
        )
    }
}

/// Drives the REAL `VoiceState` paste flow with a held restore block, so the
/// ordering between the restore and the target app's read is the subject.
private final class PasteRaceHarness {
    private let state = VoiceState()
    private var pasteboardString: String?
    private var changeCount = 1
    private var pendingRestore: (() -> Void)?

    init(previousClipboard: String) {
        pasteboardString = previousClipboard
        let terminal = TerminalRunningApplication()
        state.sendCommand = { _ in }
        state.minimumTranscribingDisplayDuration = 0
        state.pasteConfirmationDelay = 0
        state.frontmostAppProvider = { terminal }
        state.targetAppActivator = { _ in }
        // Run the flow's own scheduled steps inline (confirmation delay is 0),
        // but HOLD the clipboard restore, which is the only one scheduled at a
        // non-zero delay (`pasteboardRestoreDelay`, 0.5 s). That ordering is
        // what every existing paste test collapses away by running everything
        // inline — and it is the entire bug.
        state.pasteScheduler = { [weak self] delay, block in
            if delay > 0 {
                self?.pendingRestore = block
            } else {
                block()
            }
        }
        // A real pasteboard: writes bump the change count, and the snapshot /
        // restore pair moves the same string the live code moves. Without this
        // the restore silently no-ops on a changeCount mismatch and the test
        // passes for a reason that has nothing to do with the race.
        state.pasteboardWriter = { [weak self] text in
            self?.pasteboardString = text
            self?.changeCount += 1
        }
        state.pasteboardStringProvider = { [weak self] in self?.pasteboardString }
        state.pasteboardChangeCountProvider = { [weak self] in self?.changeCount ?? 0 }
        state.pasteboardSnapshotter = { [weak self] in
            guard let self else { return nil }
            return PasteboardSnapshot(
                changeCount: changeCount,
                items: [["public.utf8-plain-text": Data((pasteboardString ?? "").utf8)]]
            )
        }
        state.pasteboardSnapshotRestorer = { [weak self] snapshot in
            guard let data = snapshot.items.first?["public.utf8-plain-text"] else { return }
            self?.pasteboardString = String(decoding: data, as: UTF8.self)
            self?.changeCount += 1
        }
        state.simulatedPasteHandler = { true }
    }

    func deliver(transcript: String) {
        state.record()
        state.handleEvent(["type": "state", "state": "transcribing"])
        state.handleEvent(["type": "transcription", "text": transcript])
    }

    func firePendingRestore() {
        pendingRestore?()
        pendingRestore = nil
    }

    /// The target app consuming the pasteboard, whenever it gets around to it.
    func targetAppReadsPasteboard() -> String {
        pasteboardString ?? ""
    }
}

private final class TerminalRunningApplication: NSRunningApplication, @unchecked Sendable {
    override var bundleIdentifier: String? {
        "com.cmuxterm.app"
    }

    override var processIdentifier: pid_t {
        4242
    }
}
