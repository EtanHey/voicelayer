import SwiftUI

public struct DictionaryAddSheetView: View {
    @State private var correct: String
    @State private var wrong: String
    @State private var alsoPromptTerm: Bool

    private let onSave: (STTVocabularyDraft) -> Void
    private let onCancel: () -> Void

    public init(
        draft: STTVocabularyDraft,
        onSave: @escaping (STTVocabularyDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _correct = State(initialValue: draft.correct)
        _wrong = State(initialValue: draft.wrong)
        _alsoPromptTerm = State(initialValue: draft.alsoPromptTerm)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Dictionary")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Correct") {
                    TextField("Intended text", text: $correct)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Transcribed") {
                    HStack(spacing: 8) {
                        TextField("Misheard text", text: $wrong)
                            .textFieldStyle(.roundedBorder)
                        Button("⇄") {
                            swap(&correct, &wrong)
                        }
                        .help("Swap correct and transcribed text")
                    }
                }
                Toggle("Also add as prompt term", isOn: $alsoPromptTerm)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                Button("Add") {
                    onSave(currentDraft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!currentDraft.canSaveAlias)
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var currentDraft: STTVocabularyDraft {
        STTVocabularyDraft(
            correct: correct,
            wrong: wrong,
            alsoPromptTerm: alsoPromptTerm
        )
    }
}
