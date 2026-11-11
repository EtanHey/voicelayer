import SwiftUI

/// Settings › Speech: the cloned voice engine row (V10) and "Start with VoiceBar".
///
/// Buttons only issue intents through `CloneEngineControlViewModel`; the pill and description always come from the
/// latest lifecycle snapshot. With no view model or no snapshot the row says the status is unavailable and offers
/// nothing, rather than guessing.
struct CloneEngineSection: View {
    let viewModel: CloneEngineControlViewModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let startWithVoiceBarDescription = "Starts with VoiceBar and restarts if it stops. Applies the next time VoiceBar opens."

    private var presentation: CloneEnginePresentation {
        viewModel?.presentation() ?? CloneEngineControlModel().presentation(now: Date())
    }

    var body: some View {
        let shown = self.presentation
        Section {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRowLayout {
                    SettingsRowLabel(title: "Cloned voice engine", description: shown.description)
                    CloneEnginePill(presentation: shown, pulses: shown.pulses && !reduceMotion)
                }
                if shown.showsProgress {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(shown.pill)
                }
                if let note = shown.note {
                    Label {
                        Text(note).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: shown.noteIsProblem ? "exclamationmark.triangle.fill" : "info.circle")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(shown.noteIsProblem ? SettingsPanePalette.warning : SettingsPanePalette.helper)
                    .accessibilityIdentifier("speech-clone-engine-note")
                }
                if !shown.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(shown.actions, id: \.button) { action in
                            Button(action.button.title) { viewModel?.press(action.button) }
                                .disabled(!action.isEnabled || viewModel == nil)
                                .fixedSize()
                                .accessibilityIdentifier("speech-clone-engine-\(action.button.title)")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("speech-clone-engine")

            if shown.startWithVoiceBar != nil { startWithVoiceBarRow(shown) }
        } header: {
            Text("Voice engine")
        }
        // A missing acknowledgement, or an accepted retry that changed nothing, ends instead of waiting forever.
        .task(id: viewModel?.nextDeadline) {
            guard let deadline = viewModel?.nextDeadline else { return }
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            viewModel?.expire()
        }
    }

    @ViewBuilder
    private func startWithVoiceBarRow(_ presentation: CloneEnginePresentation) -> some View {
        let label = SettingsRowLabel(title: "Start with VoiceBar", description: Self.startWithVoiceBarDescription)
        if let isOn = presentation.startWithVoiceBar {
            SettingsRowLayout {
                label
                Toggle("Start with VoiceBar", isOn: Binding(
                    get: { isOn },
                    set: { viewModel?.setStartWithVoiceBar($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!presentation.startWithVoiceBarEnabled || viewModel == nil)
                .accessibilityLabel("Start with VoiceBar")
            }
            .accessibilityIdentifier("speech-clone-engine-autostart")
        } else {
            SettingsRowLayout {
                label
                Text("Unavailable")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsPanePalette.helper)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("speech-clone-engine-autostart")
        }
    }
}

/// The status pill: a colored dot and the state in label color on a light tint, so the word, not the hue, carries
/// the meaning (and stays readable in light and dark).
struct CloneEnginePill: View {
    let presentation: CloneEnginePresentation
    let pulses: Bool

    static func color(_ tone: CloneEnginePillTone) -> Color {
        switch tone {
        case .green: .green
        case .blue: .blue
        case .grey: .gray
        case .red: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(Self.color(presentation.tone))
                .symbolEffect(.pulse, options: .repeating, isActive: pulses)
            Text(presentation.pill)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Self.color(presentation.tone).opacity(0.14)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityStatus)
        .accessibilityIdentifier("speech-clone-engine-status")
    }
}
