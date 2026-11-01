import SwiftUI

public struct RecognizerPickerView: View {
    public let state: RecognizerPickerState
    public let onSelect: ((RecognizerPickerEngine) -> Void)?
    let suppressDisabledExplanation: Bool
    @FocusState private var focusedEngine: RecognizerPickerEngine?

    public init(state: RecognizerPickerState, onSelect: ((RecognizerPickerEngine) -> Void)? = nil,
                suppressDisabledExplanation: Bool = false) {
        self.state = state
        self.onSelect = onSelect
        self.suppressDisabledExplanation = suppressDisabledExplanation
    }

    // Hide only the disabled reason the containing page now explains. A command,
    // fallback or engine error must remain visible even during another busy operation.
    var displayedExplanation: String? {
        if suppressDisabledExplanation, let disabled = state.disabledReason,
           state.explanation == disabled { return nil }
        return state.explanation ?? (onSelect == nil ? "Recognizer switching unavailable" : nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(RecognizerPickerEngine.allCases) { engine in
                    Button { state.select(engine, send: onSelect) } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(engine.title)
                                    .font(.system(size: 13, weight: .regular))
                                if engine == .parakeet, !state.parakeetNotSetUp {
                                    Text("Recommended")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                            if engine == .parakeet {
                                if let reason = state.parakeetSetupReason {
                                    Text(reason)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("Fewer dropped and invented words")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer(minLength: 12)
                        Text(state.statusText(for: engine))
                            .font(.system(size: 13, weight: engine == .parakeet && state.parakeetNotSetUp ? .medium : .regular))
                            .foregroundStyle(.secondary)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(state.selected == engine ? 1 : 0)
                            .frame(width: 14)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(engine == .parakeet && state.parakeetNotSetUp)
                    .focused($focusedEngine, equals: engine)
                    .accessibilityAddTraits(state.selected == engine ? [.isSelected] : [])
                    .accessibilityLabel(engine.title + (engine == .parakeet && !state.parakeetNotSetUp ? ", Recommended. Fewer dropped and invented words" : ""))
                    .accessibilityValue(state.statusText(for: engine))
                    .accessibilityIdentifier("recognizer-picker-\(engine.rawValue)")
                    if engine != RecognizerPickerEngine.allCases.last {
                        Divider()
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recognizer")
            .onMoveCommand { direction in
                guard !state.isSelectionDisabled, onSelect != nil else { return }
                let engines = RecognizerPickerEngine.allCases
                let step: Int
                switch direction {
                case .up, .left: step = -1
                case .down, .right: step = 1
                default: return
                }
                guard let index = engines.firstIndex(of: focusedEngine ?? state.selected ?? .parakeet),
                      engines.indices.contains(index + step) else { return }
                let next = engines[index + step]
                focusedEngine = next
                state.select(next, send: onSelect)
            }
            .disabled(state.isSelectionDisabled || onSelect == nil)
            .accessibilityIdentifier("recognizer-picker")
            if let explanation = displayedExplanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(state.fallbackReason != nil || state.parakeet == .error ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recognizer-picker-explanation")
            }
            if let engine = state.retryEngine {
                Button(engine == .whisper ? "Retry Whisper" : "Retry Parakeet") {
                    state.select(engine, send: onSelect)
                }
                .disabled(state.isSelectionDisabled || onSelect == nil)
                .accessibilityHint("Retries loading the selected recognizer.")
                .accessibilityIdentifier("recognizer-picker-retry")
            }
        }
    }
}
