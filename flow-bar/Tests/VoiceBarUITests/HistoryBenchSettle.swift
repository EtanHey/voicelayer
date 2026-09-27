import AppKit
import Foundation

/// Records when a History page loader starts and finishes, from any thread.
final class HistoryBenchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [String: CFAbsoluteTime] = [:]
    private var finishes: [String: CFAbsoluteTime] = [:]

    func start(_ key: String) {
        lock.lock()
        starts[key] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func finish(_ key: String) {
        lock.lock()
        finishes[key] = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Forget earlier loads of `key`, so only a load after this point counts.
    func reset(_ key: String) {
        lock.lock()
        starts[key] = nil
        finishes[key] = nil
        lock.unlock()
    }

    func started(_ key: String) -> CFAbsoluteTime? {
        lock.lock()
        defer { lock.unlock() }
        return starts[key]
    }

    func finished(_ key: String) -> CFAbsoluteTime? {
        lock.lock()
        defer { lock.unlock() }
        return finishes[key]
    }
}

/// What an operation must wait for before it counts as settled (E review r1, M1: a slow required load used to be
/// reported as a 0 ms "no-load" settle).
enum HistoryBenchExpectation {
    /// A new `key` load must complete; without one the measurement times out, it never reads as fast.
    case load(String)
    /// A scope switch: if a `key` load starts it must complete; if none starts within the observation window the
    /// switch needed no load (a retained scope) and settles once the main thread is quiet.
    case loadIfStarted(String)
    /// Only the main thread going quiet.
    case none
}

struct HistoryBenchSettled {
    /// Time from `start` until the work (loader and main-thread stalls) ended; nil when it timed out.
    let quietAtMs: Double?
    /// Time from `start` until the awaited loader returned; nil when none was awaited or none ran.
    let loaderDoneMs: Double?
    let longestStallMs: Double
    let timedOut: Bool
}

/// The settle decision, as a pure function of timestamps (E review r3: on the headless CI runner every run-loop
/// slice ran over 8 ms, so the run-loop-driven tests never saw a quiet main thread and timed out). The benchmark
/// feeds it real run-loop slices and probe marks; `HistoryBenchSettleTests` feed it a synthetic timeline, with no
/// run loop, clock or NSApp.
struct HistoryBenchSettleRule {
    let start: CFAbsoluteTime
    let expecting: HistoryBenchExpectation
    var noLoadWindow: TimeInterval = 0.4
    /// Quiet this long after the work ended = settled.
    var quietFor: TimeInterval = 0.15
    /// A slice longer than this was main-thread work (apply, body, layout, render).
    var busySliceMs: Double = 8

    private(set) var longestStallMs = 0.0
    private var lastBusyEnd: CFAbsoluteTime

    init(start: CFAbsoluteTime, expecting: HistoryBenchExpectation) {
        self.start = start
        self.expecting = expecting
        lastBusyEnd = start
    }

    /// One observed slice, with the awaited key's load marks as they stand at its end. Returns the result once
    /// settled, nil while still waiting.
    mutating func observe(
        sliceStart: CFAbsoluteTime,
        sliceEnd: CFAbsoluteTime,
        started: CFAbsoluteTime?,
        finished: CFAbsoluteTime?
    ) -> HistoryBenchSettled? {
        let sliceMs = (sliceEnd - sliceStart) * 1000
        if sliceMs > busySliceMs {
            longestStallMs = max(longestStallMs, sliceMs)
            lastBusyEnd = sliceEnd
        }

        let awaited: CFAbsoluteTime?
        switch expecting {
        case .load:
            guard let done = finished else { return nil }
            // A load that already finished before this operation began counts as done at its start.
            awaited = max(done, start)
        case .loadIfStarted:
            if started != nil {
                guard let done = finished else { return nil }
                awaited = max(done, start)
            } else {
                guard sliceEnd - start >= noLoadWindow else { return nil }
                awaited = nil
            }
        case .none:
            awaited = nil
        }
        let workEnd = max(lastBusyEnd, awaited ?? start)
        guard sliceEnd - workEnd > quietFor else { return nil }
        return HistoryBenchSettled(
            quietAtMs: (workEnd - start) * 1000,
            loaderDoneMs: awaited.map { ($0 - start) * 1000 },
            longestStallMs: longestStallMs,
            timedOut: false
        )
    }

    func timedOut() -> HistoryBenchSettled {
        HistoryBenchSettled(quietAtMs: nil, loaderDoneMs: nil, longestStallMs: longestStallMs, timedOut: true)
    }

    var awaitedKey: String? {
        switch expecting {
        case let .load(key), let .loadIfStarted(key): key
        case .none: nil
        }
    }
}

@MainActor
enum HistoryBenchSettle {
    /// Spins the main run loop in 2 ms slices and feeds each to `HistoryBenchSettleRule`.
    static func settle(
        after start: CFAbsoluteTime,
        expecting: HistoryBenchExpectation,
        probe: HistoryBenchProbe,
        timeout: TimeInterval = 10,
        noLoadWindow: TimeInterval = 0.4
    ) -> HistoryBenchSettled {
        var rule = HistoryBenchSettleRule(start: start, expecting: expecting)
        rule.noLoadWindow = noLoadWindow
        let key = rule.awaitedKey
        let deadline = start + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            let sliceStart = CFAbsoluteTimeGetCurrent()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let sliceEnd = CFAbsoluteTimeGetCurrent()
            if let settled = rule.observe(
                sliceStart: sliceStart,
                sliceEnd: sliceEnd,
                started: key.flatMap(probe.started),
                finished: key.flatMap(probe.finished)
            ) {
                return settled
            }
        }
        return rule.timedOut()
    }

    static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "none"
    }
}
