import CoreGraphics
import Foundation
import HotkeyAtomics

/// Main owns writes; the tap reads one lock-free snapshot, never UI or gesture objects.
final class HotkeyActivitySnapshot {
    private let storage = VoiceBarHotkeyAtomicCreate(0)!
    private var flags: UInt32 = 0

    deinit { VoiceBarHotkeyAtomicDestroy(storage) }

    var value: UInt32 { VoiceBarHotkeyAtomicLoad(storage) }

    func setGestureActive(_ active: Bool) { publish(bit: 1, active: active) }
    func setCancellationActive(_ active: Bool) { publish(bit: 2, active: active) }

    private func publish(bit: UInt32, active: Bool) {
        precondition(Thread.isMainThread)
        flags = active ? flags | bit : flags & ~bit
        VoiceBarHotkeyAtomicStore(storage, flags)
    }
}

/// One dedicated user-interactive thread. Start/stop are main-owned; nothing waits on main.
/// Cleanup runs on the owning thread, whose closure retains the callback context until removal.
final class HotkeyTapRunLoop {
    private var runLoop: CFRunLoop?
    private var responsivenessWatchdog: RuntimeResponsivenessWatchdog?

    func start(install: @escaping (CFRunLoop) -> Void, cleanup: @escaping (CFRunLoop) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()!
            // A keepalive source also lets the latency test use this exact production thread
            // without registering a second global tap or posting any real input.
            var context = CFRunLoopSourceContext()
            let keepalive = CFRunLoopSourceCreate(nil, 0, &context)!
            CFRunLoopAddSource(loop, keepalive, .commonModes)
            install(loop)
            runLoop = loop
            ready.signal()
            CFRunLoopRun()
            cleanup(loop)
            CFRunLoopRemoveSource(loop, keepalive, .commonModes)
        }
        thread.name = "VoiceBar.HotkeyEventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Startup only: the event callback never waits on this semaphore.
        ready.wait()
        let loop = runLoop!
        responsivenessWatchdog = RuntimeResponsivenessWatchdog(loop: "event_tap") { acknowledgement in
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { acknowledgement.perform() }
            CFRunLoopWakeUp(loop)
        }
        responsivenessWatchdog?.start()
        return true
    }

    func perform(_ work: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Called only by the owning loop; timers continue while main is blocked.
    static func schedule(on loop: CFRunLoop, after delay: TimeInterval, _ work: @escaping () -> Void) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { _ in work() }!
        CFRunLoopAddTimer(loop, timer, .commonModes)
    }

    func stop() {
        responsivenessWatchdog?.stop()
        responsivenessWatchdog = nil
        guard let runLoop else { return }
        self.runLoop = nil
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(runLoop) }
        CFRunLoopWakeUp(runLoop)
    }
}

/// Each notification permits one delayed attempt, bounded to three per failure burst.
/// A healthy 30s interval restores the budget; an exhausted burst gets one cool-off retry.
struct HotkeyTapRecovery {
    private(set) var timeoutCount = 0
    private(set) var userInputCount = 0
    var disableCount: Int { timeoutCount + userInputCount }
    private var lastDisableTime: TimeInterval?
    private var attempts = 0

    mutating func disabled(by type: CGEventType,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (count: Int, delay: TimeInterval?) {
        if let lastDisableTime, now - lastDisableTime >= 30 { attempts = 0 }
        lastDisableTime = now
        attempts += 1
        if type == .tapDisabledByTimeout { timeoutCount += 1 } else { userInputCount += 1 }
        return (timeoutCount + userInputCount, attempts <= 3 ? pow(2, Double(attempts - 1)) : 30)
    }
}
