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
            XCTAssertEqual(ack["ok"] as? Bool, false)
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

    private final class Fixture {
        let directory: URL
        var process: Process?
        var launchCount = 0
        var saved: Bool?
        var tasks: [() -> Void] = []
        var delays: [TimeInterval] = []
        let autostart: Bool
        var port: Int? { (try? String(contentsOf: directory.appendingPathComponent("port"))).flatMap(Int.init) }
        lazy var controller = CloneEngineController(autostart: autostart, saveAutostart: { self.saved = $0 },
            probe: { completion in
                guard let port = self.port else { completion(.absent); return }
                CloneEngineProbe.inspect(url: URL(string: "http://127.0.0.1:\(port)/health")!,
                    tokenFile: self.directory.appendingPathComponent("secret").path, completion: completion)
            }, makeProcess: { self.process = try self.launchFake(); return self.process! },
            schedule: { delay, block in self.delays.append(delay); self.tasks.append(block) })
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
            process.arguments = [Bundle.module.url(forResource: "clone-engine-fake", withExtension: "py", subdirectory: "Fixtures")!.path,
                                 directory.appendingPathComponent("port").path]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
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
