import SwiftUI

public enum SettingsTab: Hashable {
    case general
    case audio
    case dictionary
}

private enum DictEditorField: Hashable {
    case search
    case correct
    case wrong
    case newTerm
}

public struct SettingsView: View {
    public let hotkeyEnabled: Bool
    public let missingPermissions: [HotkeyPermission]
    public let availableDevices: () -> [MicrophoneDevice]
    public let selectedDeviceID: () -> String?
    public let onSelectDevice: (String) -> Void
    public let anchorMode: () -> VoiceBarAnchorMode
    public let onSelectAnchorMode: (VoiceBarAnchorMode) -> Void
    public let performanceEffort: () -> VoiceBarPerformanceEffort
    public let performanceEffortNotice: () -> String?
    public let onSelectPerformanceEffort: (VoiceBarPerformanceEffort) -> Void
    public let vocabularyPreview: () -> STTVocabularyPreview
    public let onAddVocabularyAlias: (String, String) -> Void
    public let onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    public let onAddPromptTerm: (String) -> Void
    public let onRemovePromptTerm: (String) -> Void
    public let isHotkeyRemapActive: () -> Bool
    public let isMicrophonePermissionGranted: () -> Bool
    public let onRunRelaySetup: (@escaping (String) -> Void) -> Void

    @State private var selectedTab: SettingsTab
    @State private var selectedAnchorMode: VoiceBarAnchorMode
    @State private var selectedAnchoredMode: VoiceBarAnchorMode
    @State private var selectedPerformanceEffort: VoiceBarPerformanceEffort
    @State private var correctionsExpanded = true
    @State private var dictionarySearch = ""
    @State private var selectedAlias: STTVocabularyAliasPreview?
    @State private var localAliases: [STTVocabularyAliasPreview]
    @State private var localTerms: [String]
    @State private var correctText = ""
    @State private var wrongText = ""
    @State private var newTermText = ""
    @State private var relaySetupFeedback: String?
    @State private var relaySetupRunning = false
    @FocusState private var focusedEditorField: DictEditorField?

    public init(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        availableDevices: @escaping () -> [MicrophoneDevice],
        selectedDeviceID: @escaping () -> String?,
        onSelectDevice: @escaping (String) -> Void,
        anchorMode: @escaping () -> VoiceBarAnchorMode = { .follow },
        onSelectAnchorMode: @escaping (VoiceBarAnchorMode) -> Void = { _ in },
        performanceEffort: @escaping () -> VoiceBarPerformanceEffort = { .accurate },
        performanceEffortNotice: @escaping () -> String? = { nil },
        onSelectPerformanceEffort: @escaping (VoiceBarPerformanceEffort) -> Void = { _ in },
        vocabularyPreview: @escaping () -> STTVocabularyPreview = {
            STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        },
        onAddVocabularyAlias: @escaping (String, String) -> Void = { _, _ in },
        onRemoveVocabularyAlias: @escaping (STTVocabularyAliasPreview) -> Void = { _ in },
        onAddPromptTerm: @escaping (String) -> Void = { _ in },
        onRemovePromptTerm: @escaping (String) -> Void = { _ in },
        isHotkeyRemapActive: @escaping () -> Bool = { false },
        isMicrophonePermissionGranted: @escaping () -> Bool = { true },
        onRunRelaySetup: @escaping (@escaping (String) -> Void) -> Void = { completion in
            completion("Relay setup requested.")
        },
        initialTab: SettingsTab = .general
    ) {
        self.hotkeyEnabled = hotkeyEnabled
        self.missingPermissions = missingPermissions
        self.availableDevices = availableDevices
        self.selectedDeviceID = selectedDeviceID
        self.onSelectDevice = onSelectDevice
        self.anchorMode = anchorMode
        self.onSelectAnchorMode = onSelectAnchorMode
        self.performanceEffort = performanceEffort
        self.performanceEffortNotice = performanceEffortNotice
        self.onSelectPerformanceEffort = onSelectPerformanceEffort
        self.vocabularyPreview = vocabularyPreview
        self.onAddVocabularyAlias = onAddVocabularyAlias
        self.onRemoveVocabularyAlias = onRemoveVocabularyAlias
        self.onAddPromptTerm = onAddPromptTerm
        self.onRemovePromptTerm = onRemovePromptTerm
        self.isHotkeyRemapActive = isHotkeyRemapActive
        self.isMicrophonePermissionGranted = isMicrophonePermissionGranted
        self.onRunRelaySetup = onRunRelaySetup
        let initialAnchorMode = anchorMode()
        let initialPerformanceEffort = performanceEffort()
        let initialVocabulary = vocabularyPreview()
        _selectedTab = State(initialValue: initialTab)
        _selectedAnchorMode = State(initialValue: initialAnchorMode)
        _selectedPerformanceEffort = State(initialValue: initialPerformanceEffort)
        _localAliases = State(initialValue: initialVocabulary.aliases)
        _localTerms = State(initialValue: initialVocabulary.promptTerms)
        _selectedAnchoredMode = State(
            initialValue: VoiceBarAnchorMode.anchoredPositionModes.contains(initialAnchorMode)
                ? initialAnchorMode
                : .topCenter
        )
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
            Section("Permissions & Hotkey Setup") {
                LabeledContent("Shortcut") {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.secondary)
                        Text(VoiceBarHotkeyContract.shortcutChainLabel(remapDetected: isHotkeyRemapActive()))
                            .foregroundStyle(.secondary)
                    }
                }
                if isHotkeyRemapActive() {
                    Text(VoiceBarHotkeyContract.remapExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hotkeyEnabled ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(hotkeyStatusText)
                    }
                }

