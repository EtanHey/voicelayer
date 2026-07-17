// HotkeyManager.swift — Global hotkey detection via CGEventTap.
//
// Uses a consuming event tap so plain F5 does not leak to the focused app
// and trigger macOS keyboard-focus traversal.
//
// Gesture state machine: F5 keyDown shows an immediate preview; holding past
// the threshold starts push-to-talk, and double-tap locks recording on.
//
// AIDEV-NOTE: Cmd+F5 arrives as F5 keyDown/keyUp events with the Command flag
// set, not as flagsChanged events. We listen for keycode 96 directly. On
// keyboards where the top-row F5 key is hard-wired to Dictation, hidutil maps
// it to the internal F18 relay.

import ApplicationServices
import CoreGraphics
import Foundation
import VoiceBarUI

private func describeEventType(_ type: CGEventType) -> String {
    switch type {
    case .null: "null"
    case .leftMouseDown: "leftMouseDown"
    case .leftMouseUp: "leftMouseUp"
    case .rightMouseDown: "rightMouseDown"
    case .rightMouseUp: "rightMouseUp"
    case .otherMouseDown: "otherMouseDown"
    case .otherMouseUp: "otherMouseUp"
    case .otherMouseDragged: "otherMouseDragged"
    case .mouseMoved: "mouseMoved"
    case .leftMouseDragged: "leftMouseDragged"
    case .rightMouseDragged: "rightMouseDragged"
    case .keyDown: "keyDown"
    case .keyUp: "keyUp"
    case .flagsChanged: "flagsChanged"
    case .scrollWheel: "scrollWheel"
    case .tapDisabledByTimeout: "tapDisabledByTimeout"
    case .tapDisabledByUserInput: "tapDisabledByUserInput"
    default: "raw(\(type.rawValue))"
    }
}

private func describeFlags(_ flags: CGEventFlags) -> String {
    var parts: [String] = []
    if flags.contains(.maskCommand) { parts.append("cmd") }
    if flags.contains(.maskShift) { parts.append("shift") }
    if flags.contains(.maskAlternate) { parts.append("option") }
    if flags.contains(.maskControl) { parts.append("control") }
    if flags.contains(.maskSecondaryFn) { parts.append("fn") }
    return parts.isEmpty ? "none" : parts.joined(separator: "+")
}

// MARK: - Gesture State Machine

/// Maps raw key events to push-to-talk and double-tap lock.
/// - F5 down: shows a pressing preview immediately
/// - F5 held past threshold: starts push-to-talk recording
/// - F5 double-tap: starts a locked recording
final class GestureStateMachine {
    enum State: Equatable {
        case idle
        case pressing
        case holding
        case waitingForDoubleTap
        case locked
    }

    private enum DoubleTapExpiryBehavior {
        case singleTap
        case holdEnd
    }

    private(set) var state: State = .idle
    private var keyDownTime: TimeInterval?
    private var holdTimer: DispatchWorkItem?
    private var doubleTapTimer: DispatchWorkItem?
    private var holdTimerGeneration = 0
    private var doubleTapTimerGeneration = 0
    private var doubleTapDeadline: TimeInterval?
    private var doubleTapExpiryBehavior: DoubleTapExpiryBehavior?

    static let doubleTapWindowMs: Int = 400
    static let holdThresholdMs: Int = 160

