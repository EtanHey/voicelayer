import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import Vision
import XCTest

/// Drive the production views' AppKit key loop, without hover injection, pointer events or foreground activation.
/// Optional PNGs show the real focused paint; they do not establish installed-app or VoiceOver acceptance.
@MainActor
final class SettingsRowActionFocusTests: XCTestCase {
    func testRecordingDoesNotAdmitAKeyboardMicrophoneChange() throws {
        var reorders: [[String]] = []
        try withHost(microphonePane(recording: true) { reorders.append($0) }, tab: .general) { host, window in
            try tab(window)
            try pressSpace(window)
            XCTAssertFalse(try lines(host).contains { $0.text.contains("make default") })
            XCTAssertTrue(reorders.isEmpty)
        }
    }

    func testUnselectedDictionaryTermsDoNotAddHiddenTabStops() throws {
        try withHost(dictionaryPane(), tab: .dictionary) { host, window in
            for _ in 0..<10 {
                try tab(window)
                if let frame = try? focusedFrame(window, in: host) {
                    XCTAssertFalse(frame.minX > 280 && frame.width < 50 && frame.height < 40,
                                   "An unselected term must not put actions in the key loop: \(frame)")
                }
            }
        }
    }

    func testSpaceWithoutASelectedTermDoesNotRemoveDictionaryEntries() throws {
        try withHost(dictionaryPane(), tab: .dictionary) { host, window in
            for _ in 0..<8 {
                try tab(window)
                try pressSpace(window)
                // Escape dismisses any native menu; no deletion has been confirmed.
                try window.sendEvent(key("\u{1b}", code: 53, window: window))
            }
            XCTAssertTrue(try lines(host).contains { $0.text.contains("kubernetes") })
        }
    }

