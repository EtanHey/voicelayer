import AppKit
import SwiftUI

public struct SpeechSettingsView: View {
    @State private var thresholdDraft = SpeechThresholdDraft()
    @State private var rateDraft: [SpeechProfile: Double] = [:]
    /// Set by the notch drawer: palette ink on the glass. Nil in the legacy Settings window (system ink).
    @Environment(\.notchPaneInk) private var notchInk
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
                            SettingsRow(title: "Voice", description: Self.latencyNote(profile.latencyLabel)) {
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
                                Text(kind.title).foregroundStyle(primaryInk)
                                Text(Self.subtitle(kind, limit: controls.shortLimit.effective))
                                    .font(.system(size: 11.5)).fontWeight(.regular)
                                    .foregroundStyle(readInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } footer: {
                            // Both notes concern both profiles, so they show once, under the last one, one line each
                            // (2.4.6 track S); the full lock explanation is on hover and in the accessibility hint.
                            if kind == SpeechProfile.allCases.last {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let lock = Self.lockNote(controls: controls) {
                                        Label(lock.short, systemImage: "lock.fill")
                                            .help(lock.full)
                                            .accessibilityHint(lock.full)
                                    }
                                    Text(Self.appliesNote)
                                }
                                .font(.system(size: 11.5)).foregroundStyle(readInk)
                            }
                        }
                    }
                }
            } else {
                Text(connected ? "Speech settings are not reported by this VoiceLayer version." : "VoiceLayer isn't connected. Speech settings appear when it reconnects.")
                    .foregroundStyle(readInk)
            }
            if let notice, pending["preview"] == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.caption).foregroundStyle(noticeInk(notice))
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

    /// One row: what the threshold does in one line, the draft and its actions beside it, and the reported cutoff's
    /// provenance behind the info glyph (2.4.6 track S; it was a three-line title over a four-line caption).
    private var thresholdSection: some View {
        Section {
            let blocked = SpeechThresholdDraft.blockedReason(controls: controls, connected: connected, busy: busy,
                                                             pending: pending, callbackAvailable: onChange != nil)
            let canApply = thresholdDraft.canApply(controls: controls, connected: connected, busy: busy,
                                                   pending: pending, callbackAvailable: onChange != nil)
            let detail = Self.thresholdDetail(controls?.shortLimit)
            SettingsRow(title: Self.thresholdTitle, description: Self.thresholdSummary(controls?.shortLimit)) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(readInk)
                    .help(detail)
                    .accessibilityLabel("About the threshold")
                    .accessibilityValue(detail)
                    .accessibilityIdentifier("speech-threshold-info")
                TextField("Characters", text: Binding(
                    get: { thresholdDraft.displayedText(controls?.shortLimit) },
                    set: { thresholdDraft.edit($0) }))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .settingsPaneField(width: 58)
                    .onSubmit {} // Enter, like blur, never applies a draft.
                    .accessibilityLabel("Voice profile threshold draft in characters")
                    .accessibilityIdentifier("speech-threshold-draft")
                SettingsPaneButton(title: "Apply", isEnabled: canApply, prominent: true) {
                    thresholdDraft.apply(controls: controls, connected: connected, busy: busy,
                                         pending: pending, onChange: onChange)
                }
                .accessibilityIdentifier("speech-threshold-apply")
                .settingsLockedReason(canApply ? nil : blocked, stateLabel: nil)
                SettingsPaneButton(title: "Revert", isEnabled: thresholdDraft.text != nil && controls != nil) {
                    thresholdDraft.revert()
                }
                .help(SpeechThresholdDraft.revertHelp)
                .accessibilityHint(SpeechThresholdDraft.revertHelp)
                .accessibilityLabel("Revert draft to last reported cutoff")
                .accessibilityIdentifier("speech-threshold-revert")
            }
            .settingsLockedReasonAboveRow()
            .help(detail)
            .accessibilityIdentifier("speech-threshold-applied")
            if let invalid = thresholdDraft.validationMessage {
                Text(invalid)
                    .font(.system(size: 11.5))
                    .foregroundStyle(notchInk?.error ?? SettingsPanePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("speech-threshold-invalid")
            }
        } header: {
            // No words: the row says what it is. The band only gives Apply's locked reason, which rises above the
            // row, empty space to land in instead of the engine card's last line.
            Color.clear.frame(height: Self.thresholdReasonBand).accessibilityHidden(true)
        }
    }

    static let thresholdReasonBand: CGFloat = 1

    static let thresholdTitle = "Voice threshold"
    /// The row's one line: what the last reported cutoff does.
    static func thresholdSummary(_ limit: SpeechSetting<Int>?) -> String {
        guard let limit else { return "Waiting for VoiceLayer to report it." }
        return "Long voice over \(limit.effective) characters."
    }
    /// Everything the row used to print, behind the info glyph: the reported cutoff and its provenance, what it
    /// chooses, and that descriptions and Revert follow the last report.
    static func thresholdDetail(_ limit: SpeechSetting<Int>?) -> String {
        [SpeechThresholdDraft.confirmedLabel(limit), thresholdPurpose, SpeechThresholdDraft.reportStatus]
            .joined(separator: "\n")
    }
    static let appliesNote = "Changes apply to the next speech."
    /// The Voice row's one line: "First sound 0.8 s · Fast voice" (the reported label leads with "Last speech: first
    /// sound after", which wrapped beside the picker). The number keeps its unit on the same line.
    static func latencyNote(_ label: String) -> String {
        label.replacingOccurrences(of: "Last speech: first sound after ", with: "First sound ")
            .replacingOccurrences(of: #"(\d) s\b"#, with: "$1\u{00A0}s", options: .regularExpression)
    }

    static let thresholdPurpose = "Chooses the short or long voice profile for the next speech."

    @ViewBuilder
    private func voiceControl(_ kind: SpeechProfile, display: DisplayProfile, controls: SpeechControlsState) -> some View {
        let key = "\(kind.rawValue).voice"
        Group {
            if controls.lockReason(for: key) != nil || controls.lockReason(for: "\(kind.rawValue).engine") != nil {
                Text(Self.voiceLabel(display.voice)).foregroundStyle(primaryInk)
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
            SettingsPaneButton(title: "Preview", isEnabled: !disabled) { onPreview?(kind) }
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
            Text(Self.rateLabel(rate.wrappedValue)).foregroundStyle(primaryInk)
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
                       .foregroundStyle(readInk)
                       .tint(notchInk?.palette.secondary.color)
                       .frame(width: Self.rateSliderWidth)
                Text(Self.rateValueLabel(rateDraft[kind].map { String(format: "%+d%%", Int($0)) } ?? rate.wrappedValue))
                    .monospacedDigit().foregroundStyle(primaryInk)
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
        kind == .short ? "Announcements and reads up to \(limit) characters."
            : "Reads over \(limit) characters: speak and Option+F5."
    }
    /// The lock, once for the pane: a one-line note naming the variables, and the full explanation for hover.
    static func lockNote(controls: SpeechControlsState) -> (short: String, full: String)? {
        for kind in SpeechProfile.allCases {
            guard let full = lockFooter(kind, controls: controls), let profile = controls.profiles[kind] else { continue }
            var names: [String] = []
            if profile.engine.source == .environment || profile.voice.source == .environment { names.append("QA_VOICE_TTS_VOICE") }
            if profile.rate.source == .environment { names.append("QA_VOICE_TTS_RATE") }
            return ("Locked by \(names.joined(separator: " and ")).", full)
        }
        return nil
    }
    private var primaryInk: AnyShapeStyle {
        notchInk.map { AnyShapeStyle($0.primary) } ?? AnyShapeStyle(.primary)
    }
    private var readInk: AnyShapeStyle {
        notchInk.map { AnyShapeStyle($0.note) } ?? AnyShapeStyle(.secondary)
    }
    /// A request outcome is an error unless it is a progress line ("Preparing preview…").
    private func noticeInk(_ notice: String) -> AnyShapeStyle {
        guard let notchInk else { return AnyShapeStyle(.primary) }
        return notice.hasSuffix("…") ? AnyShapeStyle(notchInk.primary) : AnyShapeStyle(notchInk.error)
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