    // Callbacks — set by the owner (AppDelegate)
    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}
    var onSingleTap: () -> Void = {}
    var onDoubleTap: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPreviewPhaseChange: (HotkeyPhase) -> Void = { _ in }

    func handleKeyDown() {
        let now = CFAbsoluteTimeGetCurrent()
        switch state {
        case .idle:
            startPressing(now: now)
        case .waitingForDoubleTap:
            if isDoubleTapWindowExpired(now: now) {
                expireDoubleTapWindow()
                startPressing(now: now)
                return
            }
            clearDoubleTapTimer()
            doubleTapDeadline = nil
            doubleTapExpiryBehavior = nil
            keyDownTime = nil
            state = .locked
            onPreviewPhaseChange(.holding)
            onHoldStart()
            onDoubleTap()
        case .locked:
            state = .idle
            onPreviewPhaseChange(.idle)
            onHoldEnd()
        default:
            break
        }
    }

    func handleKeyUp() {
        switch state {
        case .pressing:
            clearHoldTimer()
            keyDownTime = nil
            startDoubleTapWindow(expiryBehavior: .singleTap)
        case .holding:
            keyDownTime = nil
            state = .idle
            onPreviewPhaseChange(.idle)
            onHoldEnd()
        case .locked:
            break
        default:
            break
        }
    }

    func handleMouseButtonDown() {
        let now = CFAbsoluteTimeGetCurrent()
        switch state {
        case .idle:
            startPressing(now: now)
        case .locked:
            state = .idle
            onPreviewPhaseChange(.idle)
            onHoldEnd()
        default:
            break
        }
    }

    func handleMouseButtonUp() {
        switch state {
        case .pressing:
            clearHoldTimer()
            keyDownTime = nil
            state = .locked
            onPreviewPhaseChange(.holding)
            onHoldStart()
        case .holding:
            keyDownTime = nil
            state = .idle
            onPreviewPhaseChange(.idle)
            onHoldEnd()
        default:
            break
        }
    }

    func cancel() {
        switch state {
        case .idle:
            reset()
        case .pressing, .waitingForDoubleTap:
            reset()
        case .holding, .locked:
            reset()
            onCancel()
        }
    }

    /// Reset state (e.g., on permission changes).
    func reset() {
        clearHoldTimer()
        clearDoubleTapTimer()
        doubleTapDeadline = nil
        doubleTapExpiryBehavior = nil
        keyDownTime = nil
        state = .idle
        onPreviewPhaseChange(.idle)
    }

    private func startPressing(now: TimeInterval) {
        clearHoldTimer()
        holdTimerGeneration += 1
        let generation = holdTimerGeneration
        keyDownTime = now
        state = .pressing
        onPreviewPhaseChange(.pressing)
        let timer = DispatchWorkItem { [weak self] in
            guard let self, state == .pressing, holdTimerGeneration == generation else { return }
            holdTimer = nil
            state = .holding
            onPreviewPhaseChange(.holding)
            onHoldStart()
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.holdThresholdMs),
            execute: timer
        )
    }

    private func startDoubleTapWindow(expiryBehavior: DoubleTapExpiryBehavior) {
        clearDoubleTapTimer()
        doubleTapTimerGeneration += 1
        let generation = doubleTapTimerGeneration
        state = .waitingForDoubleTap
        doubleTapDeadline = CFAbsoluteTimeGetCurrent() + Double(Self.doubleTapWindowMs) / 1000
        doubleTapExpiryBehavior = expiryBehavior
        onPreviewPhaseChange(.awaitingSecondTap)
        let timer = DispatchWorkItem { [weak self] in
            guard let self, state == .waitingForDoubleTap, doubleTapTimerGeneration == generation else { return }
            expireDoubleTapWindow()
        }
        doubleTapTimer = timer
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.doubleTapWindowMs),
            execute: timer
        )
    }

    private func isDoubleTapWindowExpired(now: TimeInterval) -> Bool {
        guard let doubleTapDeadline else { return true }
        return now > doubleTapDeadline
    }

    private func expireDoubleTapWindow() {
        guard state == .waitingForDoubleTap else {
            clearDoubleTapTimer()
            doubleTapDeadline = nil
            doubleTapExpiryBehavior = nil
            return
        }
        clearDoubleTapTimer()
        doubleTapDeadline = nil
        let expiryBehavior = doubleTapExpiryBehavior
        doubleTapExpiryBehavior = nil
        keyDownTime = nil
        state = .idle
        onPreviewPhaseChange(.idle)
        switch expiryBehavior {
        case .singleTap:
            onSingleTap()
        case .holdEnd:
            onHoldEnd()
        case nil:
            break
        }
    }

    private func clearDoubleTapTimer() {
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        doubleTapTimerGeneration += 1
    }

    private func clearHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
        holdTimerGeneration += 1
    }
}

enum HotkeyAction: Equatable {
    case ignore
    case consume
    case keyDown
    case keyUp
    case sendEnter
    case pasteLastTranscript
    case cancel
}

struct HotkeyPermissionStatus: Equatable {
    var listenEventGranted: Bool
    var accessibilityGranted: Bool

