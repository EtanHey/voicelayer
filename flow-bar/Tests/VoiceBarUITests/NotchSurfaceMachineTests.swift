@testable import VoiceBarUI
import XCTest

/// 2.4 Lane A: the one notch surface. Every transition, every refusal, and an exhaustive walk of the Swift
/// machine that checks the same invariants TLC checks in formal/notch-surface.
final class NotchSurfaceMachineTests: XCTestCase {
    // MARK: Transitions

    func testHistoryOpensCollapsedAndRemembersItsDetent() {
        var machine = NotchSurfaceMachine()
        XCTAssertEqual(machine.state, .closed)
        XCTAssertEqual(machine.send(.openHistory), .changed(from: .closed, to: .history(.collapsed)))
        XCTAssertEqual(machine.send(.setHistoryDetent(.expanded)), .changed(from: .history(.collapsed), to: .history(.expanded)))
        machine.send(.dismiss(.escape))
        XCTAssertEqual(machine.state, .closed)
        machine.send(.openHistory)
        XCTAssertEqual(machine.state, .history(.expanded), "History reopens where the handle left it")
    }

    func testOnlyOneDrawerAtATime() {
        var machine = NotchSurfaceMachine()
        machine.send(.openHistory)
        machine.send(.openSettings(.general))
        XCTAssertEqual(machine.drawer, .settings(.general), "Settings replaces History, never stacks on it")
        machine.send(.selectSettingsTab(.speech))
        XCTAssertEqual(machine.state, .settings(.speech))
        machine.send(.openHistory)
        XCTAssertEqual(machine.drawer, .history(.collapsed))
    }

    func testDetentAndTabChangesNeedTheirDrawer() {
        var machine = NotchSurfaceMachine()
        XCTAssertEqual(machine.send(.setHistoryDetent(.expanded)), .refused(.noDrawer))
        XCTAssertEqual(machine.send(.selectSettingsTab(.dictionary)), .refused(.noDrawer))
        machine.send(.openSettings(.general))
        XCTAssertEqual(machine.send(.setHistoryDetent(.expanded)), .refused(.noDrawer))
        XCTAssertEqual(machine.send(.dismiss(.toggle)), .changed(from: .settings(.general), to: .closed))
        XCTAssertEqual(machine.send(.dismiss(.toggle)), .refused(.noDrawer))
    }

    func testRecordingClosesAnyDrawerAndRefusesNewOnes() {
        for drawerOpen in [NotchSurfaceEvent.openHistory, .openSettings(.transcription)] {
            var machine = NotchSurfaceMachine()
            machine.send(drawerOpen)
            machine.send(.recordingChanged(true))
            XCTAssertEqual(machine.state, .recording)
            XCTAssertNil(machine.drawer, "the recording wings are never hidden by a drawer")
            XCTAssertEqual(machine.send(.openHistory), .refused(.recording))
            XCTAssertEqual(machine.send(.openSettings(.general)), .refused(.recording))
            machine.send(.recordingChanged(false))
            XCTAssertEqual(machine.state, .closed, "a refused open is not replayed later")
        }
    }

    func testTheTeleprompterOutranksADrawer() {
        var machine = NotchSurfaceMachine()
        machine.send(.openHistory)
        machine.send(.teleprompterChanged(true))
        XCTAssertEqual(machine.state, .teleprompter)
        XCTAssertNil(machine.drawer)
        XCTAssertEqual(machine.send(.openSettings(.general)), .refused(.teleprompter))
    }

    func testNoDrawerOpensOverAModalSettingsWindow() {
        var machine = NotchSurfaceMachine()
        machine.send(.openSettings(.dictionary))
        machine.send(.modalChanged(true))
        XCTAssertNil(machine.drawer, "a sheet beginning closes the drawer that would cover it")
        XCTAssertEqual(machine.send(.openHistory), .refused(.modal))
        machine.send(.modalChanged(false))
        XCTAssertEqual(machine.send(.openHistory), .changed(from: .closed, to: .history(.collapsed)))
    }

