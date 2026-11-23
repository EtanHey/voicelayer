import SwiftUI

public struct RecognizerPickerView: View {
    public let state: RecognizerPickerState
    public let onSelect: ((RecognizerPickerEngine) -> Void)?
    public let onManage: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)?
    let suppressDisabledExplanation: Bool
    @FocusState private var focusedEngine: RecognizerPickerEngine?
    /// S3: delete asks inline under the rows, never in an alert; a blocked delete says why in the same place.
    @State private var deleting: RecognizerDeleteConfirmation?
    @State private var pendingDelete: RecognizerPickerEngine?
    @State private var blockedDelete: BlockedDelete?
    /// 2.4.6 track T: every ink and fill on the notch glass comes from the shared notch palette.
    @Environment(\.colorScheme) private var colorScheme
    private var ink: NotchPaneInk { NotchPaneInk(colorScheme: colorScheme) }

    public init(state: RecognizerPickerState, onSelect: ((RecognizerPickerEngine) -> Void)? = nil,
                onManage: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)? = nil,
                suppressDisabledExplanation: Bool = false) {
        self.state = state; self.onSelect = onSelect; self.onManage = onManage
        self.suppressDisabledExplanation = suppressDisabledExplanation
    }
    var displayedExplanation: String? {
        if suppressDisabledExplanation, let disabled = state.disabledReason, state.explanation == disabled { return nil }
        return state.explanation ?? (onSelect == nil ? "Recognizer switching unavailable" : nil)
    }
    /// Spec 2.3 row names: Parakeet is short; Whisper keeps its model name.
    static func rowTitle(_ engine: RecognizerPickerEngine) -> String {
        engine == .parakeet ? "Parakeet" : engine.title
    }

    static func blurb(_ engine: RecognizerPickerEngine) -> String {
        engine == .parakeet ? "Fastest on this Mac. English." : "Slower. Handles Hebrew and mixed languages."
    }

    /// 2.4.6 track T (Etan, 23 Nov: "transcriptions ... is a little loaded with a lot of text"): the row says what it is
    /// in one short line, the language and the status; the full blurb and the auto-load line move to the row's tooltip.
    static func shortBlurb(_ engine: RecognizerPickerEngine) -> String {
        engine == .parakeet ? "English" : "Hebrew and mixed"
    }

    static func rowLine(_ state: RecognizerPickerState, _ engine: RecognizerPickerEngine) -> String {
        shortBlurb(engine) + " · " + subtitle(state, engine)
    }

    /// Everything the row used to paint, for its tooltip and VoiceOver hint.
    static func rowDetail(_ state: RecognizerPickerState, _ engine: RecognizerPickerEngine) -> String {
        ([blurb(engine), subtitle(state, engine) + "."] + [state.autoLoadLine(for: engine)].compactMap { $0 })
            .joined(separator: " ")
    }

    /// The row's status: Loaded / On disk / Not downloaded, with the model's size once known, or the live
    /// download percentage (S4: the other recognizer keeps dictating meanwhile).
    static func subtitle(_ state: RecognizerPickerState, _ engine: RecognizerPickerEngine) -> String {
        if let progress = state.downloads[engine], progress.isActive {
            if progress.state == "runtime" { return "Setting up runtime…" }
            if progress.state == "verifying" { return "Verifying…" }
            let percent = progress.total > 0 ? min(100, progress.received * 100 / progress.total) : 0
            return "Downloading \(percent) %"
        }
        let size = (state.diskBytes[engine] ?? 0) > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(state.diskBytes[engine] ?? 0), countStyle: .file) : nil
        let status: String
        if !state.assetsPresent(for: engine) {
            status = engine == .parakeet ? "Not set up" : "Not downloaded"
        } else {
            switch state.residency(for: engine) {
            case .loaded: status = engine == .parakeet && state.parakeetAvailable != true ? "Unknown" : "Loaded"
            case .unloaded:
                if engine == .parakeet, state.parakeetAvailable == false { status = "Unavailable" }
                else if state.showsSleepingHint(for: engine) { status = "On disk (\(RecognizerPickerState.sleepingHint))" }
                else { status = "On disk" }
            case .loading, .error, .unknown: status = state.residency(for: engine).title
            }
        }
        return [status, size].compactMap { $0 }.joined(separator: " · ")
    }

    static func deleteMessage(_ state: RecognizerPickerState, _ engine: RecognizerPickerEngine) -> String {
        let bytes = state.diskBytes[engine] ?? 0
        let what = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : "its incomplete model files"
        guard bytes > 0 else { return "Delete \(engine.title)'s incomplete model files from this Mac?" }
        return "Delete \(engine.title) from this Mac? This frees \(what). You can download it again later."
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(RecognizerPickerEngine.allCases) { engine in
                    row(engine)
                    if engine != RecognizerPickerEngine.allCases.last { DictionaryHairline().accessibilityHidden(true) }
                }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Recognizer")
            .onMoveCommand { direction in
                guard !state.isSelectionDisabled, onSelect != nil else { return }
                let engines = RecognizerPickerEngine.allCases
                let step: Int
                switch direction { case .up, .left: step = -1; case .down, .right: step = 1; default: return }
                guard let index = engines.firstIndex(of: focusedEngine ?? state.selected ?? .parakeet), engines.indices.contains(index + step) else { return }
                let next = engines[index + step]; focusedEngine = next; state.select(next, send: onSelect)
            }
            .accessibilityIdentifier("recognizer-picker")
            if let explanation = displayedExplanation {
                Text(explanation).font(.caption)
                    .foregroundStyle(state.explanationIsWarning ? ink.error : ink.note)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recognizer-picker-explanation")
            }
            if let engine = state.retryEngine {
                Button(engine == .whisper ? "Retry Whisper" : "Retry Parakeet") { state.select(engine, send: onSelect) }
                    .disabled(state.isSelectionDisabled || onSelect == nil).accessibilityIdentifier("recognizer-picker-retry")
            }
            if let confirmation = deleting { deleteConfirmation(confirmation) }
            if let blocked = blockedDelete {
                HStack(alignment: .firstTextBaseline) {
                    Text(blocked.reason).font(.caption).foregroundStyle(ink.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("OK") { blockedDelete = nil }.controlSize(.small)
                }
                .accessibilityIdentifier("recognizer-delete-blocked")
            }
        }
        .onChange(of: state) { _, current in
            // Review R1 #737: a selection or residency change while the confirmation is open withdraws it.
            if let confirmation = deleting, confirmation.isStale(in: current) { deleting = nil }
            guard let engine = pendingDelete else { return }
            if current.canManage(engine, action: .delete) {
                pendingDelete = nil; onManage?(engine, .delete)
            } else if current.commandNotice != nil || !current.hasFilesOnDisk(engine) {
                pendingDelete = nil
            }
        }
    }

    private func deleteConfirmation(_ confirmation: RecognizerDeleteConfirmation) -> some View {
        let engine = confirmation.engine
        let bytes = state.diskBytes[engine] ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.deleteMessage(state, engine)).font(.callout).foregroundStyle(ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { deleting = nil }
            Button(bytes > 0 ? "Delete \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" : "Delete",
                   role: .destructive) {
                deleting = nil
                // Eligibility is checked again now, against the current state, before anything is sent.
                switch confirmation.outcome(in: state) {
                case let .blocked(reason):
                    blockedDelete = BlockedDelete(engine: engine, reason: reason)
                case .send(.unload):
                    // A resident model is unloaded first; the delete follows once the daemon reports it asleep.
                    pendingDelete = engine; onManage?(engine, .unload)
                case let .send(action):
                    onManage?(engine, action)
                }
            }
            .tint(ink.error)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(ink.error.opacity(0.10)))
        .accessibilityIdentifier("recognizer-delete-confirm")
    }

    /// QA-05 / S6: one clear selected state, a leading radio mark; the faint trailing check is gone.
    static func selectionSymbol(isSelected: Bool) -> String {
        isSelected ? "largecircle.fill.circle" : "circle"
    }

    /// Review R1 #737: the shared row anatomy (V12). Name, blurb + status and the auto-load line clip at two lines
    /// with a tooltip; the download bar sits under the text; the controls wrap under it when the window is narrow.
    private func row(_ engine: RecognizerPickerEngine) -> some View {
        SettingsRowLayout {
            Button { state.select(engine, send: onSelect) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.selectionSymbol(isSelected: state.selected == engine))
                        .font(.system(size: 14))
                        .foregroundStyle(state.selected == engine ? ink.primary : ink.note)
                        .opacity(onSelect != nil && !state.isSelectionDisabled ? 1 : 0.45)
                        .accessibilityHidden(true)
                    if onSelect == nil || state.isSelectionDisabled {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(ink.note)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            ClippingAwareText(text: Self.rowTitle(engine), font: SettingsRowLabel.titleFont,
                                              lineLimit: nil)
                                .foregroundStyle(ink.primary)
                            if engine == .parakeet {
                                SettingsPill(text: "Recommended", tint: ink.primary)
                                    .accessibilityIdentifier("recognizer-recommended")
                            }
                        }
                        // Short enough for one line in the drawer; it wraps rather than clips in a narrower window.
                        ClippingAwareText(text: Self.rowLine(state, engine),
                                          font: SettingsRowLabel.descriptionFont, lineLimit: nil)
                            .foregroundStyle(ink.note)
                            .accessibilityIdentifier("recognizer-line-\(engine.rawValue)")
                        if let progress = state.downloads[engine], progress.isActive {
                            ProgressView(value: Double(min(progress.received, progress.total)),
                                         total: Double(max(1, progress.total)))
                                .controlSize(.small).frame(maxWidth: 240)
                                .accessibilityIdentifier("recognizer-progress-\(engine.rawValue)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(state.isSelectionDisabled || !state.assetsPresent(for: engine) || onSelect == nil)
            .focused($focusedEngine, equals: engine)
            .accessibilityAddTraits(state.selected == engine ? [.isSelected] : [])
            .accessibilityLabel(engine.title).accessibilityValue(state.statusText(for: engine))
            .accessibilityHint(Self.rowDetail(state, engine))
            .help(Self.rowDetail(state, engine))
            .accessibilityIdentifier("recognizer-picker-\(engine.rawValue)")
            HStack(spacing: 8) { management(engine) }
                .fixedSize()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func management(_ engine: RecognizerPickerEngine) -> some View {
        if state.downloads[engine]?.isActive == true {
            Button { onManage?(engine, .cancelDownload) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundStyle(ink.note).disabled(onManage == nil)
                .accessibilityLabel("Cancel \(engine.title) download")
                .accessibilityIdentifier("recognizer-cancel-\(engine.rawValue)")
        } else {
            if state.assetsPresent(for: engine) {
                let residency = state.residencyAction(for: engine)
                Button(residency == .unload ? "Unload" : "Load") { onManage?(engine, residency) }
                    .buttonStyle(.borderless).font(.callout).foregroundStyle(ink.note)
                    .disabled(onManage == nil || !state.canManage(engine, action: residency))
                    .help(residency == .unload ? "Unload from memory"
                        : state.selected == engine ? "Load into memory now"
                        : "Use \(engine.shortName): loads it and unloads \(engine.other.shortName)")
                    .accessibilityIdentifier("recognizer-residency-\(engine.rawValue)")
            }
            ForEach(state.assetActions(for: engine), id: \.rawValue) { action in
                Button {
                    if action == .delete {
                        if let reason = state.deleteBlockReason(for: engine) {
                            deleting = nil; blockedDelete = BlockedDelete(engine: engine, reason: reason)
                        } else {
                            blockedDelete = nil; deleting = RecognizerDeleteConfirmation(engine: engine, state: state)
                        }
                    } else {
                        onManage?(engine, .download)
                    }
                } label: {
                    Image(systemName: action == .delete ? "trash" : "arrow.down.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundStyle(ink.note)
                .disabled(onManage == nil || (action == .download && !state.canManage(engine, action: .download)))
                .help(Self.assetHelp(engine, action))
                .accessibilityLabel(Self.assetLabel(engine, action))
                .accessibilityIdentifier("recognizer-\(action.rawValue)-\(engine.rawValue)")
            }
        }
    }

    /// CodeRabbit #672: Parakeet's download also installs its runtime, so the control is named "Set up".
    static func assetLabel(_ engine: RecognizerPickerEngine, _ action: RecognizerManagementAction) -> String {
        if action == .delete { return "Delete \(engine.title)" }
        return engine == .parakeet ? "Set up \(engine.title)" : "Download \(engine.title)"
    }

    static func assetHelp(_ engine: RecognizerPickerEngine, _ action: RecognizerManagementAction) -> String {
        if action == .delete { return "Delete model files" }
        return engine == .parakeet ? "Set up: download the model and its runtime" : "Download the model"
    }
}

struct BlockedDelete: Identifiable, Equatable {
    let engine: RecognizerPickerEngine
    let reason: String
    var id: RecognizerPickerEngine { engine }
}

/// An open inline delete confirmation, pinned to the selection and residency it was asked under (review R1 #737).
struct RecognizerDeleteConfirmation: Equatable {
    enum Outcome: Equatable {
        case send(RecognizerManagementAction)
        case blocked(String)
    }

    let engine: RecognizerPickerEngine
    let selected: RecognizerPickerEngine?
    let residency: RecognizerPickerResidency

    init(engine: RecognizerPickerEngine, state: RecognizerPickerState) {
        self.engine = engine
        selected = state.selected
        residency = state.residency(for: engine)
    }

    /// Choosing another recognizer, or this one loading or unloading, since it was asked.
    func isStale(in state: RecognizerPickerState) -> Bool {
        state.selected != selected || state.residency(for: engine) != residency
    }

    /// What Delete sends now: re-checked against the current state, never the state it was asked under.
    func outcome(in state: RecognizerPickerState) -> Outcome {
        if isStale(in: state) { return .blocked("\(engine.shortName) changed while you were deciding. Try deleting it again.") }
        if let reason = state.deleteBlockReason(for: engine) { return .blocked(reason) }
        return .send(state.residencyAction(for: engine) == .unload ? .unload : .delete)
    }
}
