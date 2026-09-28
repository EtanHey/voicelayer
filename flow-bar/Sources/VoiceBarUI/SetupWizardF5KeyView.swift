import SwiftUI

/// F3 step 2: is F5 listened for, and is the F5 key helper installed — with Settings' Set up / Reinstall.
struct SetupWizardF5KeyBody: View {
    let dependencies: SetupWizardDependencies
    /// The wizard controller's helper run: it outlives this view, which is rebuilt on every step change.
    let run: SetupRelayRun?
    let onRunHelper: (SettingsRelaySetupFeedback.Action) -> Void
    let onFix: (SetupWizardStep) -> Void
    @State private var status: SetupF5KeyStatus?

    var body: some View {
        let step = SetupF5KeyStep(status: status ?? dependencies.f5KeyStatus(), run: run)
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                row("F5 listener", status: step.listenerStatus, isReady: step.listenerProblem == nil) {
                    if let fixStep = step.listenerFixStep {
                        Button("Allow access…") { onFix(fixStep) }
                    }
                }
                Divider()
                row("F5 key helper", status: step.helperStatus, isReady: step.helperAction == .reinstall) {
                    Button(step.helperButtonTitle) { onRunHelper(step.helperAction) }
                        .disabled(!step.helperButtonEnabled)
                }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            if let problem = step.listenerProblem {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let line = step.resultLine {
                resultLabel(line)
            }
            Text("The helper lets F5 start dictation even if your Mac remaps the dictation key. "
                + VoiceBarHotkeyContract.remapPlainSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(VoiceBarHotkeyContract.remapExplanation)
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onChange(of: run) { _, _ in refresh() }
    }

    private func row(
        _ label: String,
        status: String,
        isReady: Bool,
        @ViewBuilder action: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(isReady ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(status).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            action()
        }
        .frame(minHeight: 40)
    }

    @ViewBuilder
    private func resultLabel(_ line: SetupF5KeyResultLine) -> some View {
        switch line.tone {
        case .running:
            Label {
                Text(line.text).foregroundStyle(.secondary)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.callout)
        case .success, .failure:
            let succeeded = line.tone == .success
            Label {
                Text(line.text)
                    .foregroundStyle(succeeded ? Color.primary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(succeeded ? Color.green : Color.red)
            }
            .font(.callout)
        }
    }

    private func refresh() {
        status = dependencies.f5KeyStatus()
    }
}