    var missingPermissions: [HotkeyPermission] {
        var missing: [HotkeyPermission] = []
        if !listenEventGranted { missing.append(.inputMonitoring) }
        if !accessibilityGranted { missing.append(.accessibility) }
        return missing
    }

    var isGranted: Bool {
        missingPermissions.isEmpty
    }
}

struct DebounceClock {
    var now: () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }
}

struct HotkeyDebounceState {
    var lastProcessedKeyDownTime: TimeInterval?
}

struct HotkeySequenceState {
    var repasteKeyDownKeycode: Int64?
}

private let hotkeyDuplicateEventDebounceSeconds: TimeInterval = 0.01

func shouldDebounceHotkeyAction(
    action: HotkeyAction,
    debounceState: inout HotkeyDebounceState,
    clock: DebounceClock = DebounceClock()
) -> Bool {
    guard action == .keyDown else { return false }
    let timestamp = clock.now()
    if let lastProcessedKeyDownTime = debounceState.lastProcessedKeyDownTime,
       (timestamp - lastProcessedKeyDownTime) < hotkeyDuplicateEventDebounceSeconds {
        return true
    }
    debounceState.lastProcessedKeyDownTime = timestamp
    return false
}

func shouldConsumeHotkeyEvent(
    hotkeyAction: HotkeyAction,
    targetKeycodes: Set<Int64>,
    keycode: Int64
) -> Bool {
    switch hotkeyAction {
    case .keyDown, .keyUp:
        targetKeycodes.contains(keycode)
    case .cancel:
        true
    case .consume, .sendEnter:
        true
    case .pasteLastTranscript:
        targetKeycodes.contains(keycode)
    case .ignore:
        false
    }
}

func dispatchHotkeyAction(
    _ action: HotkeyAction,
    onKeyDown: @escaping () -> Void,
    onKeyUp: @escaping () -> Void = {},
    onCancel: @escaping () -> Void,
    onPasteLastTranscript: @escaping () -> Void = {}
) {
    switch action {
    case .keyDown:
        DispatchQueue.main.async(execute: onKeyDown)
    case .keyUp:
        DispatchQueue.main.async(execute: onKeyUp)
    case .cancel:
        DispatchQueue.main.async(execute: onCancel)
    case .sendEnter:
        postReturnKeyPress()
    case .pasteLastTranscript:
        DispatchQueue.main.async(execute: onPasteLastTranscript)
    case .ignore, .consume:
        break
    }
}

