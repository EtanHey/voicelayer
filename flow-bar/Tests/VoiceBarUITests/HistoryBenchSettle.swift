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

@MainActor
enum HistoryBenchSettle {
    /// Spins the main run loop in 2 ms slices; a slice over 8 ms is main-thread work (apply, body, layout,
    /// render). Settled = what `expecting` requires has happened and then 150 ms passed with no busy slice.
    static func settle(
        after start: CFAbsoluteTime,
        expecting: HistoryBenchExpectation,
        probe: HistoryBenchProbe,
        timeout: TimeInterval = 10,
        noLoadWindow: TimeInterval = 0.4
    ) -> HistoryBenchSettled {
        var longest = 0.0
        var lastBusyEnd = start
        let deadline = start + timeout
        while CFAbsoluteTimeGetCurrent() < deadline {
            let sliceStart = CFAbsoluteTimeGetCurrent()
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            let sliceEnd = CFAbsoluteTimeGetCurrent()
            let sliceMs = (sliceEnd - sliceStart) * 1000
            if sliceMs > 8 {
                longest = max(longest, sliceMs)
                lastBusyEnd = sliceEnd
            }

            let awaited: CFAbsoluteTime?
            switch expecting {
            case let .load(key):
                guard let done = probe.finished(key) else { continue }
                // A load that already finished before this operation began counts as done at its start.
                awaited = max(done, start)
            case let .loadIfStarted(key):
                if probe.started(key) != nil {
                    guard let done = probe.finished(key) else { continue }
                    awaited = max(done, start)
                } else {
                    guard sliceEnd - start >= noLoadWindow else { continue }
                    awaited = nil
                }
            case .none:
                awaited = nil
            }
            let workEnd = max(lastBusyEnd, awaited ?? start)
            if sliceEnd - workEnd > 0.15 {
                return HistoryBenchSettled(
                    quietAtMs: (workEnd - start) * 1000,
                    loaderDoneMs: awaited.map { ($0 - start) * 1000 },
                    longestStallMs: longest,
                    timedOut: false
                )
            }
        }
        return HistoryBenchSettled(quietAtMs: nil, loaderDoneMs: nil, longestStallMs: longest, timedOut: true)
    }

    static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "none"
    }
}
