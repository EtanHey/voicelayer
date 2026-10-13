import SwiftUI

public struct SpeechSettingsView: View {
    @State private var rateDraft: [SpeechProfile: Double] = [:]
    public let controls: SpeechControlsState?
    public let connected: Bool
    public let busy: Bool
    public let pending: [String: SpeechValue]
    public let notice: String?
    public let onChange: ((String, SpeechValue) -> Void)?
    public var onSelectEngine: ((SpeechProfile, String, String) -> Void)? = nil
    public let onPreview: ((SpeechProfile) -> Void)?

    public static func fieldDisabled(_ key: String, controls: SpeechControlsState, pending: [String: SpeechValue]) -> Bool {
        controls.lockReason(for: key) != nil || pending[key] != nil
    }

    public var body: some View {
        Form {
            if let controls, connected {
                ForEach(SpeechProfile.allCases, id: \.self) { kind in
                    if let profile = controls.profiles[kind] {
                        Section(kind.title) {
                            Text(kind == .short ? "Agent announcements" : "Long text · speak CLI and Option+F5")
                                .font(.caption).foregroundStyle(.secondary)
                            field("Engine", key: "\(kind.rawValue).engine", controls: controls) {
                                Picker("Engine", selection: Binding(get: { profile.engine.effective }, set: { engine in
                                    if let voice = controls.preferredVoice(for: engine, current: profile.voice.effective) {
                                        onSelectEngine?(kind, engine, voice)
                                    }
                                })) {
                                    Text("Fast (edge)").tag("edge").disabled(controls.voices(for: "edge").isEmpty)
                                    Text("Cloned").tag("clone").disabled(controls.voices(for: "clone").isEmpty)
                                }.labelsHidden()
                                    .disabled(onSelectEngine == nil || controls.lockReason(for: "\(kind.rawValue).voice") != nil
                                              || pending["\(kind.rawValue).voice"] != nil)
                            }
                            field("Voice", key: "\(kind.rawValue).voice", controls: controls) {
                                let voices = controls.voices(for: profile.engine.effective)
                                Picker("Voice", selection: binding("\(kind.rawValue).voice", profile.voice.effective)) {
                                    if !voices.contains(profile.voice.effective) {
                                        Text("\(profile.voice.effective) (not in this engine)").tag(profile.voice.effective)
                                    }
                                    ForEach(voices, id: \.self) { Text($0).tag($0) }
                                }.labelsHidden()
                            }
                            field("Rate", key: "\(kind.rawValue).rate", controls: controls) {
                                let key = "\(kind.rawValue).rate"
                                let rate = binding(key, profile.rate.effective)
                                HStack {
                                    Slider(value: Binding(get: { rateDraft[kind] ?? min(50, max(-30, Double(rate.wrappedValue.dropLast()) ?? 0)) },
                                                          set: { rateDraft[kind] = $0 }),
                                           in: -30...50, step: 5, onEditingChanged: { editing in
                                               if !editing, let value = rateDraft.removeValue(forKey: kind) {
                                                   rate.wrappedValue = String(format: "%+d%%", Int(value))
                                               }
                                           })
                                        .accessibilityLabel("\(kind.title) rate")
                                    Text(rateDraft[kind].map { String(format: "%+d%%", Int($0)) } ?? rate.wrappedValue).monospacedDigit().frame(width: 48, alignment: .trailing)
                                }
                            }
                            if profile.engine.effective == "clone", !controls.cloneRunning {
                                Text("Clone engine is not running. Speech will fall back to the fast voice.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            HStack {
                                Button("Preview") { onPreview?(kind) }
                                    .disabled(busy || !pending.isEmpty || onPreview == nil)
                                    .accessibilityIdentifier("speech-\(kind.rawValue)-preview")
                                Spacer()
                                Text(profile.latencyLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    field("Long-read threshold", key: "short_limit_chars", controls: controls) {
                        SpeechThresholdField(value: controls.shortLimit.effective) {
                            onChange?("short_limit_chars", .number($0))
                        }
                        Text("characters").foregroundStyle(.secondary)
                    }
                    Text(controls.cloneRunning ? "Clone engine: running" : "Clone engine: not running (start with `voicelayer daemon`)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Changes apply to the next speak.").font(.caption).foregroundStyle(.secondary)
                    if busy { Text("Preview is available when the voice session finishes.").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Text(connected ? "Speech settings are not reported by this VoiceLayer version." : "VoiceLayer isn't connected. Speech settings appear when it reconnects.")
                    .foregroundStyle(.secondary)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("speech-settings-form")
    }

    private func binding(_ key: String, _ current: String) -> Binding<String> {
        Binding(get: { if case .string(let s) = pending[key] { return s }; return current },
                set: { onChange?(key, .string($0)) })
    }
    private func field(_ title: String, key: String, controls: SpeechControlsState, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); content() }
                .disabled(Self.fieldDisabled(key, controls: controls, pending: pending) || onChange == nil)
                .accessibilityIdentifier("speech-\(key)")
            if let reason = controls.lockReason(for: key) { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
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
