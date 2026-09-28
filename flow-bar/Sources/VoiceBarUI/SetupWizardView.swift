import AppKit
import SwiftUI

/// What the wizard reads and does through the app. VoiceBarUI stays presentation-only: every check and action here
/// is the app's existing one, passed in.
public struct SetupWizardDependencies {
    /// Read about once a second while the Permissions step shows.
    public var permissionSnapshot: () -> SetupPermissionSnapshot
    /// Shows the macOS microphone prompt, then calls back so the step re-reads the snapshot.
    public var onRequestMicrophone: (@escaping () -> Void) -> Void
    public var openURL: (URL) -> Void
    /// The F5 listener and helper, read about once a second while the F5 key step shows.
    public var f5KeyStatus: () -> SetupF5KeyStatus
    /// Settings' Set up / Reinstall of the F5 key helper, with its #193 result.
    public var onRunRelaySetup: (@escaping (SettingsRelaySetupResult) -> Void) -> Void
    /// The microphone-priority default every read-only row shows (the app's `defaultMicrophoneName()`).
    public var defaultMicrophoneName: () -> String?
    /// Settings › General scrolled to Microphone priority, as "Change…" does from the menu and popover.
    public var onChangeMicrophone: () -> Void

    public init(
        permissionSnapshot: @escaping () -> SetupPermissionSnapshot = { .unknown },
        onRequestMicrophone: @escaping (@escaping () -> Void) -> Void = { $0() },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        f5KeyStatus: @escaping () -> SetupF5KeyStatus = { .unknown },
        onRunRelaySetup: @escaping (@escaping (SettingsRelaySetupResult) -> Void) -> Void = { completion in
            completion(SettingsRelaySetupResult(outcome: .failed(reason: "not available here"), finishedAt: Date()))
        },
        defaultMicrophoneName: @escaping () -> String? = { nil },
        onChangeMicrophone: @escaping () -> Void = {}
    ) {
        self.permissionSnapshot = permissionSnapshot
        self.onRequestMicrophone = onRequestMicrophone
        self.openURL = openURL
        self.f5KeyStatus = f5KeyStatus
        self.onRunRelaySetup = onRunRelaySetup
        self.defaultMicrophoneName = defaultMicrophoneName
        self.onChangeMicrophone = onChangeMicrophone
    }
}

/// F3: the setup wizard window's content. The frame (progress, heading, footer) is shared; each step's body
/// reuses the matching Settings control. The window itself is the app's.
public struct SetupWizardView: View {
    public static let contentSize = CGSize(width: 560, height: 460)

    private let controller: SetupWizardController
    private let dependencies: SetupWizardDependencies

    public init(controller: SetupWizardController, dependencies: SetupWizardDependencies = SetupWizardDependencies()) {
        self.controller = controller
        self.dependencies = dependencies
    }

    public var body: some View {
        let model = controller.model
        let footer = SetupWizardFooter(model: model)
        VStack(spacing: 0) {
            SetupWizardProgressBar(step: model.step, completedSegments: footer.completedSegments)
                .padding(.horizontal, 28)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                SetupWizardHeading(step: model.step)
                stepBody(model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Divider()
            SetupWizardFooterBar(
                footer: footer,
                onSkipSetup: controller.skipSetup,
                onBack: controller.goBack,
                onSkipStep: controller.skipStep,
                onPrimary: controller.continueToNextStep
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: Self.contentSize.width, minHeight: Self.contentSize.height)
    }

    @ViewBuilder
    private func stepBody(_ model: SetupWizardModel) -> some View {
        switch model.step {
        case .welcome:
            SetupWizardWelcomeBody()
        case .done:
            SetupWizardDoneBody(summary: SetupWizardDoneSummary(skippedSteps: model.skippedSteps))
        case .permissions:
            SetupWizardPermissionsBody(dependencies: dependencies)
        case .f5Key:
            SetupWizardF5KeyBody(
                dependencies: dependencies,
                run: controller.relayRun,
                onRunHelper: { controller.startRelaySetup($0, using: dependencies.onRunRelaySetup) },
                onFix: { controller.goBack(to: $0) }
            )
        case .microphone:
            SetupWizardMicrophoneBody(dependencies: dependencies)
        case .tryIt:
            EmptyView()
        }
    }
}

extension SetupWizardStep {
    var symbolName: String {
        switch self {
        case .welcome: "waveform"
        case .permissions: "lock.shield"
        case .f5Key: "keyboard"
        case .microphone: "mic"
        case .tryIt: "text.bubble"
        case .done: "checkmark.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            "Speak, and VoiceBar types what you said wherever your cursor is."
        case .permissions:
            "VoiceBar needs three permissions to hear you and type for you."
        case .f5Key:
            "F5 starts dictation from any app."
        case .microphone:
            "VoiceBar records from the first connected microphone in your list."
        case .tryIt:
            "Hold F5, say a sentence, and let go."
        case .done:
            "Hold F5 in any app to dictate."
        }
    }
}

private struct SetupWizardProgressBar: View {
    let step: SetupWizardStep
    let completedSegments: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0 ..< SetupWizardStep.setupSteps.count, id: \.self) { index in
                    Capsule()
                        .fill(index < completedSegments ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 4)
                }
            }
            Text(step.progressLabel ?? " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        // Welcome and Done keep the row's height so the heading never jumps between steps.
        .opacity(step.isSetupStep ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.progressLabel ?? "")
        .accessibilityHidden(!step.isSetupStep)
    }
}

private struct SetupWizardHeading: View {
    let step: SetupWizardStep

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: step.symbolName)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(step.subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SetupWizardFooterBar: View {
    let footer: SetupWizardFooter
    let onSkipSetup: () -> Void
    let onBack: () -> Void
    let onSkipStep: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if footer.showsSkipSetup {
                Button("Skip setup", action: onSkipSetup)
                    .buttonStyle(.link)
                    .help("Close setup. You can run it again from Settings or the menu.")
            }
            Spacer(minLength: 12)
            if footer.showsBack {
                Button("Back", action: onBack)
            }
            if footer.showsSkipStep {
                Button("Skip this step", action: onSkipStep)
            }
            Button(footer.primaryTitle, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }
}

private struct SetupWizardWelcomeBody: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup takes about two minutes:")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SetupWizardStep.setupSteps, id: \.self) { step in
                    Label(step.title, systemImage: step.symbolName)
                }
            }
            .padding(.leading, 4)
            Text("You can skip any step, and run setup again later from Settings or the menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupWizardDoneBody: View {
    let summary: SetupWizardDoneSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let unfinished = summary.unfinishedLine {
                Label {
                    Text(unfinished).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                gestureRow("Hold F5", VoiceBarHotkeyContract.holdDescription)
                gestureRow("Double-tap F5", VoiceBarHotkeyContract.doubleTapDescription)
                gestureRow("Tap F5", VoiceBarHotkeyContract.singleTapDescription)
                gestureRow(VoiceBarHotkeyContract.repasteShortcutLabel, VoiceBarHotkeyContract.repasteDescription)
            }
        }
    }

    private func gestureRow(_ key: String, _ description: String) -> some View {
        GridRow {
            Text(key).font(.body.weight(.medium))
            Text(description).foregroundStyle(.secondary)
        }
    }
}
