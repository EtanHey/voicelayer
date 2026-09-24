import SwiftUI

/// The one Add/Edit sheet for a Dictionary term: Correct / Misheard as (+ swap), and in edit mode the term's
/// existing misheard spellings with a remove button each. Settings opens it from "Add term", the pencil, or a
/// double-click on a row; the right-click "Add to Dictionary" window uses it for a correct ⇄ misheard pair.
public struct DictionaryAddSheetView: View {
    @State private var edit: DictionaryTermEdit

    private let onSaveEdit: (DictionaryTermEdit) -> Void
    private let onCancel: () -> Void
    private let requiresMisheard: Bool

    public init(
        edit: DictionaryTermEdit,
        onSave: @escaping (DictionaryTermEdit) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _edit = State(initialValue: edit)
        requiresMisheard = false
        onSaveEdit = onSave
        self.onCancel = onCancel
    }

    public init(
        draft: STTVocabularyDraft,
        allowTermOnly: Bool = false,
        onSave: @escaping (STTVocabularyDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _edit = State(initialValue: DictionaryTermEdit(correct: draft.correct, wrong: draft.wrong))
        requiresMisheard = !allowTermOnly
        onSaveEdit = { onSave(STTVocabularyDraft(correct: $0.correct, wrong: $0.wrong)) }
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(edit.isEditing ? "Edit Term" : "Add to Dictionary")
                .font(.headline)

            HStack(alignment: .center, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Correct")
                            .gridColumnAlignment(.trailing)
                        TextField("Intended text", text: $edit.correct)
                            .dictionaryTextField()
                            .dictionaryFieldContainer()
                            .accessibilityLabel("Correct spelling")
                    }
                    GridRow {
                        Text("Misheard as")
                        TextField(edit.isEditing ? "Add a misheard spelling" : "Misheard text", text: $edit.wrong)
                            .dictionaryTextField()
                            .dictionaryFieldContainer()
                            .accessibilityLabel("Misheard as")
                    }
                }
                Button {
                    (edit.correct, edit.wrong) = (edit.wrong, edit.correct)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Swap correct and misheard")
                .accessibilityLabel("Swap correct and misheard text")
            }

            if edit.isEditing, !edit.keptVariants.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also heard as")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(edit.keptVariants, id: \.self) { variant in
                            HStack(spacing: 2) {
                                Text(variant)
                                Button {
                                    edit.removedVariants.append(variant)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .help("Remove misheard spelling \(variant)")
                                .accessibilityLabel("Remove misheard spelling \(variant)")
                            }
                            .padding(.leading, 9)
                            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.24))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(edit.isEditing ? "Save" : "Add") {
                    onSaveEdit(edit)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!edit.canSave || (requiresMisheard && edit.trimmedWrong.isEmpty))
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
