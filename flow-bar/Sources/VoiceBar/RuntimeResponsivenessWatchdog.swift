import Foundation

/// What the app was doing, readable off the stalled loop. Holds state names only (voice mode, notch surface,
/// the last memory-pressure level): never transcript text, keys or audio.
final class RuntimePhaseBoard: @unchecked Sendable {
    static let shared = RuntimePhaseBoard()
    private let lock = NSLock()
    private var mode = "idle"
    private var surface = "closed"
    private var pressure: (level: String, uptime: TimeInterval)?
    private let uptime: () -> TimeInterval
    private let thermal: () -> ProcessInfo.ThermalState

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         thermal: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        self.uptime = uptime
        self.thermal = thermal
    }

    func setMode(_ value: String) { lock.lock(); mode = Self.token(value); lock.unlock() }
    func setSurface(_ value: String) { lock.lock(); surface = Self.token(value); lock.unlock() }
    func noteMemoryPressure(level: String) {
        lock.lock(); pressure = (Self.token(level), uptime()); lock.unlock()
    }

    /// `[VoiceBar] notch surface closed -> settings(general) (open settings general)` -> `settings(general)`.
    func noteSurfaceTransition(line: String) {
        guard let arrow = line.range(of: " -> ") else { return }
        let rest = line[arrow.upperBound...]
        setSurface(String(rest.prefix { $0 != " " }))
    }

    /// One log field group: `phase=<mode>/<surface> mem_pressure=<level>@<seconds ago>|none thermal=<state>`.
    func snapshot() -> String {
        lock.lock(); let mode = mode, surface = surface, pressure = pressure; lock.unlock()
        let memory = pressure.map { "\($0.level)@\(Int(max(0, uptime() - $0.uptime)))s" } ?? "none"
        let heat: String
        switch thermal() {
        case .nominal: heat = "nominal"
        case .fair: heat = "fair"
        case .serious: heat = "serious"
        case .critical: heat = "critical"
        @unknown default: heat = "unknown"
        }
        return "phase=\(mode)/\(surface) mem_pressure=\(memory) thermal=\(heat)"
    }

    /// `<mode>/<surface>`: what the rate limit compares, so a new phase is never held back.
    func phaseKey() -> String {
        lock.lock(); defer { lock.unlock() }
        return "\(mode)/\(surface)"
    }

    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return mode == "idle"
    }

    /// A state name is short and has no spaces, so a field can never smuggle free text into the log.
    private static func token(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber || "()_-.".contains($0) }.prefix(40))
    }
}

/// One outstanding probe per loop. A stall logs `stalled`, at most one `stack`, then `recovered`, each with the
/// phase when one is supplied. Never samples UI, keys or audio.
///
/// Rate limit (`quietPeriod`): after a reported stall, further stalls in the same phase within the period are
/// counted, not logged; the next reported line carries `suppressed=<count>`. A new phase is reported at once,
/// and so is any stall that reaches `alwaysReportAfter`, so a real hang is never hidden by an earlier hitch.
final class RuntimeResponsivenessWatchdog {
    private let queue = DispatchQueue(label: "VoiceBar.Responsiveness", qos: .utility)
    private let enqueue: (DispatchWorkItem) -> Void
    private let sink: (String) -> Void
    private let loop: String
    private let context: (() -> String)?
    private let phaseKey: (() -> String)?
    private let stack: (() -> [String])?
    private let stackAfter: TimeInterval
    private let threshold: TimeInterval
    private let quietPeriod: TimeInterval
    private let alwaysReportAfter: TimeInterval
    private var timer: DispatchSourceTimer?
    private var pendingAcknowledgement: DispatchWorkItem?
    private var pending: TimeInterval?
    /// The current stall crossed the threshold (logged or counted).
    private var noted = false
    /// The current stall has a `stalled` line, so it also gets `stack` and `recovered`.
    private var logged = false
    private var stackReported = false
    private var lastLoggedAt: TimeInterval?
    private var lastLoggedKey: String?
    private var suppressed = 0
    private var generation = 0

