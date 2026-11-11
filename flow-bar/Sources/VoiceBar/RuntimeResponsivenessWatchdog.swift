import Foundation

/// One outstanding probe and two numeric receipts per stall. Never samples UI, keys or audio.
final class RuntimeResponsivenessWatchdog {
    private let queue = DispatchQueue(label: "VoiceBar.Responsiveness", qos: .utility)
    private let enqueue: (DispatchWorkItem) -> Void
    private let sink: (String) -> Void
    private let loop: String
    private let threshold: TimeInterval
    private var timer: DispatchSourceTimer?
    private var pendingAcknowledgement: DispatchWorkItem?
    private var pending: TimeInterval?
    private var reported = false
    private var generation = 0

    init(loop: String, threshold: TimeInterval = 2,
         enqueue: @escaping (DispatchWorkItem) -> Void,
         sink: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        self.loop = loop
        self.threshold = threshold
        self.enqueue = enqueue
        self.sink = sink
    }

    func start(interval: TimeInterval = 0.5) {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
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
            }
        }
        pendingAcknowledgement = acknowledgement
        enqueue(acknowledgement)
    }

    private func receipt(_ state: String, elapsed: TimeInterval) {
        sink("[VoiceBar][responsiveness] loop=\(loop) state=\(state) elapsed_ms=\(Int(elapsed * 1000)) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }
}