    func testEveryReasonDismissesEveryOpenDrawer() {
        let opens: [NotchSurfaceEvent] = [.openHistory, .openSettings(.general), .openSettings(.history)]
        for open in opens {
            for reason in NotchDismissReason.allCases {
                var machine = NotchSurfaceMachine()
                machine.send(open)
                XCTAssertTrue(machine.canDismiss)
                XCTAssertEqual(machine.send(.dismiss(reason)).isChange, true, "\(open) \(reason)")
                XCTAssertEqual(machine.state, .closed)
            }
        }
    }

    // MARK: The model's receipts

    @MainActor
    func testTheModelLogsEveryDismissalWithItsReason() {
        var lines: [String] = []
        let model = NotchSurfaceModel()
        model.log = { lines.append($0) }
        model.send(.openHistory)
        model.send(.dismiss(.escape))
        XCTAssertEqual(lines, [
            "[VoiceBar] notch surface closed -> history(collapsed) (open history)",
            "[VoiceBar] notch surface history(collapsed) -> closed (dismiss escape)",
        ])
        XCTAssertEqual(model.journal.map(\.event), [.openHistory, .dismiss(.escape)])
    }

    // MARK: Exhaustive walk (the Swift side of formal/notch-surface)

    static let allEvents: [NotchSurfaceEvent] = {
        var events: [NotchSurfaceEvent] = [.openHistory]
        events += NotchHistoryDetent.allCases.map(NotchSurfaceEvent.setHistoryDetent)
        events += SettingsTab.allCases.map(NotchSurfaceEvent.openSettings)
        events += SettingsTab.allCases.map(NotchSurfaceEvent.selectSettingsTab)
        events += NotchDismissReason.allCases.map(NotchSurfaceEvent.dismiss)
        for flag in [true, false] {
            events += [.recordingChanged(flag), .teleprompterChanged(flag), .modalChanged(flag)]
        }
        return events
    }()

    func testEveryReachableStateKeepsTheInvariantsAndCanAlwaysBeDismissed() {
        var seen: Set<NotchSurfaceMachine> = [NotchSurfaceMachine()]
        var frontier = [NotchSurfaceMachine()]
        while let machine = frontier.popLast() {
            XCTAssertTrue(machine.wingsNeverHidden, "\(machine)")
            XCTAssertTrue(machine.noDrawerOverModal, "\(machine)")
            XCTAssertTrue(machine.noDrawerOverTeleprompter, "\(machine)")
            XCTAssertTrue(machine.dismissalReachable, "\(machine)")
            if machine.drawer != nil {
                var dismissed = machine
                dismissed.send(.dismiss(.outsideClick))
                XCTAssertNil(dismissed.drawer, "one dismiss closes it from \(machine)")
            }
            for event in Self.allEvents {
                var next = machine
                next.send(event)
                if seen.insert(next).inserted { frontier.append(next) }
            }
        }
        // Per remembered detent (2): with every activity flag clear, no drawer, History at that detent, or one of
        // the 5 Settings tabs; under each of the 7 other flag combinations, no drawer at all.
        XCTAssertEqual(seen.count, 2 * (1 + 1 + 5 + 7))

        // Refinement: projected onto the TLA+ variables (detent and tab abstracted), the Swift machine reaches
        // exactly the 10 distinct states TLC reports for formal/notch-surface Fixed.cfg.
        struct Projected: Hashable { let history, settings, recording, teleprompter, modal: Bool }
        let projected = Set(seen.map {
            Projected(history: $0.drawer?.isHistory == true, settings: $0.drawer?.isSettings == true,
                      recording: $0.isRecording, teleprompter: $0.isTeleprompterShown, modal: $0.isModal)
        })
        XCTAssertEqual(projected.count, 10)
        XCTAssertTrue(projected.allSatisfy { !($0.history && $0.settings) })
    }
}

private extension NotchSurfaceOutcome {
    var isChange: Bool {
        if case .changed = self { return true }
        return false
    }
}
