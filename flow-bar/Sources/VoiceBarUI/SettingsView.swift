import SwiftUI

public enum SettingsTab: Hashable {
    case general
    case audio
    case dictionary
}

public struct SettingsView: View {
    public let hotkeyEnabled: Bool
    public let missingPermissions: [HotkeyPermission]
    public let availableDevices: () -> [MicrophoneDevice]
    public let selectedDeviceID: () -> String?
    public let onSelectDevice: (String) -> Void
    public let anchorMode: () -> VoiceBarAnchorMode
    public let onSelectAnchorMode: (VoiceBarAnchorMode) -> Void
    public let isPositionLocked: () -> Bool
    public let onSetPositionLocked: (Bool) -> Void
    public let vocabularyPreview: () -> STTVocabularyPreview
    public let onAddVocabularyAlias: (String, String) -> Void
    public let onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void

    @State private var selectedTab: SettingsTab
    @State private var dictionarySearch = ""
    @State private var selectedAlias: STTVocabularyAliasPreview?
    @State private var correctText = ""
    @State private var wrongText = ""

    public init(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        availableDevices: @escaping () -> [MicrophoneDevice],
        selectedDeviceID: @escaping () -> String?,
        onSelectDevice: @escaping (String) -> Void,
        anchorMode: @escaping () -> VoiceBarAnchorMode = { .follow },
        onSelectAnchorMode: @escaping (VoiceBarAnchorMode) -> Void = { _ in },
        isPositionLocked: @escaping () -> Bool = { false },
        onSetPositionLocked: @escaping (Bool) -> Void = { _ in },
        vocabularyPreview: @escaping () -> STTVocabularyPreview = {
            STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        },
        onAddVocabularyAlias: @escaping (String, String) -> Void = { _, _ in },
        onRemoveVocabularyAlias: @escaping (STTVocabularyAliasPreview) -> Void = { _ in },
        initialTab: SettingsTab = .general
    ) {
        self.hotkeyEnabled = hotkeyEnabled
        self.missingPermissions = missingPermissions
        self.availableDevices = availableDevices
        self.selectedDeviceID = selectedDeviceID
        self.onSelectDevice = onSelectDevice
        self.anchorMode = anchorMode
        self.onSelectAnchorMode = onSelectAnchorMode
        self.isPositionLocked = isPositionLocked
        self.onSetPositionLocked = onSetPositionLocked
        self.vocabularyPreview = vocabularyPreview
        self.onAddVocabularyAlias = onAddVocabularyAlias
        self.onRemoveVocabularyAlias = onRemoveVocabularyAlias
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            audioTab
                .tabItem { Label("Audio", systemImage: "mic.fill") }
                .tag(SettingsTab.audio)
            dictionaryTab
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
                .tag(SettingsTab.dictionary)
        }
        .frame(width: 520, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                LabeledContent("Shortcut") {
                    Text(VoiceBarHotkeyContract.primaryShortcutLabel)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hotkeyEnabled ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(hotkeyStatusText)
                    }
                }
                if !missingPermissions.isEmpty {
                    LabeledContent("Fix") {
                        Button("Open System Settings") {
                            openAccessibilitySettings()
                        }
                    }
                }
            }

            Section("Gestures") {
                LabeledContent("Single tap") {
                    Text(VoiceBarHotkeyContract.singleTapDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hold") {
                    Text(VoiceBarHotkeyContract.holdDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Double-tap") {
                    Text(VoiceBarHotkeyContract.doubleTapDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(VoiceBarHotkeyContract.repasteShortcutLabel) {
                    Text(VoiceBarHotkeyContract.repasteDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Position") {
                Picker("Anchor", selection: Binding(
                    get: { anchorMode() },
                    set: { onSelectAnchorMode($0) }
                )) {
                    ForEach(VoiceBarAnchorMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle("Lock position", isOn: Binding(
                    get: { isPositionLocked() },
                    set: { onSetPositionLocked($0) }
                ))

                if let footnote = VoiceBarPositionLockPolicy.lockFootnote(
                    anchorMode: anchorMode(),
                    isLocked: isPositionLocked()
                ) {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Input Device") {
                let devices = availableDevices()
                let selected = selectedDeviceID()

                if devices.isEmpty {
                    Text("No input devices found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Microphone", selection: Binding(
                        get: { selected ?? "" },
                        set: { onSelectDevice($0) }
                    )) {
                        ForEach(devices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        Form {
            Section("Corrections") {
                TextField("Search", text: $dictionarySearch)

                let aliases = vocabularyPreview().filteredAliases(matching: dictionarySearch)
                if aliases.isEmpty {
                    Text("No corrections")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(aliases, id: \.self) { alias in
                        correctionRow(alias)
                    }
                }
            }

            Section(selectedAlias == nil ? "Add Correction" : "Edit Correction") {
                LabeledContent("Correct") {
                    TextField("Intended text", text: $correctText)
                }
                LabeledContent("Transcribed") {
                    HStack(spacing: 8) {
                        TextField("Misheard text", text: $wrongText)
                        Button("⇄") {
                            swap(&correctText, &wrongText)
                        }
                        .help("Swap correct and transcribed text")
                    }
                }
                HStack {
                    if let selectedAlias {
                        Button("Delete") {
                            onRemoveVocabularyAlias(selectedAlias)
                            clearCorrectionEditor()
                        }
                    }
                    Spacer()
                    Button(selectedAlias == nil ? "Add" : "Save") {
                        saveCorrection()
                    }
                    .disabled(!currentDraft.canSaveAlias)
                }
            }

            Section("Prompt Terms") {
                let terms = vocabularyPreview().filteredPromptTerms(matching: dictionarySearch)
                if terms.isEmpty {
                    Text("No prompt terms")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(terms, id: \.self) { term in
                        Button(term) {
                            beginAddingVariant(for: term)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var hotkeyStatusText: String {
        if hotkeyEnabled { return "Active" }
        let names = missingPermissions.map {
            switch $0 {
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            }
        }
        return "Missing: \(names.joined(separator: ", "))"
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var currentDraft: STTVocabularyDraft {
        STTVocabularyDraft(
            correct: correctText,
            wrong: wrongText
        )
    }

    private func correctionRow(_ alias: STTVocabularyAliasPreview) -> some View {
        HStack(spacing: 8) {
            Text(alias.from)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Button(alias.to) {
                beginAddingVariant(for: alias.to)
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Edit") {
                beginEditing(alias)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            beginEditing(alias)
        }
    }

    private func beginEditing(_ alias: STTVocabularyAliasPreview) {
        selectedAlias = alias
        correctText = alias.to
        wrongText = alias.from
    }

    private func beginAddingVariant(for correct: String) {
        selectedAlias = nil
        correctText = correct
        wrongText = ""
    }

    private func clearCorrectionEditor() {
        selectedAlias = nil
        correctText = ""
        wrongText = ""
    }

    private func saveCorrection() {
        let draft = currentDraft
        guard draft.canSaveAlias else { return }
        if let selectedAlias {
            onRemoveVocabularyAlias(selectedAlias)
        }
        onAddVocabularyAlias(
            draft.trimmedCorrect,
            draft.trimmedWrong
        )
        clearCorrectionEditor()
    }
}
