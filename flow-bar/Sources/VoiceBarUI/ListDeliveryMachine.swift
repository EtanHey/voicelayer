import Foundation

/// Main owns transitions; a worker may never answer. No worker result can authorize another step.
@MainActor public final class ListDeliveryMachine {
    public enum Kind { case capture, read, check }
    public struct Request {
        public let id: UUID
        public let step: Int
        public let kind: Kind
    }
    public struct Reply {
        public let request: Request
        public let same: Bool
        public let value: String?
        public let completed: TimeInterval
        public init(request: Request, same: Bool, value: String?, completed: TimeInterval) {
            self.request = request; self.same = same; self.value = value; self.completed = completed
        }
    }
    public enum Outcome: Equatable {
        case posted, refused, declined
        case partial(delivered: String, remaining: String)
    }
    public struct Environment {
        public var worker: (Request, @escaping (Reply) -> Void) -> Void
        /// Pure, main-local guard. Must not perform Accessibility work.
        public var guardTarget: () -> Bool
        public var started: () -> Void
        public var diagnostic: (String) -> Void
        public var post: (String) -> GuardedTypingResult
        public init(worker: @escaping (Request, @escaping (Reply) -> Void) -> Void,
                    guardTarget: @escaping () -> Bool, post: @escaping (String) -> GuardedTypingResult,
                    started: @escaping () -> Void = {}, diagnostic: @escaping (String) -> Void = { _ in }) {
            self.started = started; self.diagnostic = diagnostic
            self.worker = worker; self.guardTarget = guardTarget; self.post = post
        }
    }
    private struct Job {
        let id = UUID()
        let text: String
        let env: Environment
        let completion: (Outcome) -> Void
    }
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var queue: [Job] = []
    private var job: Job?
    private var segments: [ListContinuationSegment] = []
    private var step = 0
    private var deadline: TimeInterval = 0
    private var phase: Kind = .capture
    private var before = ""
    private var typed = ""
    private var drop = false
    private var fallback = false
    private var closed = false
    private var draining = false
    private var stableValue: String?
    private let permitsNewDelivery: () -> Bool
    public var isActive: Bool { job != nil }

    public init(permitsNewDelivery: @escaping () -> Bool = { true }, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                }) {
        self.permitsNewDelivery = permitsNewDelivery; self.now = now; self.schedule = schedule
    }
    public func deliver(_ text: String, env: Environment, completion: @escaping (Outcome) -> Void) {
        let next = Job(text: text, env: env, completion: completion)
        guard !closed, !draining, permitsNewDelivery() else { completion(.refused); return }
        if job != nil {
            guard queue.count < 2 else { completion(.refused); return }
            queue.append(next)
        } else { start(next) }
    }
    private func start(_ next: Job) {
        next.env.started()
        job = next; stableValue = nil; step = 0; drop = false; fallback = false; before = ""; typed = ""
        guard let plan = ListContinuationTyping.segments(for: next.text) else {
            segments = [ListContinuationSegment(text: next.text, leadingMarker: nil)]
            post(batch: true); return
        }
        segments = plan
        let budget = min(0.25 + 0.15 * Double(plan.count - 1), 2.0)
        deadline = now() + budget; phase = .capture
        let id = next.id
        schedule(budget) { [weak self] in
            guard let self, self.job?.id == id else { return }
            self.expire()
        }
        issue(.capture)
    }
    private func issue(_ kind: Kind) {
        guard let job else { return }
        guard now() < deadline else { expire(); return }
        phase = kind
        let request = Request(id: job.id, step: step, kind: kind)
        job.env.worker(request) { [weak self] reply in self?.receive(reply) }
    }
    public func receive(_ reply: Reply) {
        guard let job, reply.request.id == job.id, reply.request.step == step,
              reply.request.kind == phase else { return }
        if now() >= deadline {
            let age = now() - reply.completed
            if phase == .check, reply.same, age >= 0, age <= 0.1 { post(batch: false) }
            else { expire() }
            return
        }
        switch phase {
        case .capture:
            job.env.diagnostic("list_aware=capture unreadable=\(!reply.same || reply.value == nil)")
            guard reply.same, let value = reply.value else { finish(outcome: .declined); return }
            before = value; issue(.check)
        case .read:
            let reading = reply.same ? reply.value.map {
                ListContinuationTyping.read(before: before, after: $0, typedLine: typed,
                                            nextMarker: segments[step].leadingMarker ?? "")
            } ?? .unknown : .unknown
            job.env.diagnostic("list_aware=read verdict=\(reading)")
            if reading == .unknown || (reading == .editorInsertedMarker && stableValue != reply.value) {
                stableValue = reading == .editorInsertedMarker ? reply.value : nil
                let id = job.id, currentStep = step
                schedule(0.015) { [weak self] in
                    guard let self, self.job?.id == id, self.step == currentStep, self.phase == .read else { return }
                    self.issue(.read)
                }
                return
            }
            drop = reading == .editorInsertedMarker
            fallback = reading != .editorInsertedMarker
            if fallback { job.env.diagnostic("list_aware=fallback reason=plain_break") }
            if let value = reply.value, reply.same { before = value }
            issue(.check)
        case .check:
            guard reply.same else { finish(); return }
            let age = now() - reply.completed
            guard age >= 0, age <= 0.1 else { issue(.check); return }
            post(batch: false)
        }
    }
    private func expire() {
        guard let job else { return }
        job.env.diagnostic("list_aware=expiry phase=\(phase)")
        if phase == .capture { finish(outcome: .declined) } else { finish() }
    }
    private func post(batch: Bool) {
        guard let job else { return }
        let timestamp = now()
        let end = batch || fallback || timestamp >= deadline ? segments.count : step + 1
        var text = segments[step..<end].map(\.text).joined()
        if !batch, drop, timestamp < deadline, let marker = segments[step].leadingMarker {
            text.removeFirst(marker.count)
        }
        // The check consumption, final guard and post are one main-thread transition.
        guard job.env.guardTarget(), job.env.post(text) == .posted else { finish(); return }
        typed = text; step = end; drop = false; stableValue = nil
        if step == segments.count { finish() } else { issue(.read) }
    }
    private func finish(outcome override: Outcome? = nil) {
        guard let current = job else { return }
        let delivered = segments.prefix(step).map(\.text).joined()
        let remaining = segments.dropFirst(step).map(\.text).joined()
        let outcome: Outcome = override ?? (step == segments.count ? .posted : step == 0 ? .refused
            : .partial(delivered: delivered, remaining: remaining))
        let next = !closed && !draining && !queue.isEmpty ? queue.removeFirst() : nil
        job = next // reserve the FIFO head before a reentrant completion
        if let next { step = 0; segments = [ListContinuationSegment(text: next.text, leadingMarker: nil)] }
        current.completion(outcome)
        if let next, job?.id == next.id { start(next) }
    }
    /// Quit/update drain close synchronously, without joining the AX worker.
    public func close() {
        closed = true
        drain()
    }
    public func drain() {
        draining = true
        let waiting = queue; queue.removeAll()
        finish()
        for item in waiting { item.completion(.refused) }
        draining = false
    }
}
