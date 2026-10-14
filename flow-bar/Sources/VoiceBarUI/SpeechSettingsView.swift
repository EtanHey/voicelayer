import SwiftUI

public struct SpeechSettingsView: View {
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
        var voices = controls.voices(for: engine)
        if !voices.contains(voice) { voices.append(voice) }
        return DisplayProfile(engine: engine, voice: voice, voices: voices, cloneWarning: engine == "clone" && !controls.cloneRunning)
    }

    public var body: some View {
        Form {
            if let controls, connected {
                ForEach(SpeechProfile.allCases, id: \.self) { kind in
                    if let profile = controls.profiles[kind], let display = Self.displayProfile(kind, controls: controls, pending: pending) {
                        Section {
                            if kind == .long {
                                field("Long-read threshold", key: "short_limit_chars", controls: controls) {
                                    SpeechThresholdField(value: controls.shortLimit.effective) {
                                        onChange?("short_limit_chars", .number($0))
                                    }
                                    Text("characters").foregroundStyle(.secondary)
                                }
                            }
                            field("Engine", key: "\(kind.rawValue).engine", controls: controls) {
                                if controls.lockReason(for: "\(kind.rawValue).engine") != nil {
                                    Text(Self.engineLabel(display.engine)).foregroundStyle(.primary)
                                } else {
                                    Picker("Engine", selection: Binding(get: { display.engine }, set: { engine in
                                        if let voice = controls.preferredVoice(for: engine, current: display.voice) {
                                            onSelectEngine?(kind, engine, voice)
                                        }
                                    })) {
                                        Text("Fast").tag("edge").disabled(controls.voices(for: "edge").isEmpty)
                                        Text("Cloned voice").tag("clone").disabled(controls.voices(for: "clone").isEmpty)
                                    }.labelsHidden()
                                        .disabled(controls.lockReason(for: "\(kind.rawValue).voice") != nil || pending["\(kind.rawValue).voice"] != nil)
                                }
                            }
                            field("Voice", key: "\(kind.rawValue).voice", controls: controls) {
                                if controls.lockReason(for: "\(kind.rawValue).voice") != nil {
                                    Text(Self.voiceLabel(display.voice)).foregroundStyle(.primary)
                                } else {
                                    Picker("Voice", selection: binding("\(kind.rawValue).voice", display.voice)) {
                                        ForEach(display.voices, id: \.self) { Text(Self.voiceLabel($0)).tag($0) }
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
                                    VStack(spacing: 2) {
                                        HStack {
                                            Slider(value: Binding(get: { rateDraft[kind] ?? min(50, max(-30, Double(rate.wrappedValue.dropLast()) ?? 0)) },
                                                                  set: { rateDraft[kind] = $0 }),
                                                   in: -30...50, step: 5, onEditingChanged: { editing in
                                                       if !editing, let value = rateDraft.removeValue(forKey: kind) {
                                                           rate.wrappedValue = String(format: "%+d%%", Int(value))
                                                       }
                                                   }).accessibilityLabel("\(kind.title) rate")
                                            Text(Self.rateLabel(rateDraft[kind].map { String(format: "%+d%%", Int($0)) } ?? rate.wrappedValue))
                                                .monospacedDigit().frame(width: 110, alignment: .trailing)
                                        }
                                        HStack {
                                            Text("Slower"); Spacer(); Text("0% · Normal"); Spacer(); Text("Faster")
                                        }.font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if Self.cloneStatusOwner(controls: controls, pending: pending) == kind {
                                if display.cloneWarning {
                                    Label("Clone engine isn't running, so this will use the fast voice. Start it with `voicelayer daemon`.",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.primary).font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Label("Clone engine is running.", systemImage: "checkmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(kind.title)
                                Text(Self.subtitle(kind, limit: controls.shortLimit.effective) + (kind == .short ? " Changes apply to the next speech." : ""))
                                    .font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let lock = Self.lockFooter(kind, controls: controls) {
                                    Label(lock, systemImage: "lock.fill").fixedSize(horizontal: false, vertical: true)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(connected ? "Speech settings are not reported by this VoiceLayer version." : "VoiceLayer isn't connected. Speech settings appear when it reconnects.")
                    .foregroundStyle(.secondary)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.primary) }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("speech-settings-form")
    }

    static func engineLabel(_ engine: String) -> String { engine == "clone" ? "Cloned voice" : "Fast" }
    static func voiceLabel(_ id: String) -> String {
        let names = ["en-US-JennyNeural": "Jenny (US)", "en-US-GuyNeural": "Guy (US)",
                     "en-US-AndrewNeural": "Andrew (US)", "en-US-BrianMultilingualNeural": "Brian (US, multilingual)",
                     "en-US-AvaNeural": "Ava (US)", "en-US-AriaNeural": "Aria (US)"]
        return names[id] ?? id.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func rateLabel(_ rate: String) -> String {
        guard let percent = Int(rate.dropLast()) else { return rate }
        if percent == 0 { return "Normal" }
        return "\(rate) \(percent > 0 ? "faster" : "slower")"
    }
    static func subtitle(_ kind: SpeechProfile, limit: Int) -> String {
        kind == .short ? "Agent announcements and automatic reads up to \(limit) characters."
            : "Automatic reads over \(limit) characters, including the speak command and Option+F5."
    }
    static func lockFooter(_ kind: SpeechProfile, controls: SpeechControlsState) -> String? {
        guard let profile = controls.profiles[kind] else { return nil }
        var variables: [String] = []
        if profile.engine.source == .environment || profile.voice.source == .environment { variables.append("QA_VOICE_TTS_VOICE") }
        if profile.rate.source == .environment { variables.append("QA_VOICE_TTS_RATE") }
        guard !variables.isEmpty else { return nil }
        return "Locked by environment \(variables.joined(separator: " and ")) (applies to both profiles). Unset \(variables.count == 1 ? "it" : "them") and restart VoiceLayer to change this here."
    }
    static func cloneStatusOwner(controls: SpeechControlsState, pending: [String: SpeechValue]) -> SpeechProfile? {
        SpeechProfile.allCases.first { displayProfile($0, controls: controls, pending: pending)?.engine == "clone" }
    }
    private func previewHint(_ kind: SpeechProfile) -> String? {
        if busyReason == "Speaking…" { return "Speaking…" }
        if case .string(let profile) = pending["preview"], profile == kind.rawValue { return "Preview in progress…" }
        if busy { return busyReason ?? "Voice session in progress" }
        return nil
    }
    private func binding(_ key: String, _ current: String) -> Binding<String> {
        Binding(get: { if case .string(let s) = pending[key] { return s }; return current },
                set: { onChange?(key, .string($0)) })
    }
    private func field(_ title: String, key: String, controls: SpeechControlsState, @ViewBuilder content: () -> some View) -> some View {
        HStack { Text(title); Spacer(); content() }
            .disabled(Self.fieldDisabled(key, controls: controls, pending: pending,
                                        callbackAvailable: key.hasSuffix(".engine") ? onSelectEngine != nil : onChange != nil))
            .accessibilityIdentifier("speech-\(key)")
    }
}

/// Keep typing local; persist only the completed field, like a completed rate drag.
private struct SpeechThresholdField: View {
    let value: Int
    let onCommit: (Int) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("Characters", text: $draft)
            .labelsHidden().frame(width: 90).multilineTextAlignment(.trailing)
            .focused($focused)
            .onAppear { draft = String(value) }
            .onChange(of: value) { _, value in if !focused { draft = String(value) } }
            .onSubmit { commit() }
            .onChange(of: focused) { _, focused in if !focused { commit() } }
            .accessibilityLabel("Long-read threshold in characters")
    }
    private func commit() {
        guard let number = Int(draft), number > 0 else { draft = String(value); return }
        if number != value { onCommit(number) }
    }
}