    /// `context`, `phaseKey` and `stack` run on the watchdog queue while the watched loop is blocked: they
    /// must not touch that loop.
    init(loop: String, threshold: TimeInterval = 2,
         context: (() -> String)? = nil,
         phaseKey: (() -> String)? = nil,
         quietPeriod: TimeInterval = 0,
         alwaysReportAfter: TimeInterval = 2,
         stackAfter: TimeInterval = 1,
         stack: (() -> [String])? = nil,
         enqueue: @escaping (DispatchWorkItem) -> Void,
         sink: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.loop = loop
        self.threshold = threshold
        self.context = context
        self.phaseKey = phaseKey
        self.quietPeriod = quietPeriod
        self.alwaysReportAfter = alwaysReportAfter
        self.stackAfter = stackAfter
        self.stack = stack
        self.enqueue = enqueue
        self.sink = sink
    }

    /// `leeway` lets the system batch the probe with other wakeups; nil keeps a quarter of the interval
    /// (at most 100 ms).
    func start(interval: TimeInterval = 0.5, leeway: TimeInterval? = nil) {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let slack = leeway ?? min(0.1, interval / 4)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(max(1, Int(slack * 1000))))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pendingAcknowledgement?.cancel()
            pendingAcknowledgement = nil
            generation += 1
            pending = nil
            noted = false
            logged = false
            stackReported = false
        }
    }

    deinit { timer?.cancel(); pendingAcknowledgement?.cancel() }

    private func tick() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let pending {
            noteStall(elapsed: now - pending, now: now)
            // One stack per logged stall, taken while the loop is still stuck: function names only.
            if logged, !stackReported, now - pending >= max(threshold, stackAfter) {
                stackReported = true
                if let frames = stack?(), !frames.isEmpty {
                    sink("[VoiceBar][responsiveness] loop=\(loop) state=stack elapsed_ms=\(Int((now - pending) * 1000)) "
                        + "frames=\(frames.joined(separator: " < "))")
                }
            }
            return // A blocked loop must never accumulate heartbeat work.
        }
        pending = now
        let generation = self.generation
        let acknowledgement = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.generation == generation, let pending = self.pending else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - pending
                // Recovery can beat the timer after an actual stall.
                self.noteStall(elapsed: elapsed, now: now)
                if self.logged { self.receipt("recovered", elapsed: elapsed) }
                self.pendingAcknowledgement = nil
                self.pending = nil
                self.noted = false
                self.logged = false
                self.stackReported = false
            }
        }
        pendingAcknowledgement = acknowledgement
        enqueue(acknowledgement)
    }

    /// Decides once per stall whether it is logged or counted, and promotes a counted stall that turns long.
    private func noteStall(elapsed: TimeInterval, now: TimeInterval) {
        guard elapsed >= threshold, !logged else { return }
        if !noted {
            noted = true
            let key = phaseKey?() ?? ""
            if quietPeriod > 0, let lastLoggedAt, now - lastLoggedAt < quietPeriod, key == lastLoggedKey {
                suppressed += 1
            } else {
                log(elapsed: elapsed, now: now, key: key)
                return
            }
        }
        if elapsed >= alwaysReportAfter {
            suppressed = max(0, suppressed - 1) // This one is being reported after all.
            log(elapsed: elapsed, now: now, key: phaseKey?() ?? "")
        }
    }

    private func log(elapsed: TimeInterval, now: TimeInterval, key: String) {
        logged = true
        lastLoggedAt = now
        lastLoggedKey = key
        let skipped = suppressed
        suppressed = 0
        receipt("stalled", elapsed: elapsed, suffix: skipped > 0 ? " suppressed=\(skipped)" : "")
    }

    private func receipt(_ state: String, elapsed: TimeInterval, suffix: String = "") {
        sink("[VoiceBar][responsiveness] loop=\(loop) state=\(state) elapsed_ms=\(Int(elapsed * 1000)) pid=\(ProcessInfo.processInfo.processIdentifier)"
            + (context.map { " " + $0() } ?? "") + suffix)
    }
}
