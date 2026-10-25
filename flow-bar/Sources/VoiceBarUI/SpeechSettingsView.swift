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

    public static func fieldDisabled(_ key: String, controls: SpeechControlsState, pending: [String: SpeechValue], callbackAvailable: Bool = true) -> Bool {
        !callbackAvailable || controls.lockReason(for: key) != nil || pending[key] != nil
            || (key.hasSuffix(".voice") && (controls.lockReason(for: key.replacingOccurrences(of: ".voice", with: ".engine")) != nil
                || pending[key.replacingOccurrences(of: ".voice", with: ".engine")] != nil))
    }

    static let daemonCommand = "voicelayer daemon"
    static let rateRange: ClosedRange<Double> = -30...50
    static let normalRateFraction = (0 - rateRange.lowerBound) / (rateRange.upperBound - rateRange.lowerBound)
    /// The native horizontal knob's width; its centre stops half of it in from each end. A constant on purpose:
    /// asking AppKit for it inside `body` re-entered the SwiftUI graph update and aborted (SETUI1 round 2). The
    /// AppKit value is pinned by SpeechSettingsRenderTests, outside any view.
    static let sliderKnobWidth: CGFloat = 20

    /// Where a caption must be centred to sit under the knob at `fraction` of the range. SETUI1: centring on
    /// `width * fraction` put "Normal" 2.5 pt left of the knob at 300 pt, because the knob never reaches the edges.
    static func rateCaptionX(fraction: Double, width: CGFloat, knobWidth: CGFloat) -> CGFloat {
        guard width > knobWidth else { return width * fraction }
        return knobWidth / 2 + (width - knobWidth) * fraction
    }

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
            thresholdSection
            if let controls, connected {
                ForEach(SpeechProfile.allCases, id: \.self) { kind in
                    if let profile = controls.profiles[kind], let display = Self.displayProfile(kind, controls: controls, pending: pending) {
                        Section {
                            field("Voice", key: "\(kind.rawValue).voice", controls: controls) {
                                if controls.lockReason(for: "\(kind.rawValue).voice") != nil || controls.lockReason(for: "\(kind.rawValue).engine") != nil {
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
                                    }.labelsHidden()
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Button("Preview") { onPreview?(kind) }
                                        .disabled(busy || !pending.isEmpty || onPreview == nil)
                                        .accessibilityIdentifier("speech-\(kind.rawValue)-preview")
                                    if let hint = previewHint(kind) {
                                        Text(hint).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(profile.latencyLabel).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help("Time from requesting speech until the audio player starts, including preparation and queue wait.")
                                    .accessibilityIdentifier("speech-\(kind.rawValue)-latency")
                            }
                            field("Rate", key: "\(kind.rawValue).rate", controls: controls) {
                                let rate = binding("\(kind.rawValue).rate", profile.rate.effective)
                                if controls.lockReason(for: "\(kind.rawValue).rate") != nil {
                                    Text(Self.rateLabel(rate.wrappedValue)).foregroundStyle(.primary)
                                } else {
                                    HStack(alignment: .top) {
                                        Slider(value: Binding(get: { rateDraft[kind] ?? min(50, max(-30, Double(rate.wrappedValue.dropLast()) ?? 0)) },
                                                              set: { rateDraft[kind] = $0 }),
                                               in: Self.rateRange, step: 5, onEditingChanged: { editing in
                                                   if !editing, let value = rateDraft.removeValue(forKey: kind) {
                                                       rate.wrappedValue = String(format: "%+d%%", Int(value))
                                                   }
                                               }).accessibilityLabel("\(kind.title) rate")
                                            // The row supplies "Rate"; omit Form's empty built-in label column.
                                            .labelsHidden()
                                            .overlay(alignment: .top) {
                                                GeometryReader { geometry in
                                                    HStack {
                                                        Text("Slower")
                                                        Spacer()
                                                        Text("Faster")
                                                    }
                                                    Text("Normal")
                                                        .fixedSize()
                                                        .position(x: Self.rateCaptionX(
                                                            fraction: Self.normalRateFraction,
                                                            width: geometry.size.width,
                                                            knobWidth: Self.sliderKnobWidth
                                                        ),
                                                                  y: geometry.size.height / 2)
                                                }
                                                .font(.caption2).foregroundStyle(.secondary)
                                                .frame(height: 14)
                                                .offset(y: 24)
                                            }
                                            .frame(height: 22)
                                            .padding(.bottom, 16)
                                        Text(Self.rateValueLabel(rateDraft[kind].map { String(format: "%+d%%", Int($0)) } ?? rate.wrappedValue))
                                            .monospacedDigit().frame(width: 110, height: 22, alignment: .trailing)
                                    }
                                }
                            }
                            if display.cloneWarning || Self.cloneStatusOwner(controls: controls, pending: pending) == kind {
                                if display.cloneWarning {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("Clone engine isn't running, so this will use the fast voice (fallback). Start it with:",
                                              systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.primary).font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack {
                                            Text(Self.daemonCommand).font(.system(.callout, design: .monospaced))
                                            SettingsCopyButton(text: Self.daemonCommand, label: "daemon command")
                                        }
                                    }
                                } else {
                                    Label("Clone engine is running.", systemImage: "checkmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title)
                                Text(SpeechThresholdDraft.captionContext).font(.caption).foregroundStyle(.secondary)
                                Text(Self.subtitle(kind, limit: controls.shortLimit.effective))
                                    .font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let lock = Self.lockFooter(kind, controls: controls) {
                                    Label(lock, systemImage: "lock.fill").fixedSize(horizontal: false, vertical: true)
                                }
                                if kind == .long { Text("Changes apply to the next speech.").font(.caption) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("speech-settings-form")
    }

    private var thresholdSection: some View {
        Section("Voice profile threshold") {
            Text(SpeechThresholdDraft.confirmedLabel(controls?.shortLimit))
                .accessibilityIdentifier("speech-threshold-applied")
            Text(SpeechThresholdDraft.reportStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Draft")
                TextField("Characters", text: Binding(
                    get: { thresholdDraft.displayedText(controls?.shortLimit) },
                    set: { thresholdDraft.edit($0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 130)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {} // Enter, like blur, never applies a draft.
                    .accessibilityLabel("Voice profile threshold draft in characters")
                    .accessibilityIdentifier("speech-threshold-draft")
                Text("characters").foregroundStyle(.secondary)
                Spacer()
                Button("Apply") {
                    thresholdDraft.apply(controls: controls, connected: connected, busy: busy,
                                         pending: pending, onChange: onChange)
                }
                .disabled(!thresholdDraft.canApply(controls: controls, connected: connected, busy: busy,
                                                  pending: pending, callbackAvailable: onChange != nil))
                .accessibilityIdentifier("speech-threshold-apply")
                Button("Revert") { thresholdDraft.revert() }
                    .help(SpeechThresholdDraft.revertHelp)
                    .accessibilityLabel("Revert draft to last reported cutoff")
                    .disabled(thresholdDraft.text == nil || controls == nil)
                    .accessibilityIdentifier("speech-threshold-revert")
            }
            if let message = thresholdDraft.validationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let reason = SpeechThresholdDraft.blockedReason(controls: controls, connected: connected, busy: busy,
                                                               pending: pending, callbackAvailable: onChange != nil) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Text("Chooses the short or long voice profile for the next speech.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func engineLabel(_ engine: String) -> String { engine == "clone" ? "Cloned voice" : "Fast" }
    static func voiceLabel(_ id: String) -> String {
        let names = ["theo-c4s": "Theo", "ben-c1": "Ben", "en-US-JennyNeural": "Jenny (US)", "en-US-GuyNeural": "Guy (US)",
                     "en-US-AndrewNeural": "Andrew (US)", "en-US-BrianMultilingualNeural": "Brian (US, multilingual)",
                     "en-US-AvaNeural": "Ava (US)", "en-US-AriaNeural": "Aria (US)"]
        return names[id] ?? id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
    /// Beside the slider, whose caption already says "Normal" under 0: the value reads "0%" there, not "Normal" twice.
    static func rateValueLabel(_ rate: String) -> String {
        Int(rate.dropLast()) == 0 ? "0%" : rateLabel(rate)
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
    private func field(_ title: String, key: String, controls: SpeechControlsState, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: key.hasSuffix(".rate") ? .top : .center) {
            Text(title).padding(.top, key.hasSuffix(".rate") && controls.lockReason(for: key) == nil ? 3 : 0)
            Spacer()
            content()
        }
            .disabled(Self.fieldDisabled(key, controls: controls, pending: pending,
                                        callbackAvailable: (key.hasSuffix(".engine") || key.hasSuffix(".voice")) ? onSelectEngine != nil : onChange != nil))
            .accessibilityIdentifier("speech-\(key)")
    }
}
