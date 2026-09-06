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

    private func driveMouseCallback(buttonNumber: Int64, mouseDown: Bool) {
        let context = TapContext(
            gesture: GestureStateMachine(),
            keycodes: HotkeyManager.defaultTargetKeycodes,
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
            mouseEventSource: CGEventSource(stateID: .privateState),
            mouseType: mouseDown ? .otherMouseDown : .otherMouseUp,
            mouseCursorPosition: .zero,
            mouseButton: .center
        ) else {
            XCTFail("could not synthesize a mouse CGEvent for button \(buttonNumber)")
            return
        }
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        _ = hotkeyCallback(
            OpaquePointer(pointer),
            type: mouseDown ? .otherMouseDown : .otherMouseUp,
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

    /// The switch is only useful if the defaults key actually reaches it — the
    /// test above sets the flag directly, which would still pass if
    /// `loadVerboseSetting` read the wrong key or ignored `true`.
    func testUserDefaultsKeySetTrueTurnsPerEventTracingBackOn() throws {
        let suiteName = "com.voicelayer.tests.hotkey-diagnostics.on.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: HotkeyDiagnostics.verboseLoggingDefaultsKey)

        HotkeyDiagnostics.isVerboseEnabled = false
        HotkeyDiagnostics.loadVerboseSetting(defaults: defaults)

        XCTAssertTrue(HotkeyDiagnostics.isVerboseEnabled)

        let lines = capturingDiagnostics {
            driveCallback(keycode: 8, keyDown: true)
        }
        XCTAssertTrue(
            lines.contains { $0.contains("Callback entry") },
            "loading the key as true must restore per-event tracing; got \(lines)"
        )
    }

    func testTapCallbackLogsNothingForOrdinaryMouseButtonsByDefault() {
        let lines = capturingDiagnostics {
            driveMouseCallback(buttonNumber: 2, mouseDown: true)
            driveMouseCallback(buttonNumber: 2, mouseDown: false)
        }

        XCTAssertEqual(
            lines, [],
            "non-hotkey mouse buttons must not write a per-event line by default"
        )
    }

    func testMatchedMouseHotkeyStillEmitsDiagnostics() {
        let lines = capturingDiagnostics {
            driveMouseCallback(buttonNumber: 4, mouseDown: true)
        }

        XCTAssertTrue(
            lines.contains { $0.contains("Matched mouse button 4") },
            "matched-mouse diagnostics must survive the fix; got \(lines)"
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

        XCTAssertTrue(text.contains("func hotkeyCallback("), "hotkeyCallback() missing from HotkeyManager.swift")
        XCTAssertTrue(text.contains("func hotkeyAction("), "hotkeyAction() missing from HotkeyManager.swift")

        func body(of function: String) throws -> Substring {
            let header = "func \(function)("
            let fromHeader = try XCTUnwrap(
                text.range(of: header).map { text[$0.lowerBound...] },
                "could not locate \(function)() in HotkeyManager.swift"
            )
            let nextMark = fromHeader.range(of: "\nfunc ") ?? fromHeader.range(of: "\n// MARK:")
            if let nextMark {
                return fromHeader[..<nextMark.lowerBound]
            }
            return fromHeader
        }

        for function in ["hotkeyCallback", "hotkeyAction", "mouseHotkeyAction", "sequenceAwareHotkeyAction"] {
            let region = try body(of: function)
            XCTAssertFalse(
                region.contains("NSLog("),
                "\(function) must log through HotkeyDiagnostics so the verbose gate applies"
            )
        }
    }
}
