import Foundation

/// Wait for a state transition instead of a fixed wall-clock sleep: returns as soon as
/// `condition` holds, or false after `timeout`. A 20 ms test timer can take far longer
/// than 100 ms to fire at background QoS or on a loaded CI runner.
@MainActor
func settle(timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