func hotkeyAction(
    type: CGEventType,
    keycode: Int64,
    flags: CGEventFlags,
    autorepeat: Int64,
    targetKeycodes: Set<Int64>,
    useModifierMode: Bool,
    currentModifierFlags: CGEventFlags = CGEventSource.flagsState(.hidSystemState),
    gestureIsActive: Bool = false,
    cancellationIsActive: Bool? = nil
) -> HotkeyAction {
    let escapeCancellationIsActive = cancellationIsActive ?? gestureIsActive
    if type == .keyDown, keycode == 53, autorepeat == 0, escapeCancellationIsActive {
        NSLog("[HotkeyManager] Matched Escape while cancellation active -> cancel")
        return .cancel
    }

    let isTargetHotkey = targetKeycodes.contains(keycode)
    guard isTargetHotkey else {
        NSLog(
            "[HotkeyManager] Keycode %lld does not match hotkey set %@ for event %@",
            keycode,
            String(describing: targetKeycodes),
            describeEventType(type)
        )
        return .ignore
    }

    // In plain mode, system chords like Cmd+F5 (VoiceOver toggle), Ctrl+F5
    // (Full Keyboard Access), and Option+F5 must pass through to the OS for
    // BOTH keyDown and keyUp — otherwise VoiceBar's event tap eats the keyUp
    // and leaves the OS with an unpaired keyDown (stuck modifier state, broken
    // accessibility chords). Must run before the keyUp early-return so it
    // covers both event types.
    //
    // Exception: when a VoiceBar gesture is already active and the user
    // happens to be holding a modifier on release, let the keyUp through so
    // GestureStateMachine.handleKeyUp() can unwind the hold. Otherwise the
    // recording would sit open until manually cancelled.
    if !useModifierMode, type == .keyDown || type == .keyUp {
        let blockingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        if !flags.isDisjoint(with: blockingModifiers) {
            let shouldUnwindActiveHold = type == .keyUp && gestureIsActive
            if !shouldUnwindActiveHold {
                NSLog(
                    "[HotkeyManager] Ignoring modified plain-mode chord for keycode %lld so system shortcut reaches the OS (event=%@, flags=%@)",
                    keycode,
                    describeEventType(type),
                    describeFlags(flags)
                )
                return .ignore
            }
            NSLog(
                "[HotkeyManager] Letting modified keyUp through for keycode %lld because a gesture is active — unwinding hold (flags=%@)",
                keycode,
                describeFlags(flags)
            )
        }
    }

    let exactShiftOnly = flags.contains(.maskShift)
        && !flags.contains(.maskCommand)
        && !flags.contains(.maskAlternate)
        && !flags.contains(.maskControl)
    if exactShiftOnly, type == .keyUp {
        if gestureIsActive {
            NSLog("[HotkeyManager] Letting Shift+F5 keyUp unwind the active gesture for keycode %lld", keycode)
            return .keyUp
        }
        NSLog("[HotkeyManager] Consuming Shift+F5 release after re-paste for keycode %lld", keycode)
        return .consume
    }

    if type == .keyUp {
        NSLog(
            "[HotkeyManager] Matched keycode %lld release -> keyUp (flags=%@)",
            keycode,
            describeFlags(flags)
        )
        return .keyUp
    }

    if exactShiftOnly {
        guard type == .keyDown else {
            NSLog(
                "[HotkeyManager] Ignoring re-paste hotkey event %@ for keycode %lld",
                describeEventType(type),
                keycode
            )
            return .ignore
        }
        guard autorepeat == 0 else {
            if gestureIsActive {
                NSLog("[HotkeyManager] Consuming autorepeat for re-paste keycode %lld while gesture is active", keycode)
                return .consume
            }
            NSLog("[HotkeyManager] Ignoring autorepeat for re-paste keycode %lld", keycode)
            return .ignore
        }
        guard !gestureIsActive else {
            NSLog("[HotkeyManager] Consuming Shift+F5 keyDown during an active gesture for keycode %lld", keycode)
            return .consume
        }
        NSLog(
            "[HotkeyManager] Matched Shift+F5 re-paste chord for keycode %lld -> pasteLastTranscript (flags=%@)",
            keycode,
            describeFlags(flags)
        )
        return .pasteLastTranscript
    }

    if flags.contains(.maskShift) {
        NSLog(
            "[HotkeyManager] Ignoring modified F5 for keycode %lld because Shift+F5 is the exact re-paste shortcut (flags=%@)",
            keycode,
            describeFlags(flags)
        )
        return .ignore
    }

    if useModifierMode {
        guard type == .keyDown || type == .keyUp else {
            NSLog(
                "[HotkeyManager] Matched keycode %lld but ignored event type %@ in modifier mode",
                keycode,
                describeEventType(type)
            )
            return .ignore
        }
        guard autorepeat == 0 else {
            if gestureIsActive {
                NSLog(
                    "[HotkeyManager] Consuming autorepeat for keycode %lld in modifier mode while gesture is active",
                    keycode
                )
                return .consume
            }
            NSLog("[HotkeyManager] Ignoring autorepeat for keycode %lld in modifier mode", keycode)
            return .ignore
        }
        let commandHeld = flags.contains(.maskCommand) || currentModifierFlags.contains(.maskCommand)
        if type == .keyDown, !commandHeld {
            NSLog(
                "[HotkeyManager] Ignoring keyDown for keycode %lld because Command is not held (flags=%@)",
                keycode,
                describeFlags(flags)
            )
            return .ignore
        }
        // keyUp is accepted even if Command was released first so the gesture
        // state machine can always exit a hold cleanly.
        let action: HotkeyAction = type == .keyDown ? .keyDown : .keyUp
        NSLog(
            "[HotkeyManager] Matched keycode %lld in modifier mode -> %@ (flags=%@)",
            keycode,
            action == .keyDown ? "keyDown" : "keyUp",
            describeFlags(flags)
        )
        return action
    }

    guard type == .keyDown || type == .keyUp else {
        NSLog(
            "[HotkeyManager] Matched keycode %lld but ignored non-key event %@",
            keycode,
            describeEventType(type)
        )
        return .ignore
    }
    guard autorepeat == 0 else {
        if gestureIsActive {
            NSLog("[HotkeyManager] Consuming autorepeat for keycode %lld while gesture is active", keycode)
            return .consume
        }
        NSLog("[HotkeyManager] Ignoring autorepeat for keycode %lld", keycode)
        return .ignore
    }
    let action: HotkeyAction = type == .keyDown ? .keyDown : .keyUp
    NSLog(
        "[HotkeyManager] Matched keycode %lld in plain mode -> %@",
        keycode,
        action == .keyDown ? "keyDown" : "keyUp"
    )
    return action
}

