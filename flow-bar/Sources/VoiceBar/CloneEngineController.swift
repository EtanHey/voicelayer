import Darwin
import Foundation
import VoiceBarUI

enum CloneEngineObservation: Equatable { case absent, occupied, healthy(Int) }

/// Main-thread owner. Observation never grants signal authority; only a retained Process does.
final class CloneEngineController {
    typealias Probe = (@escaping (CloneEngineObservation) -> Void) -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    static let preferenceKey = "cloneEngineStartWithVoiceBar"
    private(set) var snapshot: CloneEngineSnapshot
    var onChange: (([String: Any]) -> Void)?
    private let probe: Probe
    private let makeProcess: () throws -> Process
    private let schedule: Scheduler
    private let saveAutostart: (Bool) -> Void
    private var child: Process?
    private var wanted = false
    private var quitting = false
    private var generation = 0
    private var failures = 0
    private var launchedAt: Date?

    init(autostart: Bool, saveAutostart: @escaping (Bool) -> Void, probe: @escaping Probe,
         makeProcess: @escaping () throws -> Process, schedule: @escaping Scheduler = { delay, block in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
         }) {
        snapshot = CloneEngineSnapshot(state: .stopped, since: ISO8601DateFormatter().string(from: Date()),
                                       reason: nil, pid: nil, startWithVoiceBar: autostart)
        self.saveAutostart = saveAutostart; self.probe = probe
        self.makeProcess = makeProcess; self.schedule = schedule
    }

    func open() {
        guard !quitting else { return }
        wanted = snapshot.startWithVoiceBar
        inspect(generation)
    }

    func handle(_ command: [String: Any]) -> [String: Any] {
        let action = command["action"] as? String
        var reason: String?
        if quitting { reason = "quitting" }
        else if command["cmd"] as? String != "clone_engine" { reason = "invalid_command" }
        else if action == "set_autostart", let number = command["value"] as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID() {
            snapshot.startWithVoiceBar = number.boolValue
            saveAutostart(number.boolValue)
            onChange?(snapshot.payload)
        } else if ["start", "restart", "stop"].contains(action ?? ""), command["value"] == nil {
            if action == "start" {
                generation += 1; wanted = true
                inspect(generation)
            } else if child == nil, snapshot.pid != nil {
                // Never signal an adopted PID, even on explicit restart/stop.
                reason = "foreign_engine"
            } else {
                generation += 1; wanted = action == "restart"
                stopOwned()
                publish(.stopped, reason: "user_stop")
                if wanted { inspect(generation) }
            }
        } else { reason = "invalid_command" }
        return Self.acknowledgement(command, reason: reason)
    }

    static func acknowledgement(_ command: [String: Any], reason: String?) -> [String: Any] {
        var ack: [String: Any] = ["type": "ack", "command": "clone_engine", "outcome": reason == nil ? "accept" : "reject"]
        if let reason { ack["reason"] = reason }
        if let id = command["id"] as? String { ack["id"] = id }
        return ack
    }

    func quit() {
        quitting = true; wanted = false; generation += 1
        let owned = child != nil
        stopOwned()
        if owned || snapshot.pid == nil { publish(.stopped, reason: "voicebar_quit") }
    }

    private func publish(_ state: CloneEngineSnapshot.State, reason: String? = nil, pid: Int? = nil) {
        guard snapshot.state != state || snapshot.reason != reason || snapshot.pid != pid else { return }
        snapshot.state = state; snapshot.reason = reason; snapshot.pid = pid
        snapshot.since = ISO8601DateFormatter().string(from: Date())
        onChange?(snapshot.payload)
    }

    private func inspect(_ token: Int) {
        guard !quitting, token == generation else { return }
        probe { [weak self] result in
            guard let self, !quitting, token == generation else { return }
            if let child, !child.isRunning {
                self.child = nil; launchedAt = nil
                if wanted { retry("engine_exited"); return }
            }
            switch result {
            case let .healthy(pid):
                if let child, child.processIdentifier != pid { stopOwned() }
                if let launchedAt, Date().timeIntervalSince(launchedAt) >= 60 { failures = 0 }
                publish(.running, reason: child == nil ? "adopted_existing" : nil, pid: pid)
                later(3, token: token)
            case .occupied, .absent:
                if let child, child.isRunning {
                    if let launchedAt, Date().timeIntervalSince(launchedAt) > 120 {
                        stopOwned(); retry("startup_timeout")
                    } else { later(1, token: token) }
                } else if result == .occupied {
                    publish(.failed, reason: "port_occupied")
                    later(3, token: token)
                } else if wanted {
                    // Each spawn is reached only after a new, serialized observation.
                    do {
                        let process = try makeProcess()
                        child = process
                        process.terminationHandler = { [weak self, weak process] _ in
                            DispatchQueue.main.async {
                                guard let self, let process, self.child === process else { return }
                                self.child = nil; self.launchedAt = nil
                                if self.wanted, !self.quitting { self.retry("engine_exited") }
                            }
                        }
                        try process.run()
                        launchedAt = Date()
                        publish(.starting, pid: Int(process.processIdentifier))
                        later(1, token: token)
                    } catch {
                        child = nil; retry("launch_failed")
                    }
                } else {
                    publish(.stopped)
                    later(3, token: token)
                }
            }
        }
    }

    private func later(_ delay: TimeInterval, token: Int) {
        schedule(delay) { [weak self] in self?.inspect(token) }
    }

    private func retry(_ reason: String) {
        // Cancel all earlier health polls before arming the only restart timer.
        generation += 1
        failures = min(failures + 1, 6)
        publish(.restarting, reason: reason)
        later(min(30, pow(2, Double(failures - 1))), token: generation)
    }

    private func stopOwned() {
        guard let process = child else { return }
        child = nil; launchedAt = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
    }
}
