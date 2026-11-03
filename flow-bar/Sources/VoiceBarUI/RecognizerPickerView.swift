import SwiftUI

public struct RecognizerPickerView: View {
    public let state: RecognizerPickerState
    public let onSelect: ((RecognizerPickerEngine) -> Void)?
    public let onManage: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)?
    let suppressDisabledExplanation: Bool
    @FocusState private var focusedEngine: RecognizerPickerEngine?
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
    /// The secondary line under a recognizer's name: its state, and its size once it's on disk.
    static func subtitle(_ state: RecognizerPickerState, _ engine: RecognizerPickerEngine) -> String {
        // Row 3: a Sleeping SELECTED engine loads on the next dictation; say so beside "Sleeping".
        let status = state.residency(for: engine) == .unloaded && state.assetsPresent(for: engine)
            ? (state.showsSleepingHint(for: engine) ? "Sleeping (\(RecognizerPickerState.sleepingHint))" : "Sleeping")
            : state.statusText(for: engine)
        guard state.assetsPresent(for: engine), let bytes = state.diskBytes[engine], bytes > 0 else { return status }
        return "\(status) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    static func deleteMessage(_ state: RecognizerPickerState, _ engine: RecognizerPickerEngine) -> String {
        let bytes = state.diskBytes[engine] ?? 0
        let what = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            : "its incomplete model files"
        let unload = state.residencyAction(for: engine) == .unload ? "Unload it and remove" : "Remove"
        return "\(unload) \(what) from disk? You can download it again later."
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
                    .foregroundStyle(state.fallbackReason != nil || state.parakeet == .error ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("recognizer-picker-explanation")
            }
            if let engine = state.retryEngine {
                Button(engine == .whisper ? "Retry Whisper" : "Retry Parakeet") { state.select(engine, send: onSelect) }
                    .disabled(state.isSelectionDisabled || onSelect == nil).accessibilityIdentifier("recognizer-picker-retry")
            }
        }
        .alert("Delete \(deleting?.title ?? "recognizer")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { engine in
            Button("Delete", role: .destructive) {
                // A resident model is unloaded first; the delete follows once the daemon reports it asleep.
                if state.residencyAction(for: engine) == .unload {
                    pendingDelete = engine; onManage?(engine, .unload)
                } else {
                    onManage?(engine, .delete)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { engine in
            Text(Self.deleteMessage(state, engine))
        }
        .alert("Can't delete \(blockedDelete?.engine.shortName ?? "recognizer") yet",
               isPresented: Binding(get: { blockedDelete != nil }, set: { if !$0 { blockedDelete = nil } }),
               presenting: blockedDelete) { _ in
            Button("OK", role: .cancel) {}
        } message: { blocked in
            Text(blocked.reason)
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
                        Text(engine.title)
                        if engine == .parakeet {
                            Text("Recommended")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .accessibilityIdentifier("recognizer-recommended")
                        }
                    }
                    Text(Self.subtitle(state, engine))
                        .font(.caption).foregroundStyle(.secondary)
                    if let line = state.autoLoadLine(for: engine) {
                        Text(line).font(.caption).foregroundStyle(.tertiary)
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
                Text(progress.state == "runtime" ? "Setting up runtime…" : progress.state == "verifying" ? "Verifying…" : "Downloading…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
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
                            blockedDelete = BlockedDelete(engine: engine, reason: reason)
                        } else {
                            deleting = engine
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
