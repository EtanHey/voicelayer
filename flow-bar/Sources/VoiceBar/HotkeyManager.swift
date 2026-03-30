// HotkeyManager.swift — Global hotkey detection via CGEventTap.
//
// Uses .listenOnly tap (Input Monitoring permission) with Cmd+F6
// as the default hotkey. No event consumption needed because the tap
// only observes matching events and lets the system handle them normally.
//
// Gesture state machine: hold (250ms) = push-to-talk, double-tap (400ms) = toggle.
//
// AIDEV-NOTE: Based on R02 research (macOS Sequoia CGEventTap guide).
// Cmd+F6 is detected via flagsChanged with Command held and F6 keycodes
// 97 (standard function key mode) or 177 (media mode), mirroring the
// dual-keycode handling used for F4.

import CoreGraphics
import Foundation

// MARK: - Gesture State Machine

/// Detects hold vs tap vs double-tap from raw key events.
/// - Hold (250ms+): push-to-talk recording
/// - Single tap: no-op
/// - Double-tap (within 400ms): toggle hands-free recording
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
    var onPreviewPhaseChange: (HotkeyPhase) -> Void = { _ in }

    func handleKeyDown() {
        switch state {
        case .waitingForDoubleTap:
            doubleTapTimer?.cancel()
            state = .idle
            onPreviewPhaseChange(.idle)
            onDoubleTap()
        case .idle:
            state = .waitingForHoldThreshold
            onPreviewPhaseChange(.pressing)
            let timer = DispatchWorkItem { [weak self] in
                guard let self, state == .waitingForHoldThreshold else { return }
                state = .holding
                onPreviewPhaseChange(.holding)
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
            onPreviewPhaseChange(.awaitingSecondTap)
            let timer = DispatchWorkItem { [weak self] in
                guard let self, state == .waitingForDoubleTap else { return }
                state = .idle
                onPreviewPhaseChange(.idle)
                onSingleTap()
            }
            doubleTapTimer = timer
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Self.doubleTapWindowMs),
                execute: timer
            )
        case .holding:
            state = .idle
            onPreviewPhaseChange(.idle)
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
        onPreviewPhaseChange(.idle)
    }
}

enum HotkeyAction: Equatable {
    case ignore
    case keyDown
    case keyUp
}

func hotkeyAction(
    type: CGEventType,
    keycode: Int64,
    flags: CGEventFlags,
    autorepeat: Int64,
    targetKeycodes: Set<Int64>,
    useModifierMode: Bool
) -> HotkeyAction {
    guard targetKeycodes.contains(keycode) else {
        return .ignore
    }

    if useModifierMode {
        guard type == .flagsChanged else {
            return .ignore
        }
        // flagsChanged events don't have autorepeat — they fire once per modifier state change
        return flags.contains(.maskCommand) ? .keyDown : .keyUp
    }

    guard type == .keyDown || type == .keyUp else {
        return .ignore
    }
    guard autorepeat == 0 else {
        return .ignore
    }
    return type == .keyDown ? .keyDown : .keyUp
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

    let action = hotkeyAction(
        type: type,
        keycode: keycode,
        flags: event.flags,
        autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat),
        targetKeycodes: ctx.targetKeycodes,
        useModifierMode: ctx.useModifierMode
    )
    switch action {
    case .ignore:
        break
    case .keyDown:
        DispatchQueue.main.async {
            ctx.gesture.handleKeyDown()
        }
    case .keyUp:
        DispatchQueue.main.async {
            ctx.gesture.handleKeyUp()
        }
    }

    // .listenOnly — always pass through
    return Unmanaged.passUnretained(event)
}

// MARK: - Hotkey Manager

/// Manages CGEventTap for global hotkey detection.
/// Uses .listenOnly (Input Monitoring) — does not consume events.
final class HotkeyManager {
    static let defaultTargetKeycodes: Set<Int64> = [97, 177]
    static let defaultUsesModifierMode = true

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Keycodes to listen for.
    /// F6 standard = 97, F6 media = 177.
    private var targetKeycodes = HotkeyManager.defaultTargetKeycodes

    /// Whether we're listening for flagsChanged (Cmd+Fn key combinations)
    /// vs keyDown/keyUp (plain function keys like F4).
    private var useModifierMode = HotkeyManager.defaultUsesModifierMode

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

        // Event mask depends on whether we listen for flagsChanged combos
        // or plain function-key presses.
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

    /// Reconfigure for different keycodes or event modes.
    func configure(keycodes: Set<Int64>, useModifierMode: Bool) {
        guard !keycodes.isEmpty else {
            NSLog("[HotkeyManager] configure() called with empty keycodes — ignoring")
            return
        }
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        gesture.reset()
        targetKeycodes = keycodes
        self.useModifierMode = useModifierMode
        if wasRunning { _ = start() }
    }
}
