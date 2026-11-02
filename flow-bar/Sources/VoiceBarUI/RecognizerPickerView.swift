import SwiftUI

public struct RecognizerPickerView: View {
    public let state: RecognizerPickerState
    public let onSelect: ((RecognizerPickerEngine) -> Void)?
    public let onManage: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)?
    let suppressDisabledExplanation: Bool
    @FocusState private var focusedEngine: RecognizerPickerEngine?
    @State private var deleting: RecognizerPickerEngine?

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
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(RecognizerPickerEngine.allCases) { engine in
                    HStack(spacing: 10) {
                        Button { state.select(engine, send: onSelect) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(engine.title).font(.system(size: 13))
                                    HStack(spacing: 5) {
                                        Text(state.residency(for: engine) == .unloaded && state.assetsPresent(for: engine)
                                             ? "Sleeping" : state.statusText(for: engine))
                                        if engine == .parakeet, state.assetsPresent(for: engine) { Text("· Recommended") }
                                    }
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    if engine == .parakeet, let reason = state.parakeetSetupReason {
                                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor).opacity(state.selected == engine ? 1 : 0)
                                    .frame(width: 14).accessibilityHidden(true)
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
                    .padding(.vertical, 8)
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
            Button("Delete", role: .destructive) { onManage?(engine, .delete) }
            Button("Cancel", role: .cancel) {}
        } message: { engine in
            Text("Remove \(ByteCountFormatter.string(fromByteCount: Int64(state.diskBytes[engine] ?? 0), countStyle: .file)) from disk? You can download this model again later.")
        }
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
            let residency: RecognizerManagementAction = state.residency(for: engine) == .loaded || state.residency(for: engine) == .error ? .unload : .load
            Button(residency == .unload ? "Unload" : "Load") { onManage?(engine, residency) }
                .controlSize(.small).disabled(onManage == nil || !state.canManage(engine, action: residency))
                .help(residency == .load && state.selected != engine ? "Select this recognizer first" : "\(residency == .load ? "Load into" : "Unload from") memory")
                .accessibilityIdentifier("recognizer-residency-\(engine.rawValue)")
            ForEach(state.assetActions(for: engine), id: \.rawValue) { action in
            let isLastInstalled = !state.assetsPresent(for: engine == .parakeet ? .whisper : .parakeet)
            Button {
                if action == .delete { deleting = engine } else { onManage?(engine, .download) }
            } label: { Image(systemName: action == .delete ? "trash" : "arrow.down.circle").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(onManage == nil || !state.canManage(engine, action: action))
                .help(action == .delete && isLastInstalled
                    ? "Download another recognizer before deleting this one"
                    : action == .delete ? "Delete model files (unload first)" : "Download model and required runtime")
                .accessibilityLabel("\(action == .delete ? "Delete" : "Download") \(engine.title)")
                .accessibilityIdentifier("recognizer-\(action.rawValue)-\(engine.rawValue)")
            }
        }
    }
}
