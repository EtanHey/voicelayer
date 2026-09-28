import SwiftUI

/// The one Add/Edit sheet for a Dictionary term: Correct / Misheard as (+ swap), and in edit mode the term's
/// existing misheard spellings with a remove button each. Settings opens it from "Add term", the pencil, or a
/// double-click on a row; the right-click "Add to Dictionary" window uses it for a correct ⇄ misheard pair.
///
/// F2: an Add that names a term already in "Your terms" opens that term instead, with Misheard as focused, when
/// focus leaves Correct or Add is pressed with no misheard spelling. With one typed, Add saves it onto the
/// existing term in one step (the mutations never duplicate a term).
public struct DictionaryAddSheetView: View {
    enum SubmitAction: Equatable {
        case save
        case open(DictionaryTermEdit)
    }

    private enum Field: Hashable {
        case correct
        case misheard
    }

    static let existingTermHint = "Already in your dictionary — add a misheard spelling"

    @State private var edit: DictionaryTermEdit
    @FocusState private var focusedField: Field?

    private let existingEntries: [STTDictionaryEntry]
    private let onSaveEdit: (DictionaryTermEdit) -> Void
    private let onCancel: () -> Void
    private let requiresMisheard: Bool

    public init(
        edit: DictionaryTermEdit,
        existingEntries: [STTDictionaryEntry] = [],
        onSave: @escaping (DictionaryTermEdit) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _edit = State(initialValue: edit)
        self.existingEntries = existingEntries
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
        existingEntries = []
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
                            .focused($focusedField, equals: .correct)
                            .accessibilityLabel("Correct spelling")
                    }
                    GridRow {
                        Text("Misheard as")
                        TextField(edit.isEditing ? "Add a misheard spelling" : "Misheard text", text: $edit.wrong)
                            .dictionaryTextField()
                            .dictionaryFieldContainer()
                            .focused($focusedField, equals: .misheard)
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

            if Self.showsExistingTermHint(for: edit, existingEntries: existingEntries) {
                Text(Self.existingTermHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!edit.canSave || (requiresMisheard && edit.trimmedWrong.isEmpty))
            }
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: focusedField) { previous, _ in
            if previous == .correct, let entry = edit.existingTerm(in: existingEntries) {
                open(edit.openingExisting(entry))
            }
        }
    }

    private func submit() {
        switch Self.submitAction(for: edit, existingEntries: existingEntries) {
        case .save: onSaveEdit(edit)
        case let .open(opened): open(opened)
        }
    }

    private func open(_ opened: DictionaryTermEdit) {
        edit = opened
        focusedField = .misheard
    }

    static func submitAction(for edit: DictionaryTermEdit, existingEntries: [STTDictionaryEntry]) -> SubmitAction {
        guard edit.trimmedWrong.isEmpty, let entry = edit.existingTerm(in: existingEntries) else { return .save }
        return .open(edit.openingExisting(entry))
    }

    static func showsExistingTermHint(for edit: DictionaryTermEdit, existingEntries: [STTDictionaryEntry]) -> Bool {
        edit.openedExisting || edit.existingTerm(in: existingEntries) != nil
    }
}
