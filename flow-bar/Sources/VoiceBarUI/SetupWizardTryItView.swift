import SwiftUI

/// F3 step 4: dictate once in any app and see what VoiceBar heard in the wizard's own field.
struct SetupWizardTryItBody: View {
    let dependencies: SetupWizardDependencies
    let onFix: (SetupWizardStep) -> Void
    /// The last dictation when the step opened; a different one is this step's dictation.
    @State private var baseline: RecentTranscriptionEntry??
    @State private var observation: SetupTryItObservation?

    init(
        dependencies: SetupWizardDependencies,
        baseline: RecentTranscriptionEntry?? = nil,
        onFix: @escaping (SetupWizardStep) -> Void
    ) {
        self.dependencies = dependencies
        self.onFix = onFix
        _baseline = State(initialValue: baseline)
    }

    var body: some View {
        let current = observation ?? dependencies.tryItObservation()
        let step = SetupTryItStep(
            baseline: baseline ?? current.entry,
            observation: current,
            readiness: SetupReadiness(
                permissions: dependencies.permissionSnapshot(),
                f5Key: dependencies.f5KeyStatus(),
                microphoneName: dependencies.defaultMicrophoneName()
            )
        )
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Click into Notes, TextEdit, or any text box.")
                Text("2. Hold F5 and say a sentence.")
                Text("3. Let go. What VoiceBar heard shows up below.")
            }
            .fixedSize(horizontal: false, vertical: true)

            heardField(step)

            if let line = step.phaseLine {
                Label {
                    Text(line).foregroundStyle(.secondary)
                } icon: {
                    ProgressView().controlSize(.small)
                }
            }
            if let line = step.insertionLine {
                Label {
                    Text(line).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: step.insertionTone == .success ? "checkmark.circle.fill"
                        : "info.circle.fill")
                        .foregroundStyle(step.insertionTone == .success ? Color.green : Color.orange)
                }
            }
            ForEach(Array(step.problems.enumerated()), id: \.offset) { _, problem in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(problem.text)
                    Spacer(minLength: 8)
                    Button(problem.fixTitle) { onFix(problem.step) }
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            let now = dependencies.tryItObservation()
            if baseline == nil { baseline = .some(now.entry) }
            observation = now
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            observation = dependencies.tryItObservation()
        }
    }

    private func heardField(_ step: SetupTryItStep) -> some View {
        Group {
            if let text = step.heardText {
                Text(text)
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
            } else {
                Text("What VoiceBar hears shows up here.")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
        .overlay(alignment: .topTrailing) {
            if step.succeeded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding(8)
                    .accessibilityLabel("Heard")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.heardText.map { "Heard: \($0)" } ?? "Nothing heard yet")
    }
}
