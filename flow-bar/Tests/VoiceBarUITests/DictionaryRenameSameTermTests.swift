@testable import VoiceBarUI
import XCTest

/// F2b (RX6 #201 r2 Medium): an edit that renames one term onto a differently spaced existing term. The rename's
/// collision check must use the same `DictionaryTermEdit.sameTerm` rule as the save's lookup; otherwise the rename
/// creates a second, differently spaced row and the lookup then sends the new variant to the OTHER row.
/// Synthetic terms only.
final class DictionaryRenameSameTermTests: XCTestCase {
    private final class Calls {
        var addedTerms: [String] = []
        var removedTerms: [String] = []
        var addedAliases: [String] = []
    }

    private func apply(_ edit: DictionaryTermEdit, to entries: inout [STTDictionaryEntry]) -> (String?, Calls) {
        let calls = Calls()
        let saved = SettingsDictionaryMutations.apply(
            edit,
            localEntries: &entries,
            onAddPromptTerm: { calls.addedTerms.append($0) },
            onRemovePromptTerm: { calls.removedTerms.append($0) },
            onAddVocabularyAlias: { calls.addedAliases.append("\($1)→\($0)") },
            onRemoveVocabularyAlias: { _ in }
        )
        return (saved, calls)
    }

    func testRenamingOntoADifferentlySpacedTermMergesIntoItAndTheVariantLandsThere() {
        let nimbus = STTDictionaryEntry(canonical: "Nimbus", variants: ["nimbis"])
        var entries = [STTDictionaryEntry(canonical: "Zephyr Board", variants: ["zefir board"]), nimbus]
        var edit = DictionaryTermEdit(original: nimbus)
        edit.correct = "zephyr   board"
        edit.wrong = "zeffer bored"

        let (saved, calls) = apply(edit, to: &entries)

        XCTAssertEqual(saved, "Zephyr Board")
        XCTAssertEqual(
            entries,
            [STTDictionaryEntry(canonical: "Zephyr Board", variants: ["zefir board", "nimbis", "zeffer bored"])],
            "one row: Nimbus merged into the existing term, no differently spaced duplicate"
        )
        XCTAssertEqual(calls.addedTerms, [], "no new term is created")
        XCTAssertEqual(calls.removedTerms, ["Nimbus"])
        XCTAssertEqual(calls.addedAliases, ["nimbis→Zephyr Board", "zeffer bored→Zephyr Board"])
    }

    func testRenameCollisionUsesTheSharedRuleDirectly() {
        var entries = [
            STTDictionaryEntry(canonical: "Zephyr Board", variants: []),
            STTDictionaryEntry(canonical: "Nimbus", variants: []),
        ]
        var text = "  ZEPHYR\tboard "
        var added: [String] = []

        SettingsDictionaryMutations.renameTerm(
            "Nimbus", editText: &text, localEntries: &entries,
            onAddPromptTerm: { added.append($0) }, onRemovePromptTerm: { _ in }, onAddVocabularyAlias: { _, _ in }
        )

        XCTAssertEqual(entries.map(\.canonical), ["Zephyr Board"])
        XCTAssertEqual(added, [])
    }

    /// A spacing-only change to a term's own spelling is not a rename, the same as a case-only change.
    func testASpacingOnlyEditOfTheSameTermIsNotARename() {
        let original = STTDictionaryEntry(canonical: "Zephyr Board", variants: [])
        var entries = [original]
        var edit = DictionaryTermEdit(original: original)
        edit.correct = "zephyr   board"

        let (saved, calls) = apply(edit, to: &entries)

        XCTAssertEqual(saved, "Zephyr Board")
        XCTAssertEqual(entries, [original])
        XCTAssertEqual(calls.addedTerms, [])
        XCTAssertEqual(calls.removedTerms, [])
    }

    func testARealRenameStillRenames() {
        let nimbus = STTDictionaryEntry(canonical: "Nimbus", variants: ["nimbis"])
        var entries = [STTDictionaryEntry(canonical: "Zephyr Board", variants: []), nimbus]
        var edit = DictionaryTermEdit(original: nimbus)
        edit.correct = "Nimbus Cloud"

        let (saved, calls) = apply(edit, to: &entries)

        XCTAssertEqual(saved, "Nimbus Cloud")
        XCTAssertEqual(entries.map(\.canonical), ["Zephyr Board", "Nimbus Cloud"])
        XCTAssertEqual(calls.addedTerms, ["Nimbus Cloud"])
        XCTAssertEqual(calls.removedTerms, ["Nimbus"])
        XCTAssertEqual(calls.addedAliases, ["nimbis→Nimbus Cloud"])
    }
}
