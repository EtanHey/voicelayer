import AppKit
import XCTest
@testable import VoiceBarUI

@MainActor
final class TeleprompterTestPlaybackClock {
    private struct Suspension {
        let deadline: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    var elapsed: Int
    private(set) var starts = 0
    var didSchedule: (() -> Void)?
    private var suspensions: [UUID: Suspension] = [:]
    private var isCancelled = false

    init(elapsed: Int = 0) { self.elapsed = elapsed }

    func isSuspended(until deadline: Int) -> Bool {
        suspensions.values.contains { $0.deadline == deadline }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
        if duration == .zero {
            starts += 1
            didSchedule?()
            return
        }
        let parts = duration.components
        let deadline = elapsed + Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    suspensions[id] = Suspension(deadline: deadline, continuation: continuation)
                    didSchedule?()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.suspensions.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func advance(to milliseconds: Int) {
        elapsed = milliseconds
        for (id, suspension) in suspensions where suspension.deadline <= milliseconds {
            suspensions.removeValue(forKey: id)?.continuation.resume()
        }
    }

    func cancel() {
        isCancelled = true
        for suspension in suspensions.values {
            suspension.continuation.resume(throwing: CancellationError())
        }
        suspensions.removeAll()
    }
}

@MainActor
final class TeleprompterTestPresentation {
    private(set) var frames: [Int: CGRect] = [:]
    private var didMeasure: (() -> Void)?

    init() {
        TeleprompterLandingProbe.didMeasure = { [weak self] frames in
            self?.frames = frames
            self?.didMeasure?()
        }
    }

    func close() { TeleprompterLandingProbe.didMeasure = nil }

    func wait(
        _ host: NSView, clock: TeleprompterTestPlaybackClock, for description: String,
        file: StaticString = #filePath, line: UInt = #line,
        until ready: @escaping @MainActor ([Int: CGRect]) -> Bool
    ) async {
        let landed = XCTestExpectation(description: description)
        var fulfilled = false
        let check = { [self] in
            if !fulfilled, ready(frames) {
                fulfilled = true
                landed.fulfill()
            }
        }
        didMeasure = check
        clock.didSchedule = check
        host.layoutSubtreeIfNeeded()
        check()
        let result = await XCTWaiter.fulfillment(of: [landed], timeout: 5)
        didMeasure = nil
        clock.didSchedule = nil
        XCTAssertEqual(result, .completed, description, file: file, line: line)
    }
}
