import SwiftUI

/// F3 step 3: "Default: <mic>" and Change…, re-read every two seconds so plugging a mic in shows up here.
struct SetupWizardMicrophoneBody: View {
    let dependencies: SetupWizardDependencies
    @State private var name: String??

    var body: some View {
        let step = SetupMicrophoneStep(defaultName: name ?? dependencies.defaultMicrophoneName())
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(step.defaultTitle)
                    .lineLimit(1)
                    .accessibilityLabel(step.accessibilityLabel)
                Spacer(minLength: 12)
                Button(step.changeTitle, action: dependencies.onChangeMicrophone)
                    .accessibilityLabel(step.changeAccessibilityLabel)
            }
            .frame(minHeight: 40)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            if let problem = step.problem {
                Label {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Text("Change… opens Settings › Microphone priority. Put your usual microphone first; if it's "
                + "disconnected, VoiceBar uses the next one in the list.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func refresh() {
        name = .some(dependencies.defaultMicrophoneName())
    }
}
