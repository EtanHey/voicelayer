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

    /// A state name is short and has no spaces, so a field can never smuggle free text into the log.
    private static func token(_ value: String) -> String {
        String(value.filter { $0.isLetter || $0.isNumber || "()_-.".contains($0) }.prefix(40))
    }
}

/// One outstanding probe and two receipts per stall, each with the phase when one is supplied. Never samples
/// UI, keys or audio.
final class RuntimeResponsivenessWatchdog {
    private let queue = DispatchQueue(label: "VoiceBar.Responsiveness", qos: .utility)
    private let enqueue: (DispatchWorkItem) -> Void
    private let sink: (String) -> Void
    private let loop: String
    private let context: (() -> String)?
    private let stack: (() -> [String])?
    private let stackAfter: TimeInterval
    private var stackReported = false
    private let threshold: TimeInterval
    private var timer: DispatchSourceTimer?
    private var pendingAcknowledgement: DispatchWorkItem?
    private var pending: TimeInterval?
    private var reported = false
    private var generation = 0

    /// `context` runs on the watchdog queue while the watched loop is blocked: it must not touch that loop.
    init(loop: String, threshold: TimeInterval = 2,
         context: (() -> String)? = nil,
         stackAfter: TimeInterval = 1,
         stack: (() -> [String])? = nil,
         enqueue: @escaping (DispatchWorkItem) -> Void,
         sink: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.loop = loop
        self.threshold = threshold
        self.context = context
        self.stackAfter = stackAfter
        self.stack = stack
        self.enqueue = enqueue
        self.sink = sink
    }

    func start(interval: TimeInterval = 0.5) {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval,
                           leeway: .milliseconds(min(100, max(1, Int(interval * 250)))))
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
            reported = false
            stackReported = false
        }
    }

    deinit { timer?.cancel(); pendingAcknowledgement?.cancel() }

    private func tick() {
        guard timer != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let pending {
            if !reported && now - pending >= threshold {
                reported = true
                receipt("stalled", elapsed: now - pending)
            }
            // One stack per stall, taken while the loop is still stuck: function names only.
            if !stackReported, now - pending >= max(threshold, stackAfter), let frames = stack?(), !frames.isEmpty {
                stackReported = true
                sink("[VoiceBar][responsiveness] loop=\(loop) state=stack elapsed_ms=\(Int((now - pending) * 1000)) "
                    + "frames=\(frames.joined(separator: " < "))")
            }
            return // A blocked loop must never accumulate heartbeat work.
        }
        pending = now
        let generation = self.generation
        let acknowledgement = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.generation == generation, let pending = self.pending else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - pending
                // Recovery can beat the timer after an actual stall.
                if !self.reported && elapsed >= self.threshold { self.receipt("stalled", elapsed: elapsed) }
                if self.reported || elapsed >= self.threshold { self.receipt("recovered", elapsed: elapsed) }
                self.pendingAcknowledgement = nil
                self.pending = nil
                self.reported = false
                self.stackReported = false
            }
        }
        pendingAcknowledgement = acknowledgement
        enqueue(acknowledgement)
    }

    private func receipt(_ state: String, elapsed: TimeInterval) {
        sink("[VoiceBar][responsiveness] loop=\(loop) state=\(state) elapsed_ms=\(Int(elapsed * 1000)) pid=\(ProcessInfo.processInfo.processIdentifier)"
            + (context.map { " " + $0() } ?? ""))
    }
}
