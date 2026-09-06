import CoreGraphics
import Foundation
@testable import VoiceBar
import XCTest

/// Regression tests for the keystroke-log bug: the CGEventTap callback logged
/// every event it saw, and the LaunchAgent routes stderr to a file, so VoiceBar
/// wrote down everything typed while it ran.
final class HotkeyDiagnosticsTests: XCTestCase {
    private var savedSink: ((String) -> Void)!
    private var savedVerbose: Bool!

    override func setUp() {
        super.setUp()
        savedSink = HotkeyDiagnostics.sink
        savedVerbose = HotkeyDiagnostics.isVerboseEnabled
    }

    override func tearDown() {
        HotkeyDiagnostics.sink = savedSink
        HotkeyDiagnostics.isVerboseEnabled = savedVerbose
        super.tearDown()
    }

    // MARK: - Helpers

    /// Runs `body` with the diagnostics sink captured, returning every line emitted.
    private func capturingDiagnostics(_ body: () -> Void) -> [String] {
        var lines: [String] = []
        HotkeyDiagnostics.sink = { lines.append($0) }
        body()
        return lines
    }

    /// Drives the real CGEventTap callback the way macOS does, so the test covers
    /// the actual production path rather than a hand-rolled stand-in.
    private func driveCallback(
        keycode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags = [],
        targetKeycodes: Set<Int64> = HotkeyManager.defaultTargetKeycodes
    ) {
        let context = TapContext(
            gesture: GestureStateMachine(),
            keycodes: targetKeycodes,
            mouseButtons: HotkeyManager.defaultTargetMouseButtons,
            enterMouseButtons: HotkeyManager.defaultEnterMouseButtons,
            modifierMode: HotkeyManager.defaultUsesModifierMode,
            onKeyDown: {},
            onKeyUp: {},
            onMouseDown: {},
            onMouseUp: {},
            onCancel: {},
            onPasteLastTranscript: {},
            shouldHandleEscape: { false }
        )
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .privateState),
            virtualKey: keycode,
            keyDown: keyDown
        ) else {
            XCTFail("could not synthesize a CGEvent for keycode \(keycode)")
            return
        }
        event.flags = flags
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        _ = hotkeyCallback(
            OpaquePointer(pointer),
            type: keyDown ? .keyDown : .keyUp,
            event: event,
            userInfo: pointer
        )
    }

    /// Keycodes for a plausible secret: "hunter2" plus the surrounding letters a
    /// password prompt would see. None of them is a VoiceBar hotkey.
    private static let nonHotkeyKeycodes: [CGKeyCode] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
        21, 22, 23, 24, 25, 26, 27, 28, 29, 31, 32, 33, 34, 35, 36, 37, 38, 39,
        40, 41, 42, 43, 44, 45, 46, 47, 49, 50, 51,
    ]

    // MARK: - The bug

    func testVerboseTapTracingIsOffByDefault() {
        XCTAssertFalse(
            HotkeyDiagnostics.isVerboseEnabled,
            "per-event tap tracing sees every keystroke — it must never default to on"
        )
    }

    func testAbsentUserDefaultsKeyLeavesVerboseTracingOff() throws {
        let suiteName = "com.voicelayer.tests.hotkey-diagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyDiagnostics.isVerboseEnabled = true
        HotkeyDiagnostics.loadVerboseSetting(defaults: defaults)

        XCTAssertFalse(HotkeyDiagnostics.isVerboseEnabled)
    }

    func testTapCallbackLogsNothingForOrdinaryTypingByDefault() {
        // Deliberately does NOT touch the switch: this is the shipped default,
        // the state every running VoiceBar is in.
        let lines = capturingDiagnostics {
            for keycode in Self.nonHotkeyKeycodes {
                driveCallback(keycode: keycode, keyDown: true)
                driveCallback(keycode: keycode, keyDown: false)
            }
        }

        XCTAssertEqual(
            lines, [],
            "VoiceBar must not write a line for keys the user did not aim at it — "
                + "that turns the LaunchAgent stderr file into a keystroke log"
        )
    }

    func testTapCallbackLogsNothingForModifiedNonHotkeyChords() {
        let lines = capturingDiagnostics {
            // Cmd+V, Cmd+Shift+A: the shape of a paste into a password field.
            driveCallback(keycode: 9, keyDown: true, flags: [.maskCommand])
            driveCallback(keycode: 9, keyDown: false, flags: [.maskCommand])
            driveCallback(keycode: 0, keyDown: true, flags: [.maskCommand, .maskShift])
        }

        XCTAssertEqual(lines, [])
    }

    // MARK: - Positive controls (so the assertions above cannot pass vacuously)

    func testMatchedHotkeyStillEmitsDiagnostics() {
        let lines = capturingDiagnostics {
            driveCallback(keycode: 96, keyDown: true)
            driveCallback(keycode: 96, keyDown: false)
        }

        XCTAssertTrue(
            lines.contains { $0.contains("Matched keycode 96") },
            "matched-hotkey diagnostics must survive the fix; got \(lines)"
        )
    }

    func testEnablingVerboseTracingRestoresPerEventLines() {
        HotkeyDiagnostics.isVerboseEnabled = true

        let lines = capturingDiagnostics {
            driveCallback(keycode: 8, keyDown: true)
        }

        XCTAssertTrue(
            lines.contains { $0.contains("Callback entry") },
            "the opt-in switch must actually re-enable per-event tracing; got \(lines)"
        )
    }

    // MARK: - Source-level guard

    /// The gate only holds while the tap path routes through `HotkeyDiagnostics`.
    /// A stray `NSLog` in `hotkeyCallback` or `hotkeyAction` would reintroduce the
    /// bug without failing any behavioural test, because it bypasses the sink.
    func testTapPathDoesNotCallNSLogDirectly() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VoiceBarTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // flow-bar/
            .appendingPathComponent("Sources/VoiceBar/HotkeyManager.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        let tapPath = try XCTUnwrap(
            text.range(of: "func hotkeyAction(").map { text[$0.lowerBound...] },
            "could not locate hotkeyAction() in HotkeyManager.swift"
        )
        let perEventRegion = try XCTUnwrap(
            tapPath.range(of: "// MARK: - Hotkey Manager").map { tapPath[..<$0.lowerBound] },
            "could not locate the end of the per-event tap path"
        )

        XCTAssertFalse(
            perEventRegion.contains("NSLog("),
            "the per-event tap path must log through HotkeyDiagnostics so the verbose gate applies"
        )
    }
}
