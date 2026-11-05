import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// U3a: the V12 row-clipping guard for General at 720 and 390 pt, and light + dark frames.
/// Synthetic native rendering only; no resident app, sockets or audio.
@MainActor
final class SettingsGeneralPaneShotsTests: XCTestCase {
    private var rowCases: [SettingsRowCase] {
        let broken = SettingsGeneralSetup(
            permissions: SetupPermissionsStep(snapshot: .unknown).rows, hotkeyListenerActive: false,
            f5CheckedAt: nil, voice: .engineDown)
        let working = SettingsGeneralSetup(
            permissions: SetupPermissionsStep(snapshot: .allGranted).rows, hotkeyListenerActive: true,
            f5CheckedAt: Date(), voice: .ready)
        let steps = (broken.steps + working.steps).map {
            SettingsRowCase(title: $0.title, description: $0.description, hasLead: true,
                            controls: $0.fix.map { SettingsRowCase.button($0.title) } ?? AnyView(EmptyView()))
        }
        return steps + [
            SettingsRowCase(title: SettingsGeneralSetup.readyTitle, description: working.readyDescription, hasLead: true,
                            controls: SettingsRowCase.button("Show steps")),
            SettingsRowCase(title: "Studio Display Microphone (USB-C hub)", description: "Not connected", hasLead: true,
                            controls: AnyView(Button("Make default") {}.controlSize(.small))),
            SettingsRowCase(title: "DJI Mic 2", description: "Connected", hasLead: true,
                            controls: AnyView(SettingsPill(text: "Used for dictation"))),
            SettingsRowCase(title: SettingsGeneralCopy.dictationKeyTitle,
                            description: SettingsGeneralCopy.dictationKeyDescription,
                            controls: AnyView(Text("F5").padding(.horizontal, 7))),
            SettingsRowCase(title: SettingsGeneralCopy.mouseTitle, description: SettingsGeneralCopy.mouseDescription,
                            controls: SettingsRowCase.toggle),
            SettingsRowCase(title: SettingsGeneralCopy.openAtLoginTitle, description: nil,
                            controls: SettingsRowCase.toggle),
            SettingsRowCase(title: SettingsGeneralCopy.hideTitle, description: SettingsGeneralCopy.hideDescription,
                            controls: SettingsRowCase.button("Hide for 1 hour")),
            SettingsRowCase(title: SettingsGeneralCopy.relayTitle,
                            description: SettingsGeneralCopy.relayDescription(installed: true, listenerActive: true),
                            controls: SettingsRowCase.button("Reinstall")),
            SettingsRowCase(title: SettingsGeneralCopy.setupAssistantTitle,
                            description: SettingsGeneralCopy.setupAssistantDescription,
                            controls: SettingsRowCase.button("Run setup again")),
        ]
    }

    /// Review R1 #736: disconnected AirPods first, the connected built-in mic second and in use. The built-in carries
    /// the pill AND can still be made default, so it stays first when the AirPods reconnect.
    func testTheMicInUseCanStillBeMadeDefaultBelowADisconnectedOne() {
        let airpods = MicrophonePriorityRow(uid: "air", deviceID: nil, label: "AirPods Pro", isConnected: false)
        let builtIn = MicrophonePriorityRow(uid: "mbp", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true)
        let snapshot = MicrophonePrioritySnapshot(rows: [airpods, builtIn], nextDeviceName: builtIn.label,
                                                  nextDeviceUID: "mbp")
        XCTAssertTrue(SettingsMicrophoneRowPresentation.isUsedForDictation(builtIn, snapshot: snapshot))
        XCTAssertTrue(SettingsMicrophoneRowPresentation.offersMakeDefault(builtIn, at: 1))
        XCTAssertEqual(snapshot.makingDefaultUIDs(at: 1), ["mbp", "air"], "the write still goes through the reorder")
        XCTAssertFalse(SettingsMicrophoneRowPresentation.offersMakeDefault(airpods, at: 0))
        XCTAssertFalse(SettingsMicrophoneRowPresentation.offersMakeDefault(builtIn, at: 0), "already first")
    }

    /// U1 (#727) gives the installed app a Dock icon whose click brings a hidden notch back.
    func testHideTheNotchSaysHowToBringItBack() {
        XCTAssertEqual(SettingsGeneralCopy.hideDescription,
                       "VoiceBar keeps working. Click its Dock icon to bring the notch back.")
    }

    func testGeneralRowsNeverClipBeforeTheSecondLine() {
        SettingsRowClippingGuard.check(rowCases)
    }

    /// Light + dark frames of the General pane at 720 and 390 pt, ready and with setup broken.
    func testWriteGeneralFramesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICEBAR_U3A_SHOTS"] else {
            throw XCTSkip("Set VOICEBAR_U3A_SHOTS to write the General frames")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        for state in ["ready", "broken"] {
            try SettingsRowClippingGuard.writeFrames({ Self.settings(broken: state == "broken").generalPaneForSnapshots },
                                                     prefix: "general-\(state)", height: 1100, to: directory)
        }
    }

    static func settings(broken: Bool) -> SettingsView {
        let mics = MicrophonePrioritySnapshot(rows: [
            MicrophonePriorityRow(uid: "dji", deviceID: "1", label: "DJI Mic 2", isConnected: true),
            MicrophonePriorityRow(uid: "mbp", deviceID: "2", label: "MacBook Pro Microphone", isConnected: true),
            MicrophonePriorityRow(uid: "air", deviceID: nil, label: "AirPods Pro", isConnected: false),
        ], nextDeviceName: "DJI Mic 2", nextDeviceUID: "dji")
        return SettingsView(
            hotkeyEnabled: true, missingPermissions: broken ? [.accessibility] : [],
            availableDevices: { [] }, selectedDeviceID: { nil }, prioritySnapshot: { mics },
            modelsStatus: { .disconnected }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 },
            isHotkeyRemapActive: { true },
            speakingVoiceStatus: { broken ? .engineDown : .ready },
            openAtLogin: SettingsToggleInput(isOn: { true }, set: { _ in }),
            mouseSideButtons: SettingsToggleInput(isOn: { true }, set: { _ in }),
            initialTab: .general
        )
    }
}
