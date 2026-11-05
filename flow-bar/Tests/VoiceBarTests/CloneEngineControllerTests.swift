import Foundation
import XCTest
@testable import VoiceBar
@testable import VoiceBarUI

final class CloneEngineControllerTests: XCTestCase {
    func testDefaultOnStartsAndQuitStopsOnlyTheOwnedFakeHTTPChild() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.process?.isRunning == true })
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        fixture.tick()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
        XCTAssertEqual(fixture.controller.snapshot.pid, Int(fixture.process!.processIdentifier))
        fixture.controller.quit()
        XCTAssertFalse(fixture.process!.isRunning)
        XCTAssertEqual(fixture.controller.snapshot.state, .stopped)
    }

    func testAdoptsExistingFakeAndNeverStopsOrRestartsIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let foreign = try fixture.launchFake()
        fixture.process = foreign
        try foreign.run()
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
        XCTAssertEqual(fixture.launchCount, 1)
        for action in ["stop", "restart"] {
            let ack = fixture.controller.handle(["cmd": "clone_engine", "action": action, "id": "foreign"])
            XCTAssertEqual(ack["outcome"] as? String, "reject")
            XCTAssertEqual(ack["reason"] as? String, "foreign_engine")
            XCTAssertTrue(foreign.isRunning)
        }
        fixture.controller.quit()
        XCTAssertTrue(foreign.isRunning)
    }

    func testCrashBackoffAndStopInvalidatesQueuedRestart() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.process?.isRunning == true })
        fixture.process!.terminate()
        fixture.process!.waitUntilExit()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .restarting })
        XCTAssertTrue(fixture.delays.contains(1))
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "stop"])
        fixture.tick()
        XCTAssertEqual(fixture.launchCount, 1)
        XCTAssertEqual(fixture.controller.snapshot.state, .stopped)
    }

    func testAutostartOffPersistsButManualStartStillWorks() throws {
        let fixture = try Fixture(autostart: false)
        defer { fixture.cleanup() }
        fixture.controller.open()
        fixture.tick()
        XCTAssertEqual(fixture.launchCount, 0)
        let ack = fixture.controller.handle(["cmd": "clone_engine", "action": "set_autostart", "value": true, "id": "pref"])
        XCTAssertEqual(ack["id"] as? String, "pref")
        XCTAssertEqual(fixture.saved, true)
        XCTAssertTrue(fixture.controller.snapshot.startWithVoiceBar)
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "start"])
        XCTAssertTrue(fixture.wait { fixture.process?.isRunning == true })
    }

    func testCrashRestartsOwnedChildAndRepeatedStartDoesNotDuplicateIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        let original = try XCTUnwrap(fixture.process)
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "start"])
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
        XCTAssertEqual(fixture.launchCount, 1)
        original.terminate(); original.waitUntilExit()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .restarting })
        fixture.tick()
        XCTAssertTrue(fixture.wait { fixture.launchCount == 2 && fixture.port != nil })
        fixture.tick()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
        XCTAssertNotEqual(fixture.controller.snapshot.pid, Int(original.processIdentifier))
        let replacement = try XCTUnwrap(fixture.process)
        replacement.terminate(); replacement.waitUntilExit()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .restarting })
        XCTAssertEqual(fixture.delays.last, 2, "An early crash must increase backoff")
    }

    func testExplicitRestartReplacesOnlyTheOwnedChildAndInvalidCommandsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        let old = try XCTUnwrap(fixture.process)
        let ack = fixture.controller.handle(["cmd": "clone_engine", "action": "restart"])
        XCTAssertEqual(ack["outcome"] as? String, "accept")
        XCTAssertTrue(fixture.wait { !old.isRunning && fixture.launchCount == 2 })
        let invalidPayloads: [[String: Any]] = [["cmd": "clone_engine", "action": "set_autostart", "value": 1],
            ["cmd": "clone_engine", "action": "start", "value": true], ["cmd": "clone_engine", "action": "kill"]]
        for payload in invalidPayloads {
            XCTAssertEqual(fixture.controller.handle(payload)["outcome"] as? String, "reject")
        }
    }

    func testMissedHealthAfterReadinessReportsFailureWithoutInterruptingOwnedReply() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        fixture.tick()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
        let process = try XCTUnwrap(fixture.process)
        fixture.observationOverride = .occupied
        fixture.tick()
        XCTAssertEqual(fixture.controller.snapshot.state, .failed)
        XCTAssertEqual(fixture.controller.snapshot.reason, "health_unavailable")
        XCTAssertEqual(fixture.controller.snapshot.pid, Int(process.processIdentifier))
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(fixture.launchCount, 1)
        fixture.observationOverride = nil
        fixture.tick()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
    }

    func testStopWinsAgainstInFlightAbsentProbe() throws {
        var pending: ((CloneEngineObservation) -> Void)?
        var spawns = 0
        let controller = CloneEngineController(autostart: true, saveAutostart: { _ in },
            probe: { pending = $0 }, makeProcess: { spawns += 1; return Process() }, schedule: { _, _ in })
        controller.open()
        _ = controller.handle(["cmd": "clone_engine", "action": "stop"])
        pending?(.absent)
        XCTAssertEqual(spawns, 0)
        XCTAssertEqual(controller.snapshot.state, .stopped)
    }

    func testOccupiedUnverifiedPortFailsClosed() {
        var spawns = 0
        let controller = CloneEngineController(autostart: true, saveAutostart: { _ in },
            probe: { $0(.occupied) }, makeProcess: { spawns += 1; return Process() }, schedule: { _, _ in })
        controller.open()
        XCTAssertEqual(controller.snapshot.state, .failed)
        XCTAssertEqual(controller.snapshot.reason, "port_occupied")
        XCTAssertEqual(spawns, 0)
    }

    func testStopAcknowledgesBeforeRetirementAndStopWinsOverPendingRestart() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var finishStop: ((Bool) -> Void)?
        fixture.stopOverride = { _, done in finishStop = done }
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        let original = try XCTUnwrap(fixture.process)
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "restart"])
        XCTAssertNotNil(finishStop)
        XCTAssertTrue(original.isRunning, "Acknowledgement must not wait for process exit")
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "start"])
        fixture.tick()
        XCTAssertEqual(fixture.launchCount, 1, "No replacement while the retained child retires")
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "stop"])
        original.terminate(); original.waitUntilExit()
        finishStop?(true)
        fixture.tick()
        XCTAssertEqual(fixture.controller.snapshot.state, .stopped)
        XCTAssertEqual(fixture.launchCount, 1)
    }

    func testDefaultStopperKeepsMainQueueResponsiveDuringStubbornChildRetirement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.stubborn = true
        fixture.controller.open()
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        let original = try XCTUnwrap(fixture.process)
        var mainAdvanced = false
        DispatchQueue.main.async { mainAdvanced = true }
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "stop"])
        XCTAssertTrue(original.isRunning, "SIGTERM-ignoring child should retire after the command returns")
        XCTAssertTrue(fixture.wait { mainAdvanced })
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .stopped && !original.isRunning })
    }

    func testFourPreflightFailuresLatchSpecificCauseUntilExplicitStartOrOpen() {
        for cause in [CloneEngineLaunchError.pythonMissing, .scriptMissing] {
            var attempts = 0
            var timers: [() -> Void] = []
            let controller = CloneEngineController(autostart: true, saveAutostart: { _ in }, probe: { $0(.absent) },
                makeProcess: { attempts += 1; throw cause }, schedule: { _, block in timers.append(block) })
            controller.open()
            for _ in 0..<3 { let batch = timers; timers = []; batch.forEach { $0() } }
            XCTAssertEqual(attempts, 4)
            XCTAssertEqual(controller.snapshot.state, .failed)
            XCTAssertEqual(controller.snapshot.reason, cause.reason)
            XCTAssertTrue(timers.isEmpty, "No automatic retry after the fourth startup failure")
            _ = controller.handle(["cmd": "clone_engine", "action": "start"])
            XCTAssertEqual(attempts, 5)
            XCTAssertEqual(controller.snapshot.state, .restarting)
            controller.quit()
        }
    }

    func testEarlyExitCarriesStatusAndLatchesAfterFourThenManualRestartRecovers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.exitCode = 23
        fixture.controller.open()
        for count in 1...4 {
            XCTAssertTrue(fixture.wait { fixture.launchCount == count && fixture.controller.snapshot.state == (count == 4 ? .failed : .restarting) })
            if count < 4 { fixture.tick() }
        }
        XCTAssertEqual(fixture.controller.snapshot.reason, "exited_early(23)")
        fixture.tick()
        XCTAssertEqual(fixture.launchCount, 4)
        fixture.exitCode = nil
        _ = fixture.controller.handle(["cmd": "clone_engine", "action": "restart"])
        XCTAssertTrue(fixture.wait { fixture.port != nil })
        fixture.tick()
        XCTAssertTrue(fixture.wait { fixture.controller.snapshot.state == .running })
        XCTAssertEqual(fixture.launchCount, 5)
    }

    func testEngineStdoutStderrAndExitStatusReachTheIsolatedLog() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let logger = CloneEngineLog(url: fixture.directory.appendingPathComponent("clone-engine.log"), maxBytes: 4096)
        fixture.logger = logger
        fixture.exitCode = 23
        fixture.controller.open()
        XCTAssertTrue(fixture.wait {
            logger.flush()
            let data = (try? Data(contentsOf: logger.url)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            return text.contains("fake stdout") && text.contains("fake stderr") && text.contains("exited_early(23)")
        })
    }

    private final class Fixture {
        let directory: URL
        var process: Process?
        var launchCount = 0
        var saved: Bool?
        var observationOverride: CloneEngineObservation?
        var stopOverride: CloneEngineController.ProcessStopper?
        var stubborn = false
        var exitCode: Int?
        var logger: CloneEngineLog?
        var tasks: [() -> Void] = []
        var delays: [TimeInterval] = []
        let autostart: Bool
        var port: Int? { (try? String(contentsOf: directory.appendingPathComponent("port"))).flatMap(Int.init) }
        lazy var controller = CloneEngineController(autostart: autostart, saveAutostart: { self.saved = $0 },
            probe: { completion in
                if let override = self.observationOverride { completion(override); return }
                guard self.process?.isRunning == true, let port = self.port else { completion(.absent); return }
                CloneEngineProbe.inspect(url: URL(string: "http://127.0.0.1:\(port)/health")!,
                    tokenFile: self.directory.appendingPathComponent("secret").path, completion: completion)
            }, makeProcess: { self.process = try self.launchFake(); return self.process! },
            schedule: { delay, block in self.delays.append(delay); self.tasks.append(block) },
            stopProcess: { process, done in
                if let stop = self.stopOverride { stop(process, done) }
                else { CloneEngineController.stopAsynchronously(process, completion: done) }
            }, diagnostic: { self.logger?.appendLine($0) })
        init(autostart: Bool = true) throws {
            self.autostart = autostart
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("fake-engine-token".utf8).write(to: directory.appendingPathComponent("secret"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("secret").path)
        }
        func launchFake() throws -> Process {
            launchCount += 1
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("port"))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [Bundle.module.url(forResource: "clone-engine-fake", withExtension: "py")!.path,
                                 directory.appendingPathComponent("port").path] + (stubborn ? ["--ignore-term"] : [])
            if let exitCode {
                process.arguments = ["-c", "import sys; print('fake stdout', flush=True); print('fake stderr', file=sys.stderr, flush=True); sys.exit(\(exitCode))"]
            }
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            logger?.attach(to: process)
            // The controller owns run(); foreign fixtures start explicitly below.
            return process
        }
        func tick() { let batch = tasks; tasks = []; batch.forEach { $0() } }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        func cleanup() {
            controller.quit()
            if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