    func testDictionaryDeletionRequiresConfirmationAndCancelAndUndoKeepTheTerm() throws {
        var removed: [String] = []
        let preview = STTVocabularyPreview(updatedAt: "2026-11-11T00:00:00Z", entries: [
            STTDictionaryEntry(canonical: "Kubernetes", variants: []),
            STTDictionaryEntry(canonical: "TypeScript", variants: [])])
        let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
            selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: { preview }, vocabularyRevision: { 0 }, onRemovePromptTerm: { removed.append($0) },
            initialTab: .dictionary, initialDictionaryPreview: preview, initialSelectedTermRowID: "personal:Kubernetes")
        try withHost(pane, tab: .dictionary) { host, window in
            try focusList(window, in: host)
            try pressSpace(window)
            XCTAssertFalse(try lines(host).contains { $0.text.contains("delete term?") })
            XCTAssertTrue(removed.isEmpty)
            try window.sendEvent(key("\u{7f}", code: 51, window: window))
            settle()
            XCTAssertTrue(try lines(host).contains { $0.text.contains("delete term?") })
            XCTAssertTrue(removed.isEmpty, "Asking does not remove the term")
            try save(host, as: "after-dictionary-delete-confirmation")
            XCTAssertTrue(NotchEscapeOwnership.shared.cancelNewest())
            settle()
            XCTAssertFalse(try lines(host).contains { $0.text.contains("delete term?") })
            XCTAssertTrue(try lines(host).contains { $0.text == "kubernetes" })
            try focusList(window, in: host)
            try window.sendEvent(key("\u{7f}", code: 51, window: window))
            settle()
            try activatePainted("Delete", in: host, window: window)
            XCTAssertTrue(try lines(host).contains { $0.text.contains("undo") })
            XCTAssertFalse(try lines(host).contains { $0.text == "kubernetes" })
            XCTAssertTrue(removed.isEmpty, "Confirmation starts the existing undo interval")
            try save(host, as: "after-dictionary-pending-undo")
            window.sendEvent(try key("z", code: 6, window: window, modifiers: .command))
            settle()
            XCTAssertTrue(try lines(host).contains { $0.text == "kubernetes" })
            XCTAssertTrue(removed.isEmpty, "Undo sends no removal")
            try save(host, as: "after-dictionary-undo")
            try focusList(window, in: host)
            var focusedEdit = false
            for _ in 0..<8 {
                try tab(window)
                if let frame = try? focusedFrame(window, in: host), frame.minX > 280,
                   frame.width < 40, frame.height < 40 {
                    try pressSpace(window)
                    focusedEdit = try lines(host).contains { $0.text.contains("edit term") }
                    break
                }
            }
            XCTAssertTrue(focusedEdit, "Tab reaches the selected term's Edit action and Space opens its editor")
            XCTAssertTrue(try lines(host).contains { $0.text.contains("edit term") })
            try save(host, as: "after-dictionary-editor")
            XCTAssertTrue(NotchEscapeOwnership.shared.cancelNewest())
            settle()
        }
    }

    private func focusList(_ window: NSWindow, in host: NSView) throws {
        for _ in 0..<16 {
            try tab(window)
            if let frame = try? focusedFrame(window, in: host), frame.width > 300, frame.height > 150 { return }
        }
        XCTFail("Tab did not reach the Dictionary list")
    }

    private func activatePainted(_ label: String, in host: NSView, window: NSWindow) throws {
        let words = try lines(host)
        let rect = try XCTUnwrap(words.first { $0.text == label.lowercased() },
                                 "Missing painted \(label): \(words.map(\.text))").box
        for _ in 0..<16 {
            try tab(window)
            if let frame = try? focusedFrame(window, in: host), frame.insetBy(dx: -2, dy: -2).contains(
                CGPoint(x: rect.midX, y: rect.midY)) {
                try pressSpace(window)
                return
            }
        }
        XCTFail("Tab did not reach painted \(label)")
    }

    private func microphonePane(recording: Bool = false, reorder: @escaping ([String]) -> Void) -> SettingsView {
        SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            prioritySnapshot: { SettingsDrawerLaneSSnapshotTests.micSnapshot() }, onReorderPriority: reorder,
            modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 },
            isRecordingActive: { recording }, initialTab: .general)
    }

    private func dictionaryPane(included: Bool = false) -> SettingsView {
        let entry = STTDictionaryEntry(canonical: "Kubernetes", variants: [])
        let preview = STTVocabularyPreview(updatedAt: "2026-01-01T00:00:00Z", entries: included ? [] : [entry],
            displayEntries: [STTDictionaryDisplayEntry(source: included ? "bundled" : "personal", entry: entry)])
        return SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyPreview: { preview }, vocabularyRevision: { 0 },
            initialTab: .dictionary, initialDictionaryPreview: preview, initialIncludedTermsExpanded: included)
    }

    private func withHost<V: View>(_ view: V, tab: SettingsTab?, body: (NSView, NSWindow) throws -> Void) throws {
        let content: AnyView
        if let pane = view as? SettingsView, let tab {
            content = AnyView(pane.notchDrawerPane(tab))
        } else {
            content = AnyView(view)
        }
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            content.frame(width: 420, height: 500)
            Text("M1 synthetic focus · solid backdrop; glass unsupported")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 22)
        }.background(Color(white: 0.16)).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 522),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        settle()
        try body(host, window)
        XCTAssertFalse(NSApp.isActive)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    private func tab(_ window: NSWindow, backwards: Bool = false) throws {
        try window.sendEvent(key(backwards ? "\u{19}" : "\t", code: 48, window: window,
                                 modifiers: backwards ? .shift : []))
        settle()
    }
    private func pressSpace(_ window: NSWindow) throws {
        try window.sendEvent(key(" ", code: 49, window: window))
        settle()
    }
    private func key(_ text: String, code: UInt16, window: NSWindow,
                     modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    private func focusedFrame(_ window: NSWindow, in host: NSView) throws -> CGRect {
        let focus = try XCTUnwrap(window.firstResponder as? NSView, "the key event must focus a real view")
        return focus.convert(focus.bounds, to: host)
    }
    private func lines(_ host: NSView) throws -> [SettingsDrawerLaneSLayoutTests.Word] {
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox
            return .init(text: text.lowercased(), box: CGRect(x: b.minX * host.bounds.width,
                y: (1 - b.maxY) * host.bounds.height, width: b.width * host.bounds.width, height: b.height * host.bounds.height))
        }
    }
    private func paintedDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> CGFloat {
        let scale = CGFloat(a.pixelsWide) / 420
        var largest: CGFloat = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                guard let c = a.colorAt(x: x, y: y), let d = b.colorAt(x: x, y: y) else { continue }
                largest = max(largest, abs(c.redComponent - d.redComponent), abs(c.greenComponent - d.greenComponent))
            }
        }
        return largest
    }
    private func save(_ host: NSView, as name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["VOICEBAR_S4_PNG_DIR"] else { return }
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
