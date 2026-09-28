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

    private func wizard(
        at step: SetupWizardStep,
        skipping: [SetupWizardStep] = [],
        permissions: SetupPermissionSnapshot = .allGranted
    ) -> some View {
        let suite = "SetupWizardArtifactTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var model = SetupWizardModel(step: skipping.first ?? step)
        while model.step != step {
            if skipping.contains(model.step) { model.skipStep() } else { model.continueToNextStep() }
        }
        let controller = SetupWizardController(store: SetupWizardCompletionStore(defaults: defaults), model: model)
        return SetupWizardView(
            controller: controller,
            dependencies: SetupWizardDependencies(permissionSnapshot: { permissions })
        )
        .frame(width: SetupWizardView.contentSize.width, height: SetupWizardView.contentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func writePNG(_ view: some View, appearance: NSAppearance?, to url: URL) throws {
        let size = SetupWizardView.contentSize
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
