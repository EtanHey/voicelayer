import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// F2: adding a term that is already in the dictionary opens THAT term to add a misheard spelling, instead of
/// asking for the whole term again. The match ignores case and extra whitespace. Synthetic terms only.
@MainActor
final class DictionaryAddExistingTermTests: XCTestCase {
    private let existing = [
        STTDictionaryEntry(canonical: "Zephyr Board", variants: ["zefir board"]),
        STTDictionaryEntry(canonical: "Quillo", variants: []),
    ]

    // MARK: - Model

    func testAnAddNamingAnExistingTermFindsItIgnoringCaseAndWhitespace() {
        XCTAssertEqual(DictionaryTermEdit(correct: "  zephyr   BOARD ").existingTerm(in: existing), existing[0])
        XCTAssertEqual(DictionaryTermEdit(correct: "quillo").existingTerm(in: existing), existing[1])
        XCTAssertNil(DictionaryTermEdit(correct: "Quill").existingTerm(in: existing), "a prefix is not a match")
        XCTAssertNil(DictionaryTermEdit(correct: "Zephyr Boards").existingTerm(in: existing))
        XCTAssertNil(DictionaryTermEdit(correct: "   ").existingTerm(in: existing))
    }

    func testAnEditNeverRedirects() {
        let edit = DictionaryTermEdit(original: existing[1], correct: "Zephyr Board")
        XCTAssertNil(edit.existingTerm(in: existing), "renaming a term onto another is the edit flow's business")
    }

    func testOpeningTheExistingTermKeepsATypedMisheardSpellingAndItsVariants() {
        let opened = DictionaryTermEdit(correct: "zephyr board", wrong: " zeffer bored ").openingExisting(existing[0])

        XCTAssertEqual(opened.original, existing[0])
        XCTAssertEqual(opened.correct, "Zephyr Board", "the term keeps its stored spelling, so saving never renames")
        XCTAssertEqual(opened.wrong, " zeffer bored ")
        XCTAssertEqual(opened.keptVariants, ["zefir board"])
        XCTAssertTrue(opened.openedExisting)
        XCTAssertFalse(DictionaryTermEdit(original: existing[0]).openedExisting, "the pencil is not a redirect")
    }

    func testSubmittingAnExistingTermWithoutAMisheardSpellingOpensItInsteadOfSaving() {
        let add = DictionaryTermEdit(correct: "ZEPHYR board")
        XCTAssertEqual(
            DictionaryAddSheetView.submitAction(for: add, existingEntries: existing),
            .open(add.openingExisting(existing[0]))
        )

        let withVariant = DictionaryTermEdit(correct: "zephyr board", wrong: "zeffer bored")
        XCTAssertEqual(
            DictionaryAddSheetView.submitAction(for: withVariant, existingEntries: existing), .save,
            "with a misheard spelling already typed, Add saves it onto the existing term in one step"
        )
        XCTAssertEqual(
            DictionaryAddSheetView.submitAction(for: DictionaryTermEdit(correct: "Nimbus"), existingEntries: existing),
            .save, "a new term is added as before"
        )
        let opened = add.openingExisting(existing[0])
        XCTAssertEqual(
            DictionaryAddSheetView.submitAction(for: opened, existingEntries: existing), .save,
            "once open, Save saves"
        )
    }

    func testTheHintShowsForAMatchOrAnOpenedTermOnly() {
        let hint = "Already in your dictionary — add a misheard spelling"
        XCTAssertEqual(DictionaryAddSheetView.existingTermHint, hint)
        XCTAssertTrue(DictionaryAddSheetView.showsExistingTermHint(
            for: DictionaryTermEdit(correct: "quillo"), existingEntries: existing
        ))
        XCTAssertTrue(DictionaryAddSheetView.showsExistingTermHint(
            for: DictionaryTermEdit(correct: "quillo").openingExisting(existing[1]), existingEntries: existing
        ))
        XCTAssertFalse(DictionaryAddSheetView.showsExistingTermHint(
            for: DictionaryTermEdit(correct: "Nimbus"), existingEntries: existing
        ))
        XCTAssertFalse(DictionaryAddSheetView.showsExistingTermHint(
            for: DictionaryTermEdit(original: existing[1]), existingEntries: existing
        ), "editing via the pencil needs no hint")
    }

    /// Saving the opened term adds only the new misheard spelling to it: no second term, no rename.
    func testSavingTheOpenedTermAddsOnlyTheVariant() {
        var entries = existing
        var opened = DictionaryTermEdit(correct: "zephyr board").openingExisting(existing[0])
        opened.wrong = "zeffer bored"
        var addedTerms: [String] = []
        var removedTerms: [String] = []
        var addedAliases: [String] = []

        let saved = SettingsDictionaryMutations.apply(
            opened,
            localEntries: &entries,
            onAddPromptTerm: { addedTerms.append($0) },
            onRemovePromptTerm: { removedTerms.append($0) },
            onAddVocabularyAlias: { addedAliases.append("\($1)→\($0)") },
            onRemoveVocabularyAlias: { _ in }
        )

        XCTAssertEqual(saved, "Zephyr Board")
        XCTAssertEqual(entries.map(\.canonical), ["Zephyr Board", "Quillo"])
        XCTAssertEqual(entries[0].variants, ["zefir board", "zeffer bored"])
        XCTAssertEqual(addedTerms, [])
        XCTAssertEqual(removedTerms, [])
        XCTAssertEqual(addedAliases, ["zeffer bored→Zephyr Board"])
    }