                permissionRow(.microphone, isGranted: isMicrophonePermissionGranted())
                permissionRow(.accessibility, isGranted: !missingPermissions.contains(.accessibility))
                permissionRow(.inputMonitoring, isGranted: !missingPermissions.contains(.inputMonitoring))

                LabeledContent("Relay (hidutil LaunchAgent)") {
                    HStack(spacing: 8) {
                        statusBadge(isHotkeyRemapActive() ? "Ready" : "Needs setup", isReady: isHotkeyRemapActive())
                        Button("Set up") {
                            runRelaySetup()
                        }
                        .disabled(relaySetupRunning)
                    }
                }

                if let relaySetupFeedback {
                    Text(relaySetupFeedback)
                        .font(.caption)
                        .foregroundStyle(isHotkeyRemapActive() ? Color.secondary : Color.red)
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
                Toggle("Anchor", isOn: Binding(
                    get: { selectedAnchorMode != .follow },
                    set: { enabled in
                        if enabled {
                            selectAnchorMode(selectedAnchoredMode)
                        } else {
                            selectAnchorMode(.follow)
                        }
                    }
                ))

                if selectedAnchorMode != .follow {
                    Picker("Position", selection: Binding(
                        get: { selectedAnchoredMode },
                        set: { mode in
                            selectAnchorMode(mode)
                        }
                    )) {
                        ForEach(VoiceBarAnchorMode.anchoredPositionModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text(positionModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Performance") {
                Picker("Effort", selection: Binding(
                    get: { selectedPerformanceEffort },
                    set: { effort in
                        selectedPerformanceEffort = effort
                        onSelectPerformanceEffort(effort)
                    }
                )) {
                    ForEach(VoiceBarPerformanceEffort.allCases) { effort in
                        Text(performanceEffortLabel(effort)).tag(effort)
                    }
                }
                .pickerStyle(.segmented)
                if let notice = performanceEffortNotice() {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        Form {
            Section("Dictionary") {
                correctionEditor

                DisclosureGroup(isExpanded: $correctionsExpanded) {
                    correctionsList
                } label: {
                    Text("Corrections")
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search corrections and terms", text: $dictionarySearch)
                        .dictionaryTextField()
                        .focused($focusedEditorField, equals: .search)
                }
                .dictionaryFieldContainer()
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedEditorField = .search
                }

                promptTermsList
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var correctionsList: some View {
        let aliases = localVocabularyPreview.filteredAliases(matching: dictionarySearch)
        if aliases.isEmpty {
            Text("No corrections yet — add one above.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(aliases, id: \.self) { alias in
                correctionRow(alias)
            }
        }
    }

    private var promptTermAddRow: some View {
        HStack(spacing: 8) {
            HStack {
                TextField("Add a term, e.g. VoiceLayer", text: $newTermText)
                    .dictionaryTextField()
                    .focused($focusedEditorField, equals: .newTerm)
                    .onSubmit(commitNewPromptTerm)
            }
            .dictionaryFieldContainer()
            .contentShape(Rectangle())
            .onTapGesture {
                focusedEditorField = .newTerm
            }
            Button(action: commitNewPromptTerm) {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(newTermText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add term")
            .accessibilityLabel("Add prompt term")
        }
    }

    private func promptTermRow(_ term: String) -> some View {
        HStack {
            Text(term)
            Spacer()
            deletePromptTermButton(term)
        }
    }

    private func deletePromptTermButton(_ term: String) -> some View {
        Button {
            SettingsDictionaryMutations.deletePromptTerm(
                term,
                localTerms: &localTerms,
                onRemovePromptTerm: onRemovePromptTerm
            )
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .help("Delete term")
        .accessibilityLabel("Delete term \(term)")
    }

    private func commitNewPromptTerm() {
        SettingsDictionaryMutations.commitNewPromptTerm(
            newTermText: &newTermText,
            localTerms: &localTerms,
            onAddPromptTerm: onAddPromptTerm
        )
    }

    // MARK: - Helpers

    private var hotkeyStatusText: String {
        if hotkeyEnabled { return "Active" }
        let names = missingPermissions.map {
            switch $0 {
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            case .microphone: "Microphone"
            }
        }
        return "Missing: \(names.joined(separator: ", "))"
    }

    private var positionModeDescription: String {
        switch selectedAnchorMode {
        case .follow:
            "Follows the active screen while you drag freely."
        case .topCenter:
            "Anchored to the top center of the active screen."
        case .bottomCenter:
            "Anchored to the bottom center of the active screen."
        }
    }

    private func permissionRow(_ permission: HotkeyPermission, isGranted: Bool) -> some View {
        LabeledContent(permission.label) {
            HStack(spacing: 8) {
                statusBadge(isGranted ? "Granted" : "Missing", isReady: isGranted)
                Button("Open") {
                    openPermissionSettings(permission)
                }
            }
        }
    }

    private func statusBadge(_ text: String, isReady: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isReady ? .green : .red)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func openPermissionSettings(_ permission: HotkeyPermission) {
        if let url = URL(string: permission.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func runRelaySetup() {
        guard !relaySetupRunning else { return }
        relaySetupRunning = true
        relaySetupFeedback = "Setting up relay..."
        onRunRelaySetup { feedback in
            relaySetupFeedback = feedback
            relaySetupRunning = false
        }
    }

    private func performanceEffortLabel(_ effort: VoiceBarPerformanceEffort) -> String {
        switch effort {
        case .fast:
            "Fast"
        case .balanced:
            "Balanced"
        case .accurate:
            "Accurate"
        }
    }

    private var currentDraft: STTVocabularyDraft {
        STTVocabularyDraft(
            correct: correctText,
            wrong: wrongText
        )
    }

    private var localVocabularyPreview: STTVocabularyPreview {
        STTVocabularyPreview(updatedAt: nil, promptTerms: localTerms, aliases: localAliases)
    }

    /// Leading label column width shared by the two editor rows.
    private static let editorLabelWidth: CGFloat = 92

    private var correctionEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Explicit leading labels instead of LabeledContent: the grouped
            // Form right-aligns LabeledContent values, which reads wrong once
            // the fields have visible borders.
            HStack(spacing: 8) {
                Text("Correct")
                    .frame(width: Self.editorLabelWidth, alignment: .leading)
                    .onTapGesture {
                        focusedEditorField = .correct
                    }
                TextField("Intended text", text: $correctText)
                    .dictionaryTextField()
                    .focused($focusedEditorField, equals: .correct)
                    .onSubmit {
                        focusedEditorField = .wrong
                    }
            }
            .dictionaryFieldContainer()
            .contentShape(Rectangle())
            .onTapGesture {
                focusedEditorField = .correct
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("Transcribed")
                        .frame(width: Self.editorLabelWidth, alignment: .leading)
                        .onTapGesture {
                            focusedEditorField = .wrong
                        }
                    TextField("Misheard text", text: $wrongText)
                        .dictionaryTextField()
                        .focused($focusedEditorField, equals: .wrong)
                        .onSubmit(saveCorrection)
                }
                .dictionaryFieldContainer()
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedEditorField = .wrong
                }
                Button("⇄") {
                    swap(&correctText, &wrongText)
                }
                .help("Swap correct and transcribed text")
            }
            HStack {
                if let alias = selectedAlias {
                    Button("Delete") {
                        SettingsDictionaryMutations.deleteCorrection(
                            alias,
                            correctText: &correctText,
                            wrongText: &wrongText,
                            selectedAlias: &selectedAlias,
                            localAliases: &localAliases,
                            onRemoveVocabularyAlias: onRemoveVocabularyAlias
                        )
                        focusedEditorField = nil
                    }
                }
                Spacer()
                Button(selectedAlias == nil ? "Add" : "Save") {
                    saveCorrection()
                }
                .disabled(!currentDraft.canSaveAlias)
            }
        }
    }

    private var promptTermsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt Terms")
                .font(.headline)

            promptTermAddRow

            let terms = localVocabularyPreview.filteredPromptTerms(matching: dictionarySearch)
            if terms.isEmpty {
                Text("No prompt terms yet — terms bias transcription toward your vocabulary.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(terms, id: \.self) { term in
                    promptTermRow(term)
                }
            }
        }
    }

    private func correctionRow(_ alias: STTVocabularyAliasPreview) -> some View {
        HStack(spacing: 8) {
            Text(alias.from)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(alias.to)
            Spacer()
            Button {
                beginEditing(alias)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit correction")
            .accessibilityLabel("Edit correction \(alias.from)")
            deleteCorrectionButton(alias)
        }
        .contentShape(Rectangle())
        .background(selectedAlias == alias ? Color.accentColor.opacity(0.12) : .clear)
        .cornerRadius(4)
        .onTapGesture {
            beginEditing(alias)
        }
    }

    private func deleteCorrectionButton(_ alias: STTVocabularyAliasPreview) -> some View {
        Button {
            SettingsDictionaryMutations.deleteCorrection(
                alias,
                correctText: &correctText,
                wrongText: &wrongText,
                selectedAlias: &selectedAlias,
                localAliases: &localAliases,
                onRemoveVocabularyAlias: onRemoveVocabularyAlias
            )
            if selectedAlias == nil {
                focusedEditorField = nil
            }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .help("Delete correction")
        .accessibilityLabel("Delete correction \(alias.from)")
    }

    private func beginEditing(_ alias: STTVocabularyAliasPreview) {
        correctionsExpanded = true
        selectedAlias = alias
        correctText = alias.to
        wrongText = alias.from
        focusedEditorField = .correct
    }

    private func clearCorrectionEditor() {
        selectedAlias = nil
        correctText = ""
        wrongText = ""
        focusedEditorField = nil
    }

    private func selectAnchorMode(_ mode: VoiceBarAnchorMode) {
        selectedAnchorMode = mode
        if mode != .follow {
            selectedAnchoredMode = mode
        }
        onSelectAnchorMode(mode)
    }

    private func saveCorrection() {
        SettingsDictionaryMutations.saveCorrection(
            correctText: &correctText,
            wrongText: &wrongText,
            selectedAlias: &selectedAlias,
            localAliases: &localAliases,
            onRemoveVocabularyAlias: onRemoveVocabularyAlias,
            onAddVocabularyAlias: onAddVocabularyAlias
        )
        focusedEditorField = nil
    }
}

enum SettingsDictionaryMutations {
    static func commitNewPromptTerm(
        newTermText: inout String,
        localTerms: inout [String],
        onAddPromptTerm: (String) -> Void
    ) {
        let trimmed = newTermText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        localTerms.append(trimmed)
        onAddPromptTerm(trimmed)
        newTermText = ""
    }

    static func deletePromptTerm(
        _ term: String,
        localTerms: inout [String],
        onRemovePromptTerm: (String) -> Void
    ) {
        localTerms.removeAll { $0 == term }
        onRemovePromptTerm(term)
    }

    static func saveCorrection(
        correctText: inout String,
        wrongText: inout String,
        selectedAlias: inout STTVocabularyAliasPreview?,
        localAliases: inout [STTVocabularyAliasPreview],
        onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void,
        onAddVocabularyAlias: (String, String) -> Void
    ) {
        let draft = STTVocabularyDraft(correct: correctText, wrong: wrongText)
        guard draft.canSaveAlias else { return }

        let nextAlias = STTVocabularyAliasPreview(
            from: draft.trimmedWrong,
            to: draft.trimmedCorrect
        )
        if let editingAlias = selectedAlias {
            if let index = localAliases.firstIndex(of: editingAlias) {
                localAliases[index] = nextAlias
            } else {
                localAliases.removeAll { $0.from == editingAlias.from }
                localAliases.append(nextAlias)
            }
            onRemoveVocabularyAlias(editingAlias)
        } else {
            localAliases.append(nextAlias)
        }
        onAddVocabularyAlias(draft.trimmedCorrect, draft.trimmedWrong)

        selectedAlias = nil
        correctText = ""
        wrongText = ""
    }

    static func deleteCorrection(
        _ alias: STTVocabularyAliasPreview,
        correctText: inout String,
        wrongText: inout String,
        selectedAlias: inout STTVocabularyAliasPreview?,
        localAliases: inout [STTVocabularyAliasPreview],
        onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    ) {
        localAliases.removeAll { $0 == alias }
        onRemoveVocabularyAlias(alias)
        if selectedAlias == alias {
            selectedAlias = nil
            correctText = ""
            wrongText = ""
        }
    }
}

private extension HotkeyPermission {
    var label: String {
        switch self {
        case .inputMonitoring:
            "Input Monitoring"
        case .accessibility:
            "Accessibility"
        case .microphone:
            "Microphone"
        }
    }

    var settingsURLString: String {
        switch self {
        case .inputMonitoring:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
    }
}
