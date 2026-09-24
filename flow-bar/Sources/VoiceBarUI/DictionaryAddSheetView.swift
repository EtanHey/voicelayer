import SwiftUI

public struct DictionaryAddSheetView: View {
    @State private var correct: String
    @State private var wrong: String

    private let onSave: (STTVocabularyDraft) -> Void
    private let onCancel: () -> Void
    private let allowTermOnly: Bool

    public init(
        draft: STTVocabularyDraft,
        allowTermOnly: Bool = false,
        onSave: @escaping (STTVocabularyDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _correct = State(initialValue: draft.correct)
        _wrong = State(initialValue: draft.wrong)
        self.allowTermOnly = allowTermOnly
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Dictionary")
                .font(.headline)

            HStack(alignment: .center, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Correct")
                            .gridColumnAlignment(.trailing)
                        TextField("Intended text", text: $correct)
                            .dictionaryTextField()
                            .dictionaryFieldContainer()
                            .accessibilityLabel("Correct spelling")
                    }
                    GridRow {
                        Text("Misheard as")
                        TextField("Misheard text", text: $wrong)
                            .dictionaryTextField()
                            .dictionaryFieldContainer()
                            .accessibilityLabel("Misheard as")
                    }
                }
                Button {
                    swap(&correct, &wrong)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .help("Swap correct and misheard")
                .accessibilityLabel("Swap correct and misheard text")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onSave(currentDraft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(currentDraft.trimmedCorrect.isEmpty || (!allowTermOnly && !currentDraft.canSaveAlias))
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var currentDraft: STTVocabularyDraft {
        STTVocabularyDraft(
            correct: correct,
            wrong: wrong
        )
    }
}
