import AppKit
import ApplicationServices
@testable import VoiceBar
@testable import VoiceBarUI
import XCTest

/// T23 (M4, 18 Nov): after T3 Code relaunched, every F5 auto-paste into it ended "Nothing to paste into;
/// kept in History" (`paste_native_focus reason=focused_element_unavailable`), while Shift+F5 typing worked.
///
/// These run the real ready-time capture and paste decisions in VoiceState and the real recovery wiring
/// (`installDictationFocusRecovery`) against one fake macOS: a frontmost app whose focus query answers
/// kAXErrorNoValue until AXManualAccessibility is set, as the Option+F5 path already assumes.
/// The file compiles on main, where that wiring does not exist, so the red run swaps in a no-op helper.
final class DictationPasteAfterRelaunchTests: XCTestCase {
    final class App: NSRunningApplication, @unchecked Sendable {
        let name: String?
        let pid: pid_t
        init(_ name: String?, _ pid: pid_t) { self.name = name; self.pid = pid; super.init() }
        override var bundleIdentifier: String? { name }
        override var processIdentifier: pid_t { pid }
    }

    /// One fake desktop. `axOn` belongs to the process: a relaunch makes a new one with its tree off.
    final class World {
        struct Process {
            var identity: SelectionFocusAX.AppIdentity
            var app: App
            var chromium: Bool
            var axOn: Bool
            var acceptsManualAX = true
            /// How many focus queries after the set still answer NoValue (Chromium builds its tree lazily).
            var queriesUntilTreeIsOn = 0
            var field = "composer"
            var secure = false
        }
        var front: Process?
        var sets: [SelectionFocusAX.AppIdentity] = []
        var focusQueries = 0
        private var nextPID: pid_t = 21_000

        func launch(_ bundle: String, chromium: Bool, axOn: Bool) {
            nextPID += 1
            front = Process(identity: .init(pid: nextPID, startTime: UInt64(nextPID) * 10),
                            app: App(bundle, nextPID), chromium: chromium, axOn: axOn)
        }
        /// The update button: quit and relaunch. New pid, new start time, and a Chromium tree that is off again.
        func relaunch() {
            guard let old = front else { return }
            launch(old.app.name ?? "", chromium: old.chromium, axOn: !old.chromium && old.axOn)
            front?.field = old.field
            front?.secure = old.secure
            front?.acceptsManualAX = old.acceptsManualAX
            front?.queriesUntilTreeIsOn = old.queriesUntilTreeIsOn
        }
        var focusReadable: Bool { front?.axOn == true }

        var ax: SelectionFocusAX {
            SelectionFocusAX(
                secureInputEnabled: { false },
                trusted: { true },
                queryFocus: { [unowned self] in
                    focusQueries += 1
                    guard var process = front else { return (.noValue, nil) }
                    if !process.axOn, process.queriesUntilTreeIsOn > 0, sets.contains(process.identity) {
                        process.queriesUntilTreeIsOn -= 1
                        if process.queriesUntilTreeIsOn == 0 { process.axOn = true }
                        front = process
                    }
                    guard process.axOn else { return (.noValue, nil) }
                    return (.success, .init(role: "AXTextArea", subrole: process.secure ? "AXSecureTextField" : nil))
                },
                frontmostApp: { [unowned self] in front?.identity },
                isChromiumFamily: { [unowned self] app in front?.identity == app && front?.chromium == true },
                setManualAccessibility: { [unowned self] app in
                    sets.append(app)
                    guard var process = front, process.identity == app else { return .cannotComplete }
                    guard process.chromium, process.acceptsManualAX else { return .attributeUnsupported }
                    if process.queriesUntilTreeIsOn == 0 { process.axOn = true }
                    front = process
                    return .success
                },
                sleep: { _ in })
        }
    }

    final class Kit {
        let world = World()
        let state = VoiceState(recentTranscriptionsLoader: { [] }, recentTranscriptionsSaver: { _ in },
            recentTranscriptionEntriesLoader: { [] }, recentTranscriptionEntriesSaver: { _ in })
        var typed: [String] = [], writes: [String] = [], commands: [[String: Any]] = []
        /// Off-main work the recovery queued; `drain()` runs it. Nil runs it inline.
        var queued: [() -> Void]?

