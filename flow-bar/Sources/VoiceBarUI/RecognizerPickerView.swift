import SwiftUI

public struct RecognizerPickerView: View {
    public let state: RecognizerPickerState
    public let onSelect: ((RecognizerPickerEngine) -> Void)?
    public let onManage: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)?
    let suppressDisabledExplanation: Bool
    @FocusState private var focusedEngine: RecognizerPickerEngine?
    /// S3: delete asks inline under the rows, never in an alert; a blocked delete says why in the same place.
    @State private var deleting: RecognizerPickerEngine?
    @State private var pendingDelete: RecognizerPickerEngine?
    @State private var blockedDelete: BlockedDelete?

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
                    if engine != RecognizerPickerEngine.allCases.last { Divider().accessibilityHidden(true) }
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
                    .foregroundStyle(state.explanationIsWarning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recognizer-picker-explanation")
            }
            if let engine = state.retryEngine {
                Button(engine == .whisper ? "Retry Whisper" : "Retry Parakeet") { state.select(engine, send: onSelect) }
                    .disabled(state.isSelectionDisabled || onSelect == nil).accessibilityIdentifier("recognizer-picker-retry")
            }
            if let engine = deleting { deleteConfirmation(engine) }
            if let blocked = blockedDelete {
                HStack(alignment: .firstTextBaseline) {
                    Text(blocked.reason).font(.caption).foregroundStyle(SettingsPanePalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("OK") { blockedDelete = nil }.controlSize(.small)
                }
                .accessibilityIdentifier("recognizer-delete-blocked")
            }
        }
        .onChange(of: state) { _, current in
            guard let engine = pendingDelete else { return }
            if current.canManage(engine, action: .delete) {
                pendingDelete = nil; onManage?(engine, .delete)
            } else if current.commandNotice != nil || !current.hasFilesOnDisk(engine) {
                pendingDelete = nil
            }
        }
    }

    private func deleteConfirmation(_ engine: RecognizerPickerEngine) -> some View {
        let bytes = state.diskBytes[engine] ?? 0
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.deleteMessage(state, engine)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Cancel") { deleting = nil }
            Button(bytes > 0 ? "Delete \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" : "Delete",
                   role: .destructive) {
                deleting = nil
                // A resident model is unloaded first; the delete follows once the daemon reports it asleep.
                if state.residencyAction(for: engine) == .unload {
                    pendingDelete = engine; onManage?(engine, .unload)
                } else {
                    onManage?(engine, .delete)
                }
            }
            .tint(.red)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
        .accessibilityIdentifier("recognizer-delete-confirm")
    }

    /// QA-05 / S6: one clear selected state, a leading radio mark; the faint trailing check is gone.
    static func selectionSymbol(isSelected: Bool) -> String {
        isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func row(_ engine: RecognizerPickerEngine) -> some View {
        HStack(spacing: 10) {
            Button { state.select(engine, send: onSelect) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.selectionSymbol(isSelected: state.selected == engine))
                    .font(.system(size: 14))
                    .foregroundStyle(state.selected == engine ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Self.rowTitle(engine)).font(SettingsRowLabel.titleFont)
                        if engine == .parakeet {
                            SettingsPill(text: "Recommended", tint: .green)
                                .accessibilityIdentifier("recognizer-recommended")
                        }
                    }
                    Text(Self.blurb(engine) + " " + Self.subtitle(state, engine))
                        .font(SettingsRowLabel.descriptionFont).foregroundStyle(SettingsPanePalette.helper)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let line = state.autoLoadLine(for: engine) {
                        Text(line).font(SettingsRowLabel.descriptionFont).foregroundStyle(SettingsPanePalette.helper)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("recognizer-autoload-\(engine.rawValue)")
                    }
                }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(state.isSelectionDisabled || !state.assetsPresent(for: engine) || onSelect == nil)
            .focused($focusedEngine, equals: engine)
            .accessibilityAddTraits(state.selected == engine ? [.isSelected] : [])
            .accessibilityLabel(engine.title).accessibilityValue(state.statusText(for: engine))
            .accessibilityIdentifier("recognizer-picker-\(engine.rawValue)")
            management(engine)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func management(_ engine: RecognizerPickerEngine) -> some View {
        if let progress = state.downloads[engine], progress.isActive {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: Double(min(progress.received, progress.total)), total: Double(max(1, progress.total)))
                    .frame(width: 68).controlSize(.small)
            }
            Button { onManage?(engine, .cancelDownload) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).disabled(onManage == nil)
                .accessibilityLabel("Cancel \(engine.title) download")
                .accessibilityIdentifier("recognizer-cancel-\(engine.rawValue)")
        } else {
            if state.assetsPresent(for: engine) {
                let residency = state.residencyAction(for: engine)
                Button(residency == .unload ? "Unload" : "Load") { onManage?(engine, residency) }
                    .buttonStyle(.borderless).font(.callout)
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
                            blockedDelete = nil; deleting = engine
                        }
                    } else {
                        onManage?(engine, .download)
                    }
                } label: {
                    Image(systemName: action == .delete ? "trash" : "arrow.down.circle").font(.system(size: 14))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
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
