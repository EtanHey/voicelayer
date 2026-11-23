import ApplicationServices
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// The production wiring, with the fake AX. The red run on main replaces this file with a no-op
/// `installDictationFocusRecovery`, because main has no dictation recovery to install.
func installDictationFocusRecovery(ax: SelectionFocusAX, on state: VoiceState,
                                   run: @escaping (@escaping () -> Void) -> Void) {
    DictationFocusRecovery(ax: ax, run: run, deliver: { $0() }, log: { _, _ in }).install(on: state)
}

final class DictationFocusRecoveryTests: XCTestCase {
    private typealias World = DictationPasteAfterRelaunchTests.World

    private func recovery(_ world: World, logs: @escaping ([String: String]) -> Void = { _ in }) -> DictationFocusRecovery {
        DictationFocusRecovery(ax: world.ax, run: { $0() }, deliver: { $0() }, log: { _, fields in logs(fields) })
    }

    func testOutcomes() {
        let cases: [(String, (World) -> Void, DictationFocusRecovery.Outcome, Int)] = [
            ("readable chromium", { $0.launch("c", chromium: true, axOn: true) }, .readable, 0),
            ("tree off", { $0.launch("c", chromium: true, axOn: false) }, .recovered, 1),
            ("native unreadable", { $0.launch("n", chromium: false, axOn: false) }, .notChromiumFamily, 0),
            ("refuses the flag", { $0.launch("c", chromium: true, axOn: false); $0.front?.acceptsManualAX = false },
             .enableFailed, 1),
            ("never comes up", { $0.launch("c", chromium: true, axOn: false); $0.front?.queriesUntilTreeIsOn = 99 },
             .stillUnreadable, 1),
            ("no app", { _ in }, .noFrontmostApp, 0),
        ]
        for (name, setup, expected, sets) in cases {
            let world = World()
            setup(world)
            XCTAssertEqual(recovery(world).recover(phase: "test"), expected, name)
            XCTAssertEqual(world.sets.count, sets, name)
        }
    }

    func testWaitIsBoundedAndLogsStatusesWithoutText() {
        let world = World()
        world.launch("c", chromium: true, axOn: false)
        world.front?.queriesUntilTreeIsOn = 99
        var logged: [String: String] = [:]
        _ = recovery(world, logs: { logged = $0 }).recover(phase: "ready")
        XCTAssertEqual(world.focusQueries, 1 + DictationFocusRecovery.retryLimit)
        XCTAssertLessThanOrEqual(Double(DictationFocusRecovery.retryLimit) * DictationFocusRecovery.retryStep, 2.0)
        XCTAssertEqual(logged["outcome"], "still_unreadable")
        XCTAssertEqual(logged["ax_status"], String(AXError.noValue.rawValue))
        XCTAssertEqual(logged["manual_ax_attempted"], "true")
        XCTAssertEqual(logged["retries"], String(DictationFocusRecovery.retryLimit))
        XCTAssertEqual(Set(logged.keys), ["phase", "outcome", "ax_status", "pid", "manual_ax_attempted",
                                          "manual_ax_status", "retries", "retry_statuses"])
    }

    func testUntrustedAndOtherErrorsNeverTouchTheApp() {
        for status in [AXError.apiDisabled, .failure, .notImplemented] {
            let world = World()
            world.launch("c", chromium: true, axOn: false)
            var ax = world.ax
            ax.queryFocus = { (status, nil) }
            let outcome = DictationFocusRecovery(ax: ax, run: { $0() }, deliver: { $0() }, log: { _, _ in })
                .recover(phase: "test")
            XCTAssertEqual(outcome, .notRecoverable)
            XCTAssertEqual(world.sets, [])
        }
        let world = World()
        world.launch("c", chromium: true, axOn: false)
        var ax = world.ax
        ax.trusted = { false }
        XCTAssertEqual(DictationFocusRecovery(ax: ax, run: { $0() }, deliver: { $0() }, log: { _, _ in })
            .recover(phase: "test"), .untrusted)
        XCTAssertEqual(world.sets, [])
    }

