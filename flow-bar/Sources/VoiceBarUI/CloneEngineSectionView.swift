import SwiftUI

/// Settings › Speech: the cloned voice engine row (V10) and "Start with VoiceBar".
///
/// Buttons only issue intents through `CloneEngineControlViewModel`; the pill and description always come from the
/// latest lifecycle snapshot. With no view model or no snapshot the row says the status is unavailable and offers
/// nothing, rather than guessing.
struct CloneEngineSection: View {
    let viewModel: CloneEngineControlViewModel?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchPaneInk) private var notchInk

    /// The full fact, on hover and for VoiceOver; the row itself shows `startWithVoiceBarNote` (2.4.6 track S: one
    /// short line per row).
    static let startWithVoiceBarDescription = "Starts when VoiceBar opens and restarts by itself if it stops. A change here applies the next time VoiceBar opens."
    static let startWithVoiceBarNote = "Restarts if it stops. Takes effect next launch."

    private var presentation: CloneEnginePresentation {
        viewModel?.presentation() ?? CloneEngineControlModel().presentation(now: Date())
    }

    var body: some View {
        let shown = self.presentation
        Section {
            VStack(alignment: .leading, spacing: 8) {
                // Status, pill and actions share one row (2.4.6 track S: the status card was three rows tall).
                SettingsRowLayout {
                    SettingsRowLabel(title: "Cloned voice engine", description: shown.description)
                    HStack(spacing: 6) {
                        CloneEnginePill(presentation: shown, pulses: shown.pulses && !reduceMotion)
                        ForEach(shown.actions, id: \.button) { action in
                            SettingsPaneButton(title: action.button.title,
                                               isEnabled: action.isEnabled && viewModel != nil) {
                                viewModel?.press(action.button)
                            }
                            .accessibilityIdentifier("speech-clone-engine-\(action.button.title)")
                        }
                    }
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
                    .foregroundStyle(shown.noteIsProblem ? (notchInk?.error ?? SettingsPanePalette.warning)
                        : (notchInk?.note ?? SettingsPanePalette.helper))
                    .accessibilityIdentifier("speech-clone-engine-note")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("speech-clone-engine")

            if shown.startWithVoiceBar != nil { startWithVoiceBarRow(shown) }
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
        let label = SettingsRowLabel(title: "Start with VoiceBar", description: Self.startWithVoiceBarNote)
            .help(Self.startWithVoiceBarDescription)
            .accessibilityHint(Self.startWithVoiceBarDescription)
        if let isOn = presentation.startWithVoiceBar {
            SettingsRowLayout {
                label
                Toggle("Start with VoiceBar", isOn: Binding(
                    get: { isOn },
                    set: { viewModel?.setStartWithVoiceBar($0) }
                ))
                .labelsHidden()
                .toggleStyle(.settingsSwitch)
                .disabled(!presentation.startWithVoiceBarEnabled || viewModel == nil)
                .accessibilityLabel("Start with VoiceBar")
            }
            .accessibilityIdentifier("speech-clone-engine-autostart")
        } else {
            SettingsRowLayout {
                label
                Text("Unavailable")
                    .font(.system(size: 11.5))
                    .foregroundStyle(notchInk?.note ?? SettingsPanePalette.helper)
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
    @Environment(\.notchPaneInk) private var notchInk

    static func color(_ tone: CloneEnginePillTone) -> Color {
        switch tone {
        case .green: .green
        case .blue: .blue
        case .grey: .gray
        case .red: .red
        }
    }

    /// On the notch glass the dot takes the notch's own state inks: the setup mark's green, the processing blue,
    /// the error red and the note ink for grey (no system colours on the glass).
    static func color(_ tone: CloneEnginePillTone, ink: NotchPaneInk) -> Color {
        switch tone {
        case .green: return SettingsMarkPalette.color(done: ink.appearance)
        case .blue: return Theme.transcribingSpinnerColor(for: ink.appearance)
        case .grey: return ink.note
        case .red: return ink.error
        }
    }

    var body: some View {
        let tint = notchInk.map { Self.color(presentation.tone, ink: $0) } ?? Self.color(presentation.tone)
        HStack(spacing: 5) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: pulses)
            Text(presentation.pill)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(notchInk.map { AnyShapeStyle($0.primary) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(0.14)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityStatus)
        .accessibilityIdentifier("speech-clone-engine-status")
    }
}