    // MARK: - Hosted sheet

    /// Pressing Add with an existing term and no misheard spelling does not close the sheet: it opens the term
    /// (the sheet grows by its hint and its existing spellings). Pressing again saves an edit of THAT term.
    func testPressingAddOnAnExistingTermOpensItAndTheNextPressSavesAnEditOfIt() throws {
        var saves: [DictionaryTermEdit] = []
        var cancels = 0
        let height = Height()
        let (window, host) = makeHost(
            DictionaryAddSheetView(
                edit: DictionaryTermEdit(correct: "zephyr board"),
                existingEntries: existing,
                onSave: { saves.append($0) },
                onCancel: { cancels += 1 }
            ),
            height: height
        )
        defer { tearDown(window) }
        let heightBefore = height.value
        XCTAssertGreaterThan(heightBefore, 0)

        let addButton = try clickPrimaryButton(in: host, window: window) {
            !saves.isEmpty || cancels > 0 || height.value != heightBefore
        }

        XCTAssertEqual(saves.count, 0, "Add on an existing term must not save a duplicate or close the sheet")
        XCTAssertEqual(cancels, 0)
        XCTAssertGreaterThan(height.value, heightBefore, "the hint and existing spellings appear")

        click(host, at: addButton, window: window)

        let saved = try XCTUnwrap(saves.first)
        XCTAssertEqual(saved.original, existing[0], "the save edits the existing term")
        XCTAssertEqual(saved.correct, "Zephyr Board")
    }

    func testPressingAddOnANewTermStillSavesAtOnce() throws {
        var saves: [DictionaryTermEdit] = []
        let (window, host) = makeHost(
            DictionaryAddSheetView(
                edit: DictionaryTermEdit(correct: "Nimbus"),
                existingEntries: existing,
                onSave: { saves.append($0) },
                onCancel: {}
            ),
            height: Height()
        )
        defer { tearDown(window) }

        _ = try clickPrimaryButton(in: host, window: window) { !saves.isEmpty }

        XCTAssertEqual(saves.map(\.correct), ["Nimbus"])
        XCTAssertNil(saves.first?.original)
    }

    func testSettingsHandsTheSheetYourTerms() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/VoiceBarUI/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("DictionaryAddSheetView(edit: edit, existingEntries: localEntries, onSave:"))
    }

    func testWritesTheAddAndOpenedSheetsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs.local/design/2026-09-28-f2-dictionary-add-existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let typed = DictionaryTermEdit(correct: "zephyr board")
        for (name, edit) in [("add-typed", typed), ("opened", typed.openingExisting(existing[0]))] {
            for (appearance, slug) in [(NSAppearance(named: .aqua), "light"), (
                NSAppearance(named: .darkAqua),
                "dark"
            )] {
                let size = CGSize(width: 420, height: 230)
                let host = NSHostingView(rootView: DictionaryAddSheetView(
                    edit: edit, existingEntries: existing, onSave: { _ in }, onCancel: {}
                ).frame(width: size.width, height: size.height, alignment: .top))
                host.appearance = appearance
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                bitmap.size = size
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("sheet-\(name)-\(slug).png"), options: .atomic)
            }
        }
    }

    // MARK: - Helpers

    private static let size = CGSize(width: 420, height: 320)

    private final class Height {
        var value: CGFloat = 0
    }

    /// Bottom-aligned in a fixed host, so the button row stays put while the sheet grows; reports its height.
    private func makeHost(_ sheet: DictionaryAddSheetView, height: Height) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: sheet
            .frame(width: 420)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { height.value = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, new in height.value = new }
            })
            .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom))
        host.frame = NSRect(origin: .zero, size: Self.size)
        // A plain borderless window: AppKit delivers synthetic clicks to SwiftUI buttons in it.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return (window, host)
    }

    private func tearDown(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The primary button is the rightmost control on the sheet's bottom row (18 pt padding). Scans from the right
    /// edge until a click has an effect, and returns where it landed.
    private func clickPrimaryButton(
        in host: NSView, window: NSWindow, until hit: () -> Bool
    ) throws -> NSPoint {
        for y in stride(from: CGFloat(26), through: 34, by: 4) {
            for x in stride(from: Self.size.width - 20, through: Self.size.width - 90, by: -4) {
                let point = NSPoint(x: x, y: y)
                click(host, at: point, window: window)
                if hit() { return point }
            }
        }
        throw NSError(domain: "DictionaryAddExistingTermTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "no primary button found on the bottom row"])
    }

    private func click(_ host: NSView, at point: NSPoint, window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { return XCTFail("could not build \(type)") }
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }
}