    /// The kick runs on its own queue: `record` returns, and the take's record command is sent,
    /// before the recovery has made a single AX call.
    func testRecordStartNeverWaitsForTheKick() throws {
        let kit = DictationPasteAfterRelaunchTests.Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        kit.queued = []
        kit.state.record(pressToTalk: true)
        XCTAssertEqual(kit.commands.last?["cmd"] as? String, "record")
        XCTAssertEqual(kit.world.focusQueries, 0)
        XCTAssertEqual(kit.queued?.count, 1)
        kit.drain()
        XCTAssertEqual(kit.world.sets.count, 1)
    }

    /// Conformance with formal/ready-time-paste, Fixed.cfg. The model's target-app variables are
    /// chromium, axOn, accepts (the tree comes up after AXManualAccessibility), Relaunch (before the take
    /// or after the key-down Kick) and whether the input is a secure field. For every combination the
    /// Swift path must end where the model's Fixed spec ends: delivered exactly once into that input when
    /// the ready-time focus is readable after recovery and not secure, otherwise a visible refusal with
    /// the words kept; and AXManualAccessibility only ever on a Chromium-family app.
    func testReadyTimePasteModelFixedConformance() throws {
        let formal = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../formal/ready-time-paste").standardized
        let cfg = try String(contentsOf: formal.appendingPathComponent("Fixed.cfg"), encoding: .utf8)
        for knob in ["Recover = TRUE", "KickOnly = FALSE", "RecoverAnyApp = FALSE", "CacheByBundle = FALSE",
                     "SilentDecline = FALSE", "AllowSecure = FALSE", "OldPolicy = FALSE"] {
            XCTAssertTrue(cfg.contains(knob), "Fixed.cfg no longer pins \(knob); update this mirror")
        }
        let spec = try String(contentsOf: formal.appendingPathComponent("ReadyTimePaste.tla"), encoding: .utf8)
        for name in ["Relaunch ==", "Kick ==", "RelaunchedTargetRecovered ==", "DeliveredOrVisiblyDeclined ==",
                     "NativeNeverTouched =="] {
            XCTAssertTrue(spec.contains(name), name)
        }
        var cases = 0
        for chromium in [true, false] { for axOn in [true, false] { for accepts in [true, false] {
            for relaunch in ["none", "before", "during"] { for secure in [false, true] {
                // The model's Fixed transitions, in order: Init, Relaunch?, Record + Kick, Relaunch?, Ready.
                var tree = axOn
                if relaunch == "before", chromium { tree = false }
                if !tree, chromium { tree = accepts }               // Kick
                if relaunch == "during", chromium { tree = false }
                if !tree, chromium { tree = accepts }               // Ready's recovery
                let delivered = tree && !secure
                let name = "chromium=\(chromium) axOn=\(axOn) accepts=\(accepts) relaunch=\(relaunch) secure=\(secure)"

                let kit = DictationPasteAfterRelaunchTests.Kit()
                kit.world.launch(chromium ? "com.example.electron" : "com.example.native", chromium: chromium, axOn: axOn)
                kit.world.front?.acceptsManualAX = accepts
                kit.world.front?.secure = secure
                if relaunch == "before" { kit.world.relaunch() }
                let id = try kit.start()
                if relaunch == "during" { kit.world.relaunch() }
                kit.final(id); kit.final(id)

                XCTAssertEqual(kit.typed.count + kit.writes.count, delivered ? 1 : 0, name)
                XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום", name)
                if !delivered {
                    XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted, name)
                    XCTAssertNotNil(kit.state.confirmationText, "visible refusal: \(name)")
                }
                if !chromium { XCTAssertEqual(kit.world.sets, [], name) }
                cases += 1
            } }
        } } }
        XCTAssertEqual(cases, 48)
    }

    /// Option+F5 and dictation share one recovery: the selection preflight's set and re-queries
    /// are exactly `enableManualAccessibility`'s.
    func testSelectionPreflightUsesTheSharedRecovery() {
        let world = World()
        world.launch("c", chromium: true, axOn: false)
        world.front?.queriesUntilTreeIsOn = 3
        let result = SpeakSelectionCapture.preflight(world.ax, recover: true, copyExemptApp: nil)
        XCTAssertNil(result.blockReason)
        XCTAssertEqual(result.axEnable, .set)
        XCTAssertEqual(result.retries, 3)
        XCTAssertEqual(result.details["preflight_initial_retry_statuses"],
                       [AXError.noValue, .noValue, .success].map { String($0.rawValue) }.joined(separator: ","))
        XCTAssertEqual(world.sets.count, 1)
    }
}