func sequenceAwareHotkeyAction(
    type: CGEventType,
    keycode: Int64,
    flags: CGEventFlags,
    autorepeat: Int64,
    targetKeycodes: Set<Int64>,
    useModifierMode: Bool,
    currentModifierFlags: CGEventFlags = CGEventSource.flagsState(.hidSystemState),
    gestureIsActive: Bool = false,
    cancellationIsActive: Bool? = nil,
    sequenceState: inout HotkeySequenceState
) -> HotkeyAction {
    if type == .keyUp, sequenceState.repasteKeyDownKeycode == keycode {
        sequenceState.repasteKeyDownKeycode = nil
        NSLog("[HotkeyManager] Consuming keyUp paired with re-paste keyDown for keycode %lld", keycode)
        return .consume
    }

    let action = hotkeyAction(
        type: type,
        keycode: keycode,
        flags: flags,
        autorepeat: autorepeat,
        targetKeycodes: targetKeycodes,
        useModifierMode: useModifierMode,
        currentModifierFlags: currentModifierFlags,
        gestureIsActive: gestureIsActive,
        cancellationIsActive: cancellationIsActive
    )
    if type == .keyDown, autorepeat == 0, targetKeycodes.contains(keycode) {
        sequenceState.repasteKeyDownKeycode = action == .pasteLastTranscript ? keycode : nil
    }
    return action
}

func mouseHotkeyAction(
    type: CGEventType,
    buttonNumber: Int64,
    targetMouseButtons: Set<Int64>,
    enterMouseButtons: Set<Int64> = []
) -> HotkeyAction {
    if enterMouseButtons.contains(buttonNumber) {
        switch type {
        case .otherMouseDown:
            NSLog("[HotkeyManager] Matched mouse button %lld press -> sendEnter", buttonNumber)
            return .sendEnter
        case .otherMouseUp:
            NSLog("[HotkeyManager] Matched mouse button %lld release -> consume", buttonNumber)
            return .consume
        default:
            NSLog(
                "[HotkeyManager] Matched enter mouse button %lld but ignored event type %@",
                buttonNumber,
                describeEventType(type)
            )
            return .ignore
        }
    }

    guard targetMouseButtons.contains(buttonNumber) else {
        NSLog(
            "[HotkeyManager] Mouse button %lld does not match hotkey mouse set %@ for event %@",
            buttonNumber,
            String(describing: targetMouseButtons),
            describeEventType(type)
        )
        return .ignore
    }

    switch type {
    case .otherMouseDown:
        NSLog("[HotkeyManager] Matched mouse button %lld press -> keyDown", buttonNumber)
        return .keyDown
    case .otherMouseUp:
        NSLog("[HotkeyManager] Matched mouse button %lld release -> keyUp", buttonNumber)
        return .keyUp
    default:
        NSLog(
            "[HotkeyManager] Matched mouse button %lld but ignored event type %@",
            buttonNumber,
            describeEventType(type)
        )
        return .ignore
    }
}

private func postReturnKeyPress() {
    let source = CGEventSource(stateID: .hidSystemState)
    let returnKeycode = CGKeyCode(36)
    CGEvent(keyboardEventSource: source, virtualKey: returnKeycode, keyDown: true)?
        .post(tap: .cghidEventTap)
    usleep(10000)
    CGEvent(keyboardEventSource: source, virtualKey: returnKeycode, keyDown: false)?
        .post(tap: .cghidEventTap)
}

// MARK: - Tap Context (passed through userInfo)

