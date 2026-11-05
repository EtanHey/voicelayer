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

    func testEverythingWorkingIsOneQuietReadyRow() {
        let ready = setup()
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.header, "Setup")
        XCTAssertEqual(SettingsGeneralSetup.readyTitle, "VoiceBar is ready")
        XCTAssertEqual(ready.readyDescription, "Permissions are on, F5 works and your voice is set up.")
        XCTAssertNil(ready.firstBroken)
    }

    func testWithoutAVoiceReadingTheReadyLineClaimsOnlyWhatItKnows() {
        let ready = setup(voice: nil)
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(ready.readyDescription, "Permissions are on and F5 works.")
        XCTAssertFalse(ready.steps.contains { $0.id == .speakingVoice })
    }

    func testAMissingPermissionListsBrokenStepsFirstWithTheirFix() {
        let broken = setup(accessibility: false)
        XCTAssertFalse(broken.isReady)
        XCTAssertEqual(broken.header, "Finish setup")
        XCTAssertEqual(broken.steps.map(\.id), [.accessibility, .microphone, .inputMonitoring, .f5Key, .speakingVoice])
        let accessibility = broken.steps[0]
        XCTAssertEqual(accessibility.description, "Off. VoiceBar needs this to paste what you say into other apps.")
        XCTAssertEqual(accessibility.fix?.title, "Open System Settings")
        XCTAssertEqual(broken.firstBroken, .accessibility)
    }

    func testBrokenStepsKeepSpecOrderAmongThemselves() {
        let broken = setup(accessibility: false, inputMonitoring: false, listener: false, voice: .engineDown)
        XCTAssertEqual(broken.steps.map(\.id), [.accessibility, .inputMonitoring, .f5Key, .speakingVoice, .microphone])
    }

    func testANeverAskedMicrophoneOffersThePrompt() {
        let step = setup(microphone: .notRequested).steps[0]
        XCTAssertEqual(step.id, .microphone)
        XCTAssertEqual(step.fix, .permission(.requestMicrophone))
        XCTAssertEqual(step.fix?.title, "Allow…")
    }

    func testF5OffAfterPermissionsChangedOffersTheListenerRestart() {
        let f5 = setup(listener: false).steps[0]
        XCTAssertEqual(f5.id, .f5Key)
        XCTAssertEqual(f5.fix, .restartF5Listener)
        XCTAssertEqual(f5.fix?.title, "Restart F5 listener")
    }

    func testF5OffWithAPermissionMissingPointsAtThePermissionInstead() {
        let f5 = setup(inputMonitoring: false, listener: false).steps.first { $0.id == .f5Key }
        XCTAssertNil(f5?.fix)
        XCTAssertEqual(f5?.description, "Off. Turn on the permissions above first.")
    }

    func testAWorkingF5OffersCheckAndSaysWhenItWasLastChecked() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T14:30:00Z"))
        let checked = now.addingTimeInterval(-3600 * 5 - 18 * 60)
        let f5 = try XCTUnwrap(setup(checkedAt: checked, now: now).steps.first { $0.id == .f5Key })
        XCTAssertEqual(f5.fix, .checkF5)
        XCTAssertEqual(f5.description, "Works. Last checked today at 09:12.")
        XCTAssertEqual(setup().steps.first { $0.id == .f5Key }?.description, "Works.")
    }

    func testSpeakingVoiceSendsToSpeechInBothStates() {
        let down = setup(voice: .engineDown).steps[0]
        XCTAssertEqual(down.id, .speakingVoice)
        XCTAssertEqual(down.fix?.title, "Start engine")
        XCTAssertEqual(setup().steps.first { $0.id == .speakingVoice }?.fix?.title, "Manage")
    }

    func testOnlyAStoppedOrFailedCloneEngineCountsAsDown() {
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .stopped), .engineDown)
        XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: .failed), .engineDown)
        for state in [CloneEngineSnapshot.State.running, .starting, .restarting] {
            XCTAssertEqual(SettingsSetupVoiceStatus(cloneEngine: state), .ready, "\(state)")
        }
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
