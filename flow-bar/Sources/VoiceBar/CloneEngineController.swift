import Darwin
import Foundation
import VoiceBarUI

enum CloneEngineObservation: Equatable { case absent, occupied, healthy(Int) }
enum CloneEngineLaunchError: Error {
    case pythonMissing, scriptMissing, sourceUnavailable
    var reason: String {
        switch self {
        case .pythonMissing: "python_missing"
        case .scriptMissing: "script_missing"
        case .sourceUnavailable: "script_unresolved"
        }
    }
}

/// Main-thread state owner. Only retained Process objects grant signal authority.
final class CloneEngineController {
    typealias Probe = (@escaping (CloneEngineObservation) -> Void) -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    typealias ProcessStopper = (Process, @escaping (Bool) -> Void) -> Void
    private enum StopPurpose { case user, startupTimeout, adopt }
    static let preferenceKey = "cloneEngineStartWithVoiceBar"
    static let startupFailureLimit = 4
    private(set) var snapshot: CloneEngineSnapshot
    var onChange: (([String: Any]) -> Void)?
    private let probe: Probe
    private let makeProcess: () throws -> Process
    private let schedule: Scheduler
    private let saveAutostart: (Bool) -> Void
    private let stopProcess: ProcessStopper
    private let diagnostic: (String) -> Void
    private var child: Process?
    private var retiring: Process?
    private var wanted = false
    private var quitting = false
    private var generation = 0
    private var failures = 0
    private var startupFailures = 0
    private var startupBlocked = false
    private var launchedAt: Date?
    private var hasServedHealth = false

    init(autostart: Bool, saveAutostart: @escaping (Bool) -> Void, probe: @escaping Probe,
         makeProcess: @escaping () throws -> Process, schedule: @escaping Scheduler = { delay, block in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
         }, stopProcess: @escaping ProcessStopper = CloneEngineController.stopAsynchronously,
         diagnostic: @escaping (String) -> Void = { _ in }) {
        snapshot = CloneEngineSnapshot(state: .stopped, since: ISO8601DateFormatter().string(from: Date()),
                                       reason: nil, pid: nil, startWithVoiceBar: autostart)
        self.saveAutostart = saveAutostart; self.probe = probe; self.makeProcess = makeProcess
        self.schedule = schedule; self.stopProcess = stopProcess; self.diagnostic = diagnostic
    }