/// Holds configuration and gesture reference for the C callback.
/// Must be kept alive for the duration of the event tap.
private final class TapContext {
    let gesture: GestureStateMachine
    let targetKeycodes: Set<Int64>
    let targetMouseButtons: Set<Int64>
    let enterMouseButtons: Set<Int64>
    let useModifierMode: Bool
    let onKeyDown: () -> Void
    let onKeyUp: () -> Void
    let onMouseDown: () -> Void
    let onMouseUp: () -> Void
    let onCancel: () -> Void
    let onPasteLastTranscript: () -> Void
    let shouldHandleEscape: () -> Bool
    var debounceState = HotkeyDebounceState()
    var hotkeySequenceState = HotkeySequenceState()
    /// CFMachPort reference for re-enabling the tap after system disables it.
    var tap: CFMachPort?

    init(
        gesture: GestureStateMachine,
        keycodes: Set<Int64>,
        mouseButtons: Set<Int64>,
        enterMouseButtons: Set<Int64>,
        modifierMode: Bool,
        onKeyDown: @escaping () -> Void,
        onKeyUp: @escaping () -> Void,
        onMouseDown: @escaping () -> Void,
        onMouseUp: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onPasteLastTranscript: @escaping () -> Void,
        shouldHandleEscape: @escaping () -> Bool
    ) {
        self.gesture = gesture
        targetKeycodes = keycodes
        targetMouseButtons = mouseButtons
        self.enterMouseButtons = enterMouseButtons
        useModifierMode = modifierMode
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onMouseDown = onMouseDown
        self.onMouseUp = onMouseUp
        self.onCancel = onCancel
        self.onPasteLastTranscript = onPasteLastTranscript
        self.shouldHandleEscape = shouldHandleEscape
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
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    let mouseButtonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)

    NSLog(
        "[HotkeyManager] Callback entry type=%@ keycode=%lld mouseButton=%lld flags=%@ autorepeat=%lld",
        describeEventType(type),
        keycode,
        mouseButtonNumber,
        describeFlags(event.flags),
        autorepeat
    )

    // Re-enable tap if system disabled it (e.g., after timeout or secure input)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = ctx.tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[HotkeyManager] Re-enabled event tap after system disable")
        }
        return Unmanaged.passUnretained(event)
    }

    let isMouseHotkeyEvent = type == .otherMouseDown || type == .otherMouseUp
    let action: HotkeyAction = if isMouseHotkeyEvent {
        mouseHotkeyAction(
            type: type,
            buttonNumber: mouseButtonNumber,
            targetMouseButtons: ctx.targetMouseButtons,
            enterMouseButtons: ctx.enterMouseButtons
        )
    } else {
        sequenceAwareHotkeyAction(
            type: type,
            keycode: keycode,
            flags: event.flags,
            autorepeat: autorepeat,
            targetKeycodes: ctx.targetKeycodes,
            useModifierMode: ctx.useModifierMode,
            gestureIsActive: ctx.gesture.state != .idle,
            cancellationIsActive: ctx.gesture.state != .idle || ctx.shouldHandleEscape(),
            sequenceState: &ctx.hotkeySequenceState
        )
    }
    if shouldDebounceHotkeyAction(action: action, debounceState: &ctx.debounceState) {
        NSLog("[HotkeyManager] Debounced repeated keyDown for keycode %lld", keycode)
        return nil
    }
    dispatchHotkeyAction(
        action,
        onKeyDown: { isMouseHotkeyEvent ? ctx.onMouseDown() : ctx.onKeyDown() },
        onKeyUp: { isMouseHotkeyEvent ? ctx.onMouseUp() : ctx.onKeyUp() },
        onCancel: ctx.onCancel,
        onPasteLastTranscript: ctx.onPasteLastTranscript
    )

    if shouldConsumeHotkeyEvent(
        hotkeyAction: action,
        targetKeycodes: ctx.targetKeycodes,
        keycode: keycode
    ) || (isMouseHotkeyEvent && action != .ignore) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}

// MARK: - Hotkey Manager

