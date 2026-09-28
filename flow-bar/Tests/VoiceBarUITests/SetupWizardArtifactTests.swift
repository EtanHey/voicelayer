import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// F3: the wizard window content, offscreen (no key window, no events). Artifacts land in
/// docs.local/design/2026-09-28-f3-wizard/ in both appearances.
@MainActor
final class SetupWizardArtifactTests: XCTestCase {
    func testEveryStepFitsTheWizardWindow() {
        for step in SetupWizardStep.allCases {
            let host = NSHostingView(rootView: wizard(at: step))
            let fitting = host.fittingSize
            XCTAssertLessThanOrEqual(fitting.width, SetupWizardView.contentSize.width, "\(step)")
            XCTAssertLessThanOrEqual(fitting.height, SetupWizardView.contentSize.height, "\(step)")
        }
    }

    func testWritesEveryStepInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/design/2026-09-28-f3-wizard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var cases = SetupWizardStep.allCases.map { step in (step.rawValue, wizard(at: step)) }
        cases.append(("done-skipped", wizard(at: .done, skipping: [.permissions, .microphone])))
        cases.append(("permissions-missing", wizard(at: .permissions, permissions: SetupPermissionSnapshot(
            microphone: .notRequested, accessibilityGranted: false, inputMonitoringGranted: true,
            hotkeyListenerActive: false
        ))))
        cases.append(("f5Key-setup", wizard(at: .f5Key, f5Key: SetupF5KeyStatus(
            listenerActive: true, helperInstalled: false
        ))))
        cases.append(("f5Key-off-failed", wizard(
            at: .f5Key,
            f5Key: SetupF5KeyStatus(listenerActive: false, helperInstalled: false),
            relayRun: SetupRelayRun(action: .setUp, result: SettingsRelaySetupResult(
                outcome: .failed(reason: "installer exited 1: launchctl bootstrap failed"),
                finishedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        )))
        cases.append(("f5Key-ready", wizard(
            at: .f5Key,
            relayRun: SetupRelayRun(action: .reinstall, result: SettingsRelaySetupResult(
                outcome: .ready, finishedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ))
        )))
        cases.append(("microphone-none", wizard(at: .microphone, microphone: nil)))
        let heard = RecentTranscriptionEntry(
            text: "Testing the new microphone, one two three.", createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        cases.append(("tryIt-problems", wizard(
            at: .tryIt,
            permissions: SetupPermissionSnapshot(
                microphone: .granted, accessibilityGranted: false, inputMonitoringGranted: true,
                hotkeyListenerActive: false
            ),
            f5Key: SetupF5KeyStatus(listenerActive: false, helperInstalled: true)
        )))
        cases.append(("tryIt-listening", wizard(
            at: .tryIt, tryIt: SetupTryItObservation(entry: nil, insertion: .unverified, activity: .recording)
        )))
        cases.append(("tryIt-typed", wizard(
            at: .tryIt, tryIt: SetupTryItObservation(entry: heard, insertion: .pasted, activity: .idle)
        )))
        cases.append(("tryIt-not-typed", wizard(
            at: .tryIt, tryIt: SetupTryItObservation(entry: heard, insertion: .failed, activity: .idle)
        )))
        cases.append(("permissions-restart", wizard(at: .permissions, permissions: SetupPermissionSnapshot(
            microphone: .granted, accessibilityGranted: true, inputMonitoringGranted: true, hotkeyListenerActive: false
        ))))
        for (name, view) in cases {
            for (appearance, appearanceName) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try writePNG(view, appearance: NSAppearance(named: appearance),
                             to: directory.appendingPathComponent("wizard-\(name)-\(appearanceName).png"))
            }
        }
    }

    /// The two ways back in: "Run setup…" in the menu-bar popover and General › Setup › Run setup again.
    func testWritesTheEntryPointsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/design/2026-09-28-f3-wizard")
        let popover = MenuBarPopoverView(
            footer: .resolve(isConnected: true, mode: .idle, captureLive: true, errorMessage: nil,
                             remoteSTTConfigured: nil),
            hotkeyHint: "Hold F5 to dictate",
            defaultMicrophoneName: "Studio USB Mic",
            transcript: "A synthetic last transcript."
        ).background(Color(nsColor: .windowBackgroundColor))
        let settings = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [MicrophoneDevice(id: "built-in", name: "Studio USB Mic")] },
            selectedDeviceID: { "built-in" },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            initialTab: .general
        )
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try writePNG(popover, size: CGSize(width: 300, height: 300), appearance: NSAppearance(named: appearance),
                         to: directory.appendingPathComponent("entry-popover-\(name).png"))
            try writePNG(settings, size: CGSize(width: 720, height: 900), appearance: NSAppearance(named: appearance),
                         to: directory.appendingPathComponent("entry-settings-general-\(name).png"))
        }
    }

    private func wizard(
        at step: SetupWizardStep,
        skipping: [SetupWizardStep] = [],
        permissions: SetupPermissionSnapshot = .allGranted,
        f5Key: SetupF5KeyStatus = SetupF5KeyStatus(listenerActive: true, helperInstalled: true),
        relayRun: SetupRelayRun? = nil,
        microphone: String? = "Studio USB Mic",
        tryIt: SetupTryItObservation = .none
    ) -> some View {
        let suite = "SetupWizardArtifactTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var model = SetupWizardModel(step: skipping.first ?? step)
        while model.step != step {
            if skipping.contains(model.step) { model.skipStep() } else { model.continueToNextStep() }
        }
        let controller = SetupWizardController(
            store: SetupWizardCompletionStore(defaults: defaults), model: model, relayRun: relayRun
        )
        return SetupWizardView(
            controller: controller,
            dependencies: SetupWizardDependencies(
                permissionSnapshot: { permissions },
                f5KeyStatus: { f5Key },
                defaultMicrophoneName: { microphone },
                tryItObservation: { tryIt }
            ),
            initialTryItBaseline: .some(nil)
        )
        .frame(width: SetupWizardView.contentSize.width, height: SetupWizardView.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func writePNG(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        try writePNG(view, size: SetupWizardView.contentSize, appearance: appearance, to: url)
    }

    private func writePNG(_ view: some View, size: CGSize, appearance: NSAppearance?, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
    }
}
