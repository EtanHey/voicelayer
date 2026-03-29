// HotkeyManager.swift — Global hotkey detection via CGEventTap.
//
// Uses .listenOnly tap (Input Monitoring permission) with Right Command
// as the default hotkey. App Store compatible. No event consumption needed
// because Right Command alone has no system side-effect.
//
// Gesture state machine: hold (250ms) = push-to-talk, double-tap (400ms) = toggle.
//
// AIDEV-NOTE: Based on R02 research (macOS Sequoia CGEventTap guide).
// Right Command (keycode 54) is the recommended default — zero system conflicts,
// works with .listenOnly, App Store viable. F4 (keycodes 118+129) as alternative.

import CoreGraphics
import Foundation

// MARK: - Gesture State Machine

/// Detects hold vs tap vs double-tap from raw key events.
/// - Hold (250ms+): push-to-talk recording
/// - Single tap: toggle recording on/off
/// - Double-tap (within 400ms): reserved for future use
final class GestureStateMachine {
    enum State: Sendable {
        case idle
        case waitingForHoldThreshold // keyDown received, 250ms timer running
        case holding // threshold exceeded, recording active
        case waitingForDoubleTap // first tap released, 400ms timer running
    }

    private(set) var state: State = .idle
    private var holdTimer: DispatchWorkItem?
    private var doubleTapTimer: DispatchWorkItem?

    static let holdThresholdMs: Int = 250
    static let doubleTapWindowMs: Int = 400

    // Callbacks — set by the owner (AppDelegate)
    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}
    var onSingleTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}

    func handleKeyDown() {
        switch state {
        case .waitingForDoubleTap:
            doubleTapTimer?.cancel()
            state = .idle
            onDoubleTap()
        case .idle:
            state = .waitingForHoldThreshold
            let timer = DispatchWorkItem { [weak self] in
                guard let self, state == .waitingForHoldThreshold else { return }
                state = .holding
                onHoldStart()
            }
            holdTimer = timer
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Self.holdThresholdMs),
                execute: timer
            )
        default:
            break
        }
    }

    func handleKeyUp() {
        switch state {
        case .waitingForHoldThreshold:
            holdTimer?.cancel()
            state = .waitingForDoubleTap
            let timer = DispatchWorkItem { [weak self] in
                guard let self, state == .waitingForDoubleTap else { return }
                state = .idle
                onSingleTap()
            }
            doubleTapTimer = timer
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Self.doubleTapWindowMs),
                execute: timer
            )
        case .holding:
            state = .idle
            onHoldEnd()
        default:
            break
        }
    }

    /// Reset state (e.g., on permission changes).
    func reset() {
        holdTimer?.cancel()
        doubleTapTimer?.cancel()
        state = .idle
    }
}

// MARK: - Tap Context (passed through userInfo)

/// Holds configuration and gesture reference for the C callback.
/// Must be kept alive for the duration of the event tap.
private final class TapContext {
    let gesture: GestureStateMachine
    let targetKeycodes: Set<Int64>
    let useModifierMode: Bool
    /// CFMachPort reference for re-enabling the tap after system disables it.
    var tap: CFMachPort?

    init(gesture: GestureStateMachine, keycodes: Set<Int64>, modifierMode: Bool) {
        self.gesture = gesture
        targetKeycodes = keycodes
        useModifierMode = modifierMode
    }
}

// MARK: - C Callback (no captures)

/// CGEventTap callback — must be a C function with no captured context.
/// All state is accessed through the userInfo pointer (TapContext).
private func hotkeyCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable tap if system disabled it (e.g., after timeout or secure input)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = ctx.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[HotkeyManager] Re-enabled event tap after system disable")
        }
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

    if ctx.useModifierMode {
        // Modifier key mode (Right Command = keycode 54)
        guard ctx.targetKeycodes.contains(keycode) else {
            return Unmanaged.passUnretained(event)
        }
        let isDown = event.flags.contains(.maskCommand)
        DispatchQueue.main.async {
            if isDown {
                ctx.gesture.handleKeyDown()
            } else {
                ctx.gesture.handleKeyUp()
            }
        }
    } else {
        // Function key mode (F4 = keycodes 118, 129)
        guard ctx.targetKeycodes.contains(keycode) else {
            return Unmanaged.passUnretained(event)
        }
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
        guard autorepeat == 0 else {
            return Unmanaged.passUnretained(event)
        }
        let isDown = (type == .keyDown)
        DispatchQueue.main.async {
            if isDown {
                ctx.gesture.handleKeyDown()
            } else {
                ctx.gesture.handleKeyUp()
            }
        }
    }

    // .listenOnly — always pass through
    return Unmanaged.passUnretained(event)
}

// MARK: - Hotkey Manager

/// Manages CGEventTap for global hotkey detection.
/// Uses .listenOnly (Input Monitoring) — does not consume events.
final class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Keycodes to listen for.
    /// Right Command = 54. F4 standard = 118, F4 media = 129.
    private var targetKeycodes: Set<Int64> = [54]

    /// Whether we're listening for flagsChanged (modifier keys like Cmd)
    /// vs keyDown/keyUp (function keys like F4).
    private var useModifierMode: Bool = true

    private let gesture: GestureStateMachine

    /// Retained context for the C callback — must live as long as the tap.
    private var tapContext: TapContext?

    init(gesture: GestureStateMachine) {
        self.gesture = gesture
    }

    /// Check if Input Monitoring permission is granted.
    static func hasPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Request Input Monitoring permission (shows system dialog).
    static func requestPermission() {
        CGRequestListenEventAccess()
    }

    /// Start the event tap. Returns false if permission is missing or tap creation fails.
    func start() -> Bool {
        guard HotkeyManager.hasPermission() else {
            NSLog("[HotkeyManager] Input Monitoring permission not granted")
            HotkeyManager.requestPermission()
            return false
        }

        // Event mask depends on whether we listen for modifier or function keys
        let mask = if useModifierMode {
            CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        } else {
            CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                    (1 << CGEventType.keyUp.rawValue)
            )
        }

        // Create context for the C callback
        let ctx = TapContext(
            gesture: gesture, keycodes: targetKeycodes, modifierMode: useModifierMode
        )
        tapContext = ctx
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: ctxPtr
        ) else {
            NSLog("[HotkeyManager] Failed to create CGEventTap — check permissions")
            return false
        }

        eventTap = tap
        ctx.tap = tap // Store tap reference so callback can re-enable it

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source

        NSLog("[HotkeyManager] Event tap started — keycodes: %@, modifier: %@",
              String(describing: targetKeycodes), useModifierMode ? "yes" : "no")
        return true
    }

    /// Stop the event tap and clean up.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        tapContext = nil
        NSLog("[HotkeyManager] Event tap stopped")
    }

    /// Reconfigure for different keycodes (e.g., switch from Right Command to F4).
    func configure(keycodes: Set<Int64>, useModifierMode: Bool) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        targetKeycodes = keycodes
        self.useModifierMode = useModifierMode
        if wasRunning { _ = start() }
    }
}