    func open() {
        guard !quitting else { return }
        resetStartupRequest()
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
            saveAutostart(number.boolValue); onChange?(snapshot.payload)
        } else if ["start", "restart", "stop"].contains(action ?? ""), command["value"] == nil {
            if action == "start" {
                resetStartupRequest(); wanted = true; inspect(generation)
            } else if child == nil, retiring == nil, snapshot.pid != nil {
                reason = "foreign_engine"
            } else {
                generation += 1; wanted = action == "restart"
                if wanted { startupFailures = 0; startupBlocked = false; failures = 0 }
                stopOwned(.user, token: generation)
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

    /// App teardown alone may wait on main; both graceful and forced waits have deadlines.
    func quit() {
        quitting = true; wanted = false; generation += 1
        let owned = child ?? retiring
        child = nil; retiring = nil
        if let owned {
            owned.terminationHandler = nil
            let stopped = Self.stopBounded(owned)
            publish(stopped ? .stopped : .failed, reason: stopped ? "voicebar_quit" : "stop_timeout",
                    pid: stopped ? nil : Int(owned.processIdentifier))
        } else if snapshot.pid == nil { publish(.stopped, reason: "voicebar_quit") }
    }

    private func resetStartupRequest() {
        generation += 1; startupFailures = 0; startupBlocked = false; failures = 0
    }

    private func publish(_ state: CloneEngineSnapshot.State, reason: String? = nil, pid: Int? = nil) {
        guard snapshot.state != state || snapshot.reason != reason || snapshot.pid != pid else { return }
        snapshot.state = state; snapshot.reason = reason; snapshot.pid = pid
        snapshot.since = ISO8601DateFormatter().string(from: Date())
        onChange?(snapshot.payload)
    }

    private func inspect(_ token: Int) {
        guard !quitting, !startupBlocked, retiring == nil, token == generation else { return }
        probe { [weak self] result in
            guard let self, !quitting, !startupBlocked, retiring == nil, token == generation else { return }
            if let child, !child.isRunning { handleExit(child); return }
            switch result {
            case let .healthy(pid):
                if let child, child.processIdentifier != pid {
                    stopOwned(.adopt, token: token)
                    return
                }
                startupFailures = 0
                if child != nil { hasServedHealth = true }
                if let launchedAt, Date().timeIntervalSince(launchedAt) >= 60 { failures = 0 }
                publish(.running, reason: child == nil ? "adopted_existing" : nil, pid: pid)
                later(3, token: token)
            case .occupied, .absent:
                if let child, child.isRunning {
                    if !hasServedHealth, let launchedAt, Date().timeIntervalSince(launchedAt) > 120 {
                        stopOwned(.startupTimeout, token: token)
                    } else {
                        if hasServedHealth { publish(.failed, reason: "health_unavailable", pid: Int(child.processIdentifier)) }
                        later(1, token: token)
                    }
                } else if result == .occupied {
                    startupBlocked = true; generation += 1
                    diagnostic("port_occupied")
                    publish(.failed, reason: "port_occupied")
                } else if wanted { launch(token) }
                else { publish(.stopped); later(3, token: token) }
            }
        }
    }

    private func launch(_ token: Int) {
        do {
            let process = try makeProcess()
            child = process; hasServedHealth = false
            process.terminationHandler = { [weak self, weak process] _ in
                DispatchQueue.main.async {
                    guard let self, let process, self.child === process else { return }
                    self.handleExit(process)
                }
            }
            try process.run()
            launchedAt = Date()
            diagnostic("starting pid=\(process.processIdentifier)")
            publish(.starting, pid: Int(process.processIdentifier))
            later(1, token: token)
        } catch {
            child = nil
            let reason = (error as? CloneEngineLaunchError)?.reason ?? "launch_failed(\((error as NSError).code))"
            retry(reason, startupFailure: true)
        }
    }

    private func handleExit(_ process: Process) {
        guard child === process else { return }
        let early = !hasServedHealth
        child = nil; launchedAt = nil; hasServedHealth = false
        let reason = "\(early ? "exited_early" : "engine_exited")(\(process.terminationStatus))"
        if wanted, !quitting { retry(reason, startupFailure: early) }
        else { diagnostic(reason) }
    }

    private func later(_ delay: TimeInterval, token: Int) {
        schedule(delay) { [weak self] in self?.inspect(token) }
    }

    private func retry(_ reason: String, startupFailure: Bool) {
        generation += 1
        diagnostic(reason)
        if startupFailure { startupFailures += 1 }
        if startupFailures >= Self.startupFailureLimit {
            startupBlocked = true
            publish(.failed, reason: reason)
            return
        }
        failures = min(failures + 1, 6)
        publish(.restarting, reason: reason)
        later(min(30, pow(2, Double(failures - 1))), token: generation)
    }

    private func stopOwned(_ purpose: StopPurpose, token: Int) {
        // The retirement callback observes the latest generation/intent. No caller may
        // launch while this exact Process is still retained in `retiring`.
        guard retiring == nil else { return }
        guard let process = child else {
            publish(.stopped, reason: "user_stop")
            if wanted { inspect(generation) }
            return
        }
        child = nil; retiring = process; launchedAt = nil; hasServedHealth = false
        process.terminationHandler = nil
        stopProcess(process) { [weak self, weak process] stopped in
            guard let self, let process, self.retiring === process else { return }
            self.retiring = nil
            guard !self.quitting else { return }
            guard stopped else {
                self.child = process; self.wanted = false; self.generation += 1
                self.diagnostic("stop_timeout pid=\(process.processIdentifier)")
                self.publish(.failed, reason: "stop_timeout", pid: Int(process.processIdentifier))
                return
            }
            if token != self.generation {
                self.publish(.stopped, reason: "user_stop")
                if self.wanted { self.inspect(self.generation) }
                return
            }
            switch purpose {
            case .user:
                self.publish(.stopped, reason: "user_stop")
                if self.wanted { self.inspect(self.generation) }
            case .startupTimeout:
                self.retry("startup_timeout(\(process.terminationStatus))", startupFailure: true)
            case .adopt:
                // Retirement may take seconds; revalidate the external endpoint.
                self.inspect(self.generation)
            }
        }
    }

    static func stopAsynchronously(_ process: Process, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let stopped = stopBounded(process)
            DispatchQueue.main.async { completion(stopped) }
        }
    }

    private static func stopBounded(_ process: Process) -> Bool {
        if process.isRunning { process.terminate() }
        let gracefulDeadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < gracefulDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        let forcedDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning, ProcessInfo.processInfo.systemUptime < forcedDeadline { Thread.sleep(forTimeInterval: 0.01) }
        return !process.isRunning
    }
}
