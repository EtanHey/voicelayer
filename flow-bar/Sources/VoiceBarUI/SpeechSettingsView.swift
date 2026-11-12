import AppKit
import SwiftUI

public struct SpeechSettingsView: View {
    @State private var thresholdDraft = SpeechThresholdDraft()
    @State private var rateDraft: [SpeechProfile: Double] = [:]
    public let controls: SpeechControlsState?
    public let connected: Bool
    public let busy: Bool
    public var busyReason: String? = nil
    public let pending: [String: SpeechValue]
    public let notice: String?
    public let onChange: ((String, SpeechValue) -> Void)?
    public var onSelectEngine: ((SpeechProfile, String, String) -> Void)? = nil
    public let onPreview: ((SpeechProfile) -> Void)?
    /// V10 clone-engine status and controls; nil reads "Unavailable".
    public var cloneEngine: CloneEngineControlViewModel? = nil

    public static func fieldDisabled(_ key: String, controls: SpeechControlsState, pending: [String: SpeechValue], callbackAvailable: Bool = true) -> Bool {
        !callbackAvailable || controls.lockReason(for: key) != nil || pending[key] != nil
            || (key.hasSuffix(".voice") && (controls.lockReason(for: key.replacingOccurrences(of: ".voice", with: ".engine")) != nil
                || pending[key.replacingOccurrences(of: ".voice", with: ".engine")] != nil))
    }

    /// Spec V10: shown in orange under a profile that uses the cloned voice while the engine isn't running.
    static let fastVoiceFallbackLine = "Uses the fast voice while the engine is stopped."
    static let rateRange: ClosedRange<Double> = -30...50
    struct DisplayProfile {
        let engine: String
        let voice: String
        let voices: [String]
        let cloneWarning: Bool
    }
    static func displayProfile(_ kind: SpeechProfile, controls: SpeechControlsState, pending: [String: SpeechValue]) -> DisplayProfile? {
        guard let profile = controls.profiles[kind] else { return nil }
        func value(_ field: String, _ current: String) -> String {
            if case .string(let value) = pending["\(kind.rawValue).\(field)"] { return value }
            return current
        }
        let engine = value("engine", profile.engine.effective), voice = value("voice", profile.voice.effective)
        let voices = controls.voices(for: engine)
        return DisplayProfile(engine: engine, voice: voice, voices: voices, cloneWarning: engine == "clone" && !controls.cloneRunning)
    }