        init() {
            state.isConnected = true
            state.frontmostAppProvider = { [unowned self] in world.front?.app }
            state.sendCommand = { [unowned self] in commands.append($0) }
            state.targetAppActivator = { _ in XCTFail("Automatic delivery must not steal focus") }
            state.pasteScheduler = { _, work in work() }
            state.pasteboardWriter = { _ in XCTFail("Keep the user's clipboard") }
            state.chromiumFamilyAppDetector = { [unowned self] app in
                world.front?.app.processIdentifier == app.processIdentifier && world.front?.chromium == true
            }
            // Mirrors CommandModeAXHelper.captureFocusedTargetEligibility: no readable focus, no target.
            state.focusedTargetEligibilityProvider = { [unowned self] in
                guard let process = world.front, world.focusReadable else { return nil }
                let pid = process.app.processIdentifier, field = process.field
                return DictationFocusedTargetEligibility(processIdentifier: pid, role: "AXTextArea",
                    isEditable: true, isSecure: process.secure,
                    matchesCurrentFocus: { [unowned self] in
                        world.focusReadable && world.front?.app.processIdentifier == pid && world.front?.field == field
                    })
            }
            state.dictationTargetIdentityProvider = { [unowned self] in
                guard world.focusReadable, let pid = world.front?.app.processIdentifier else { return nil }
                return { [unowned self] in world.focusReadable && world.front?.app.processIdentifier == pid }
            }
            state.asyncDictationInsertionHandlerProvider = { [unowned self] in
                guard world.focusReadable, let field = world.front?.field else { return nil }
                return { [unowned self] text, done in writes.append(field + ":" + text); done(.verified); return true }
            }
            state.ownedTextTypingHandler = { [unowned self] text, pid, matches in
                guard matches(), world.front?.app.processIdentifier == pid else { return .focusChanged }
                typed.append("\(world.front?.app.name ?? "nil")#\(pid):" + text)
                return .posted
            }
            installDictationFocusRecovery(ax: world.ax, on: state) { [unowned self] work in
                if queued != nil { queued?.append(work) } else { work() }
            }
        }
        func drain() { while let work = queued?.first { queued?.removeFirst(); work() } }
        func start() throws -> String {
            // The previous take (if any) has finished: the daemon reports no jobs.
            if state.processingTakeCount > 0 { state.handleEvent(["type": "state", "state": "idle", "recording_jobs": []]) }
            let before = commands.count
            state.record(pressToTalk: true)
            let record = try XCTUnwrap(commands.dropFirst(before).last { $0["cmd"] as? String == "record" })
            let id = try XCTUnwrap(record["take_id"] as? String)
            state.pendingIntent = nil // the daemon's acknowledgement, as in F5PauseConformanceTests
            state.handleEvent(["type": "state", "state": "transcribing", "recording_jobs": [
                ["take_id": id, "kind": "live", "phase": "processing"]]])
            return id
        }
        func final(_ id: String, text: String = "whole fu… שלום") {
            state.handleEvent(["type": "transcription", "take_id": id, "job_kind": "live",
                "delivery_id": id, "text": text])
        }
    }

    // MARK: fail-first: the owner's case

    func testRelaunchedT3CodeWithItsTreeOffGetsTheTranscriptExactlyOnce() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        let id = try kit.start()
        kit.final(id); kit.final(id)
        let pid = try XCTUnwrap(kit.world.front?.app.processIdentifier)
        XCTAssertEqual(kit.typed, ["com.t3tools.t3code#\(pid):whole fu… שלום"])
        XCTAssertEqual(kit.writes, [], "a rich host is typed, never written through AX")
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .typed)
        XCTAssertEqual(kit.world.sets.map(\.pid), [pid], "asked once, at record start")
    }

    func testTreeThatComesUpOnlyAfterSeveralQueriesStillDelivers() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        kit.world.front?.queriesUntilTreeIsOn = 5
        kit.queued = []
        let id = try kit.start()
        kit.final(id)
        kit.drain()
        XCTAssertEqual(kit.typed.count, 1)
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
    }

    func testAppRelaunchingBetweenTwoTakesRecoversAgain() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        let first = try kit.start(); kit.final(first, text: "one")
        let firstPID = try XCTUnwrap(kit.world.front?.app.processIdentifier)
        kit.world.relaunch()
        let secondPID = try XCTUnwrap(kit.world.front?.app.processIdentifier)
        XCTAssertNotEqual(firstPID, secondPID)
        let second = try kit.start(); kit.final(second, text: "two")
        XCTAssertEqual(kit.typed, ["com.t3tools.t3code#\(firstPID):one", "com.t3tools.t3code#\(secondPID):two"])
        XCTAssertEqual(kit.world.sets.map(\.pid), [firstPID, secondPID])
    }

    func testAppRelaunchingDuringTheTakeIsRecoveredAtReadyTime() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        let id = try kit.start()
        XCTAssertTrue(kit.world.focusReadable, "the key-down kick turned the first process's tree on")
        kit.world.relaunch()
        kit.final(id)
        let pid = try XCTUnwrap(kit.world.front?.app.processIdentifier)
        XCTAssertEqual(kit.typed, ["com.t3tools.t3code#\(pid):whole fu… שלום"])
    }

    // MARK: rules that must not move

    func testNonChromiumAppWithUnreadableFocusIsNeverTouchedAndRefusalIsVisible() throws {
        let kit = Kit()
        kit.world.launch("com.example.native", chromium: false, axOn: false)
        let id = try kit.start()
        kit.final(id)
        XCTAssertEqual(kit.world.sets, [], "AXManualAccessibility is only for the Chromium family")
        XCTAssertEqual(kit.typed, []); XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; kept in History")
    }

    func testSecureFieldRevealedByRecoveryIsStillRefused() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        kit.world.front?.secure = true
        let id = try kit.start()
        kit.final(id)
        XCTAssertEqual(kit.typed, []); XCTAssertEqual(kit.writes, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted)
    }

    func testChromiumAppRefusingManualAccessibilityKeepsTheWordsAndSaysSo() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: false)
        kit.world.front?.acceptsManualAX = false
        let id = try kit.start()
        kit.final(id)
        XCTAssertEqual(kit.typed, [])
        XCTAssertEqual(kit.state.latestReusableTranscript, "whole fu… שלום")
        XCTAssertEqual(kit.state.latestDictationInsertionStatus, .notInserted)
        XCTAssertEqual(kit.state.confirmationText, "Nothing to paste into; kept in History")
    }

    func testReadableTargetIsNeverTouched() throws {
        let kit = Kit()
        kit.world.launch("com.t3tools.t3code", chromium: true, axOn: true)
        let id = try kit.start()
        kit.final(id)
        XCTAssertEqual(kit.typed.count, 1)
        XCTAssertEqual(kit.world.sets, [])
    }
}
