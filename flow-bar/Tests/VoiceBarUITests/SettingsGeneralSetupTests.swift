import XCTest
@testable import VoiceBarUI

/// U3a: General › Setup (R2), the arrival highlight and the microphone pill, one guard per behaviour.
final class SettingsGeneralSetupTests: XCTestCase {
    private func permissions(microphone: SetupMicrophoneAuthorization = .granted, accessibility: Bool = true,
                             inputMonitoring: Bool = true, listener: Bool = true) -> [SetupPermissionRow] {
        SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
            microphone: microphone, accessibilityGranted: accessibility,
            inputMonitoringGranted: inputMonitoring, hotkeyListenerActive: listener
        )).rows
    }

    private func setup(microphone: SetupMicrophoneAuthorization = .granted, accessibility: Bool = true,
                       inputMonitoring: Bool = true, listener: Bool = true, checkedAt: Date? = nil,
                       voice: SettingsSetupVoiceStatus? = .ready, now: Date = Date()) -> SettingsGeneralSetup {
        SettingsGeneralSetup(
            permissions: permissions(microphone: microphone, accessibility: accessibility,
                                     inputMonitoring: inputMonitoring, listener: listener),
            hotkeyListenerActive: listener, f5CheckedAt: checkedAt, voice: voice, now: now, calendar: calendar)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    /// Etan, 2026-11-07: "Why the fuck not just detect what needs to be re set????" Healthy shows nothing.
    func testEverythingWorkingShowsNothing() {
        for voice in [SettingsSetupVoiceStatus.ready, nil] {
            let healthy = setup(voice: voice)
            XCTAssertTrue(healthy.isHealthy)
            XCTAssertEqual(healthy.steps, [], "no ready row, no healthy steps")
            XCTAssertNil(healthy.header, "no Setup header")
            XCTAssertNil(healthy.firstBroken)
        }
    }

    func testRevokedAccessibilityIsExactlyOneRowWithItsPane() throws {
        let broken = setup(accessibility: false)
        XCTAssertFalse(broken.isHealthy)
        XCTAssertEqual(broken.header, "Finish setup")
        XCTAssertEqual(broken.steps.map(\.id), [.accessibility])
        let accessibility = try XCTUnwrap(broken.steps.first)
        XCTAssertEqual(accessibility.description, "Off. VoiceBar needs this to paste what you say into other apps.")
        XCTAssertEqual(accessibility.fix, .permission(.openSettings(
            url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")))
        XCTAssertEqual(accessibility.fix?.title, "Open System Settings")
        XCTAssertEqual(broken.firstBroken, .accessibility)
    }

    func testEachPermissionDeepLinksToItsOwnPrivacyPane() {
        let panes: [(SettingsGeneralSetup, SettingsSetupStepID, String)] = [
            (setup(microphone: .denied), .microphone, "Privacy_Microphone"),
            (setup(accessibility: false), .accessibility, "Privacy_Accessibility"),
            (setup(inputMonitoring: false), .inputMonitoring, "Privacy_ListenEvent"),
        ]
        for (setup, id, anchor) in panes {
            XCTAssertEqual(setup.steps.map(\.id), [id])
            XCTAssertEqual(setup.steps.first?.fix, .permission(.openSettings(
                url: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")), "\(id)")
        }
    }

    func testBrokenStepsKeepSpecOrderAndF5WaitsForItsPermissions() {
        let broken = setup(accessibility: false, inputMonitoring: false, listener: false, voice: .engineDown)
        XCTAssertEqual(broken.steps.map(\.id), [.accessibility, .inputMonitoring, .speakingVoice],
                       "F5 has no fix of its own while a permission it needs is off")
        XCTAssertEqual(broken.allSteps.map(\.id),
                       [.microphone, .accessibility, .inputMonitoring, .f5Key, .speakingVoice])
        XCTAssertEqual(broken.firstBroken, .accessibility)
    }

    func testANeverAskedMicrophoneOffersThePrompt() {
        let step = setup(microphone: .notRequested).steps[0]
        XCTAssertEqual(step.id, .microphone)
        XCTAssertEqual(step.fix, .permission(.requestMicrophone))
        XCTAssertEqual(step.fix?.title, "Allow…")
    }

    func testF5OffAfterPermissionsChangedOffersTheListenerRestart() {
        let broken = setup(listener: false)
        XCTAssertEqual(broken.steps.map(\.id), [.f5Key])
        XCTAssertEqual(broken.steps[0].fix, .restartF5Listener)
        XCTAssertEqual(broken.steps[0].fix?.title, "Restart F5 listener")
    }

    func testF5OffWithAPermissionMissingPointsAtThePermissionInstead() {
        let setup = setup(inputMonitoring: false, listener: false)
        XCTAssertEqual(setup.steps.map(\.id), [.inputMonitoring])
        let f5 = setup.allSteps.first { $0.id == .f5Key }
        XCTAssertNil(f5?.fix)
        XCTAssertEqual(f5?.description, "Off. Turn on the permissions above first.")
    }

    func testAWorkingF5StillSaysWhenItWasLastChecked() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T14:30:00Z"))
        let checked = now.addingTimeInterval(-3600 * 5 - 18 * 60)
        let f5 = try XCTUnwrap(setup(checkedAt: checked, now: now).allSteps.first { $0.id == .f5Key })
        XCTAssertEqual(f5.fix, .checkF5)
        XCTAssertEqual(f5.description, "Works. Last checked today at 09:12.")
    }

    func testSpeakingVoiceShowsOnlyWhenBroken() {
        let down = setup(voice: .engineDown)
        XCTAssertEqual(down.steps.map(\.id), [.speakingVoice])
        XCTAssertEqual(down.steps[0].fix?.title, "Start engine")
        XCTAssertEqual(setup().allSteps.first { $0.id == .speakingVoice }?.fix?.title, "Manage")
    }

    /// Review R1 #735: only a running engine is ready; starting and restarting are neither ready nor broken.
    func testEachCloneEngineStateMapsTruthfully() {
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .running), .ready)
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .starting), .starting)
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .restarting), .restarting)
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .stopped), .engineDown)
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .failed), .engineDown)
    }

    /// A loading or recovering voice fixes itself: nothing to show, and never the orange dot's target.
    func testALoadingOrRecoveringVoiceShowsNothing() throws {
        for voice in [SettingsSetupVoiceStatus.starting, .restarting] {
            let setup = setup(voice: voice)
            XCTAssertTrue(setup.isHealthy, "\(voice)")
            XCTAssertNil(setup.header, "\(voice): nothing for you to finish")
            XCTAssertNil(setup.firstBroken, "\(voice): the orange dot never points at a step that fixes itself")
            let step = try XCTUnwrap(setup.allSteps.first { $0.id == .speakingVoice })
            XCTAssertTrue(step.isPending)
            XCTAssertFalse(step.isBroken)
            XCTAssertFalse(step.description.contains("is ready"), step.description)
        }
    }

    func testAPendingVoiceNeverJoinsABrokenList() {
        let setup = setup(accessibility: false, voice: .starting)
        XCTAssertEqual(setup.steps.map(\.id), [.accessibility])
        XCTAssertEqual(setup.firstBroken, .accessibility)
        XCTAssertEqual(setup.header, "Finish setup")
    }

    func testArrivalHighlightsTheBrokenRowUnlessReduceMotion() {
        var highlight = SettingsArrivalHighlight()
        highlight.arrive(at: .accessibility, reduceMotion: false)
        XCTAssertEqual(highlight.step, .accessibility)
        XCTAssertEqual(SettingsArrivalHighlight.duration, 1.6)
        highlight.arrive(at: .accessibility, reduceMotion: true)
        XCTAssertNil(highlight.step)
    }

    func testAnOlderExpiryNeverEndsANewerHighlight() {
        var highlight = SettingsArrivalHighlight()
        highlight.arrive(at: .accessibility, reduceMotion: false)
        highlight.arrive(at: .f5Key, reduceMotion: false)
        highlight.expire(.accessibility)
        XCTAssertEqual(highlight.step, .f5Key)
        highlight.expire(.f5Key)
        XCTAssertNil(highlight.step)
    }

    func testUsedForDictationFollowsTheNextDeviceByIdentity() {
        let dji = MicrophonePriorityRow(uid: "dji", deviceID: "1", label: "DJI Mic 2", isConnected: true)
        let built = MicrophonePriorityRow(uid: "mbp", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true)
        let snapshot = MicrophonePrioritySnapshot(rows: [dji, built], nextDeviceName: "MacBook Pro Microphone",
                                                  nextDeviceUID: "mbp")
        XCTAssertFalse(SettingsMicrophoneRowPresentation.isUsedForDictation(dji, snapshot: snapshot))
        XCTAssertTrue(SettingsMicrophoneRowPresentation.isUsedForDictation(built, snapshot: snapshot))
        let byName = MicrophonePrioritySnapshot(rows: [dji], nextDeviceName: "DJI Mic 2")
        XCTAssertTrue(SettingsMicrophoneRowPresentation.isUsedForDictation(dji, snapshot: byName))
    }

    func testADisconnectedMicrophoneIsNeverMarkedUsed() {
        let airpods = MicrophonePriorityRow(uid: "air", deviceID: nil, label: "AirPods Pro", isConnected: false)
        let snapshot = MicrophonePrioritySnapshot(rows: [airpods], nextDeviceName: "AirPods Pro", nextDeviceUID: "air")
        XCTAssertFalse(SettingsMicrophoneRowPresentation.isUsedForDictation(airpods, snapshot: snapshot))
        XCTAssertEqual(SettingsMicrophoneRowPresentation.status(airpods), "Not connected")
    }
}