/// Manages CGEventTap for global hotkey detection.
/// Matched hotkey events are consumed so F5 does not move focus in the target app.
final class HotkeyManager {
    static let defaultTargetKeycodes: Set<Int64> = [79, 96]
    static let defaultTargetMouseButtons: Set<Int64> = [4, 5]
    static let defaultEnterMouseButtons: Set<Int64> = [3]
    static let defaultUsesModifierMode = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Keycodes to listen for.
    /// F18 relay = 79, F5 standard = 96.
    private var targetKeycodes = HotkeyManager.defaultTargetKeycodes
    private var targetMouseButtons = HotkeyManager.defaultTargetMouseButtons
    private var enterMouseButtons = HotkeyManager.defaultEnterMouseButtons

    /// Whether the hotkey requires Command while the function key still emits
    /// ordinary keyDown/keyUp events.
    private var useModifierMode = HotkeyManager.defaultUsesModifierMode

    private let gesture: GestureStateMachine

    /// Retained context for the C callback — must live as long as the tap.
    private var tapContext: TapContext?

    /// Callback for Shift+F5 re-paste hotkey.
    var onKeyDown: () -> Void
    var onKeyUp: () -> Void
    var onMouseDown: () -> Void
    var onMouseUp: () -> Void
    var onCancel: () -> Void
    var onPasteLastTranscript: () -> Void = {}
    var shouldHandleEscape: () -> Bool = { false }
    private(set) var permissionStatus = HotkeyPermissionStatus(
        listenEventGranted: false,
        accessibilityGranted: false
    )

    init(gesture: GestureStateMachine) {
        self.gesture = gesture
        onKeyDown = { gesture.handleKeyDown() }
        onKeyUp = { gesture.handleKeyUp() }
        onMouseDown = { gesture.handleMouseButtonDown() }
        onMouseUp = { gesture.handleMouseButtonUp() }
        onCancel = { gesture.cancel() }
    }

    deinit {
        // Ensure tap is invalidated before TapContext pointer becomes dangling
        stop()
    }

    static func currentPermissionStatus() -> HotkeyPermissionStatus {
        HotkeyPermissionStatus(
            listenEventGranted: CGPreflightListenEventAccess(),
            accessibilityGranted: AXIsProcessTrusted()
        )
    }

    static func requestPermissions(for status: HotkeyPermissionStatus) {
        if status.missingPermissions.contains(.inputMonitoring) {
            CGRequestListenEventAccess()
        }
        if status.missingPermissions.contains(.accessibility) {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Start the event tap. Returns false if permission is missing or tap creation fails.
    func start() -> Bool {
        permissionStatus = HotkeyManager.currentPermissionStatus()
        guard permissionStatus.isGranted else {
            if permissionStatus.missingPermissions.contains(.inputMonitoring) {
                NSLog("[HotkeyManager] Input Monitoring permission not granted")
            }
            if permissionStatus.missingPermissions.contains(.accessibility) {
                NSLog("[HotkeyManager] Accessibility permission not granted")
            }
            HotkeyManager.requestPermissions(for: permissionStatus)
            return false
        }

        // Event mask depends on whether we require a modifier chord or a plain
        // function key. Cmd+F5 still arrives as keyDown/keyUp.
        let keyMask = if useModifierMode {
            CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                    (1 << CGEventType.keyUp.rawValue)
            )
        } else {
            CGEventMask(
                (1 << CGEventType.keyDown.rawValue) |
                    (1 << CGEventType.keyUp.rawValue)
            )
        }
        let mask = keyMask |
            CGEventMask(1 << CGEventType.otherMouseDown.rawValue) |
            CGEventMask(1 << CGEventType.otherMouseUp.rawValue)

        // Create context for the C callback
        let ctx = TapContext(
            gesture: gesture,
            keycodes: targetKeycodes,
            mouseButtons: targetMouseButtons,
            enterMouseButtons: enterMouseButtons,
            modifierMode: useModifierMode,
            onKeyDown: onKeyDown,
            onKeyUp: onKeyUp,
            onMouseDown: onMouseDown,
            onMouseUp: onMouseUp,
            onCancel: onCancel,
            onPasteLastTranscript: onPasteLastTranscript,
            shouldHandleEscape: shouldHandleEscape
        )
        tapContext = ctx
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        NSLog(
            "[HotkeyManager] Creating CGEventTap mode=%@ keycodes=%@ mask=0x%llx permission=%@",
            useModifierMode ? "modifier" : "plain",
            String(describing: targetKeycodes),
            mask,
            permissionStatus.isGranted ? "granted" : "missing"
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