    public var body: some View {
        Form {
            CloneEngineSection(viewModel: cloneEngine)
            thresholdSection
            if let controls, connected {
                ForEach(SpeechProfile.allCases, id: \.self) { kind in
                    if let profile = controls.profiles[kind], let display = Self.displayProfile(kind, controls: controls, pending: pending) {
                        // Both profiles retain the candidate measurement helper. Disabled controls explain
                        // their state on hover or keyboard focus, and in their accessibility hint.
                        Section {
                            SettingsRow(title: "Voice", description: profile.latencyLabel.replacingOccurrences(of: #"(\d) s\b"#, with: "$1\u{00A0}s", options: .regularExpression)) {
                                voiceControl(kind, display: display, controls: controls)
                                previewControl(kind)
                            }
                            .accessibilityIdentifier("speech-\(kind.rawValue)-latency")
                            SettingsRow(title: "Rate", textMinWidth: Self.rateTitleWidth) {
                                rateControl(kind, profile: profile, controls: controls)
                            }
                            .disabled(Self.fieldDisabled("\(kind.rawValue).rate", controls: controls, pending: pending,
                                                         callbackAvailable: onChange != nil))
                            .accessibilityIdentifier("speech-\(kind.rawValue).rate")
                            // V10 removed the copy-a-command fallback; the engine row above starts the engine.
                            if display.cloneWarning {
                                Label(Self.fastVoiceFallbackLine, systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(SettingsPanePalette.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("speech-\(kind.rawValue)-fast-voice-fallback")
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(Self.subtitle(kind, limit: controls.shortLimit.effective))
                                    .font(.system(size: 11.5)).fontWeight(.regular)
                                    .foregroundStyle(SettingsPanePalette.helper)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let lock = Self.lockFooter(kind, controls: controls) {
                                    Label(lock, systemImage: "lock.fill").fixedSize(horizontal: false, vertical: true)
                                }
                                Text("Changes apply to the next speech.").font(.caption)
                            }.font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(connected ? "Speech settings are not reported by this VoiceLayer version." : "VoiceLayer isn't connected. Speech settings appear when it reconnects.")
                    .foregroundStyle(.secondary)
            }
            if let notice, pending["preview"] == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsCopyButton(text: notice, label: "speech error")
                }
            }
        }
        .onChange(of: controls?.shortLimit) { _, limit in thresholdDraft.reconcile(limit) }
        .formStyle(.grouped)
        // Draw above the Form, so short Voice rows cannot clip the reason at the card edge.
        .settingsLockedReasonBubble()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("speech-settings-form")
    }

    /// Keep the candidate reported-cutoff title, provenance and draft purpose on the control row.
    private var thresholdSection: some View {
        Section("Voice profile threshold") {
            let blocked = SpeechThresholdDraft.blockedReason(controls: controls, connected: connected, busy: busy,
                                                             pending: pending, callbackAvailable: onChange != nil)
            let canApply = thresholdDraft.canApply(controls: controls, connected: connected, busy: busy,
                                                   pending: pending, callbackAvailable: onChange != nil)
            let helper = [thresholdDraft.validationMessage, Self.thresholdPurpose, SpeechThresholdDraft.reportStatus]
                .compactMap { $0 }.joined(separator: " ")
            SettingsRow(title: SpeechThresholdDraft.confirmedLabel(controls?.shortLimit), description: helper) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Draft").font(.system(size: 10)).foregroundStyle(SettingsPanePalette.helper)
                    TextField("Characters", text: Binding(
                        get: { thresholdDraft.displayedText(controls?.shortLimit) },
                        set: { thresholdDraft.edit($0) }))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 58)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {} // Enter, like blur, never applies a draft.
                        .accessibilityLabel("Voice profile threshold draft in characters")
                        .accessibilityIdentifier("speech-threshold-draft")
                }
                Button("Apply") {
                    thresholdDraft.apply(controls: controls, connected: connected, busy: busy,
                                         pending: pending, onChange: onChange)
                }
                .controlSize(.small).fixedSize()
                .disabled(!canApply)
                .accessibilityIdentifier("speech-threshold-apply")
                .settingsLockedReason(canApply ? nil : blocked, stateLabel: nil, lift: 16)
                Button("Revert") { thresholdDraft.revert() }
                    .controlSize(.small).fixedSize()
                    .help(SpeechThresholdDraft.revertHelp)
                    .accessibilityHint(SpeechThresholdDraft.revertHelp)
                    .accessibilityLabel("Revert draft to last reported cutoff")
                    .disabled(thresholdDraft.text == nil || controls == nil)
                    .accessibilityIdentifier("speech-threshold-revert")
            }
            .settingsLockedReasonAboveRow()
            .help(SpeechThresholdDraft.confirmedLabel(controls?.shortLimit))
            .accessibilityIdentifier("speech-threshold-applied")
        }
    }

    static let thresholdPurpose = "Chooses the short or long voice profile for the next speech."

    @ViewBuilder
    private func voiceControl(_ kind: SpeechProfile, display: DisplayProfile, controls: SpeechControlsState) -> some View {
        let key = "\(kind.rawValue).voice"
        Group {
            if controls.lockReason(for: key) != nil || controls.lockReason(for: "\(kind.rawValue).engine") != nil {
                Text(Self.voiceLabel(display.voice)).foregroundStyle(.primary)
            } else {
                Picker("Voice", selection: Binding(get: { "\(display.engine):\(display.voice)" }, set: { id in
                    if let selected = controls.availableVoices.first(where: { "\($0.engine):\($0.voice)" == id }) {
                        onSelectEngine?(kind, selected.engine, selected.voice)
                    }
                })) {
                    Section("Fast") {
                        ForEach(controls.voices(for: "edge"), id: \.self) {
                            Text(Self.voiceLabel($0)).tag("edge:\($0)")
                        }
                    }
                    Section("Cloned") {
                        ForEach(controls.voices(for: "clone"), id: \.self) {
                            Text(Self.voiceLabel($0)).tag("clone:\($0)")
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .disabled(Self.fieldDisabled(key, controls: controls, pending: pending, callbackAvailable: onSelectEngine != nil))
        .accessibilityIdentifier("speech-\(key)")
    }

    /// Preview, disabled while a voice session runs or a change is pending; the reason shows on hover of the button.
    @ViewBuilder
    private func previewControl(_ kind: SpeechProfile) -> some View {
        let disabled = busy || !pending.isEmpty || onPreview == nil
        let previewing: Bool = { if case .string(let p) = pending["preview"] { return p == kind.rawValue }; return false }()
        HStack(spacing: 6) {
            if previewing { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14) }
            Button("Preview") { onPreview?(kind) }
                .disabled(disabled)
                .accessibilityIdentifier("speech-\(kind.rawValue)-preview")
                .settingsLockedReason(disabled && onPreview != nil
                    ? previewHint(kind) ?? Self.pendingChangeReason : nil, stateLabel: nil)
        }
    }

    static let pendingChangeReason = "Saving your last change…"

    @ViewBuilder
    private func rateControl(_ kind: SpeechProfile, profile: SpeechControlsState.Profile,
                             controls: SpeechControlsState) -> some View {
        let rate = binding("\(kind.rawValue).rate", profile.rate.effective)
        if controls.lockReason(for: "\(kind.rawValue).rate") != nil {
            Text(Self.rateLabel(rate.wrappedValue)).foregroundStyle(.primary)
        } else {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { rateDraft[kind] ?? min(50, max(-30, Double(rate.wrappedValue.dropLast()) ?? 0)) },
                                      set: { rateDraft[kind] = $0 }),
                       in: Self.rateRange, step: 5, label: { Text("\(kind.title) rate") },
                       minimumValueLabel: { Image(systemName: "tortoise").accessibilityLabel("Slower") },
                       maximumValueLabel: { Image(systemName: "hare").accessibilityLabel("Faster") },
                       onEditingChanged: { editing in
                           if !editing, let value = rateDraft.removeValue(forKey: kind) {
                               rate.wrappedValue = String(format: "%+d%%", Int(value))
                           }
                       })
                       .labelsHidden()
                       .foregroundStyle(.secondary)
                       .frame(width: Self.rateSliderWidth)
                Text(Self.rateValueLabel(rateDraft[kind].map { String(format: "%+d%%", Int($0)) } ?? rate.wrappedValue))
                    .monospacedDigit().foregroundStyle(.primary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    static let rateSliderWidth: CGFloat = 170
    /// "Rate" needs only its own width; the slider takes the rest of the row.
    static let rateTitleWidth: CGFloat = 44

    static func engineLabel(_ engine: String) -> String { SpeechControlsState.isFastVoice(engine) ? "Fast" : "Cloned voice" }
    static func voiceLabel(_ id: String) -> String {
        let names = ["theo-c4s": "Theo", "ben-c1": "Ben", "en-US-JennyNeural": "Jenny (US)", "en-US-GuyNeural": "Guy (US)",
                     "en-US-AndrewNeural": "Andrew (US)", "en-US-BrianMultilingualNeural": "Brian (US, multilingual)",
                     "en-US-AvaNeural": "Ava (US)", "en-US-AriaNeural": "Aria (US)"]
        return names[id] ?? id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
    /// Beside the slider (lane S PR 3): "Normal" at 0, else the signed percent ("+10%", "-20%"); the tortoise and hare at
    /// the slider's ends say which way is slower.
    static func rateValueLabel(_ rate: String) -> String {
        guard let percent = Int(rate.dropLast()) else { return rate }
        return percent == 0 ? "Normal" : String(format: "%+d%%", percent)
    }

    static func rateLabel(_ rate: String) -> String {
        guard let percent = Int(rate.dropLast()) else { return rate }
        if percent == 0 { return "Normal" }
        return "\(rate) \(percent > 0 ? "faster" : "slower")"
    }
    static func subtitle(_ kind: SpeechProfile, limit: Int) -> String {
        kind == .short ? "Agent announcements and automatic reads up to \(limit) characters."
            : "Reads over \(limit) characters, such as the speak command and Option+F5."
    }
    static func lockFooter(_ kind: SpeechProfile, controls: SpeechControlsState) -> String? {
        guard let profile = controls.profiles[kind] else { return nil }
        var variables: [String] = []
        if profile.engine.source == .environment || profile.voice.source == .environment { variables.append("QA_VOICE_TTS_VOICE (engine and voice)") }
        if profile.rate.source == .environment { variables.append("QA_VOICE_TTS_RATE (rate)") }
        guard !variables.isEmpty else { return nil }
        return "Locked by environment \(variables.count == 1 ? "variable" : "variables") \(variables.joined(separator: " and ")) (applies to both profiles). Unset \(variables.count == 1 ? "it" : "them") and restart VoiceLayer to change this here."
    }
    static func cloneStatusOwner(controls: SpeechControlsState, pending: [String: SpeechValue]) -> SpeechProfile? {
        SpeechProfile.allCases.first { displayProfile($0, controls: controls, pending: pending)?.engine == "clone" }
    }
    private func previewHint(_ kind: SpeechProfile) -> String? {
        if case .string(let profile) = pending["preview"], profile == kind.rawValue {
            return notice ?? (busyReason == "Speaking…" ? "Speaking…" : "Preview in progress…")
        }
        if busyReason == "Speaking…" { return "Speaking…" }
        if busy { return busyReason ?? "Voice session in progress" }
        return nil
    }
    private func binding(_ key: String, _ current: String) -> Binding<String> {
        Binding(get: { if case .string(let s) = pending[key] { return s }; return current },
                set: { onChange?(key, .string($0)) })
    }
}
