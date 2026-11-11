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
    func testTabAndShiftTabRevealTheMicRowAndButtonAndSpaceReorders() throws {
        var reorders: [[String]] = []
        let pane = microphonePane { reorders.append($0) }
        try withHost(pane, tab: .general) { host, window in
            let rest = try lines(host)
            XCTAssertFalse(rest.contains { $0.text.contains("make default") })
            try save(host, as: "before-mic-row-focus")
            try tab(window)
            let row = try focusedFrame(window, in: host)
            XCTAssertGreaterThan(row.width, 300, "Tab reaches the microphone row")
            XCTAssertTrue(try lines(host).contains { $0.text.contains("make default") })
            try tab(window)
            let button = try focusedFrame(window, in: host)
            XCTAssertLessThan(button.width, 110, "the next Tab reaches the reserved action itself")
            XCTAssertTrue(row.contains(button), "the action belongs to this row")
            let revealed = try lines(host)
            let action = try XCTUnwrap(revealed.first { $0.text.contains("make default") })
            XCTAssertTrue(button.insetBy(dx: -4, dy: -4).intersects(action.box))
            XCTAssertNotNil(host.hitTest(NSPoint(x: button.midX, y: button.midY)))
            for text in ["macbook pro microphone", "airpods", "usb audio device"] {
                let before = try XCTUnwrap(rest.first { $0.text.contains(text) })
                let after = try XCTUnwrap(revealed.first { $0.text.contains(text) })
                XCTAssertEqual(before.box.minX, after.box.minX, accuracy: 1.5)
                XCTAssertEqual(before.box.minY, after.box.minY, accuracy: 1.5, "focus must not reflow the row")
            }
            try save(host, as: "after-mic-row-focus")
            try tab(window, backwards: true)
            XCTAssertEqual(try focusedFrame(window, in: host), row)
            XCTAssertTrue(try lines(host).contains { $0.text.contains("make default") })
            try tab(window)
            XCTAssertEqual(try focusedFrame(window, in: host), button)
            try pressSpace(window)
            XCTAssertEqual(reorders, [["builtin", "wireless", "airpods", "usb"]], "Space invokes the existing reorder once")
        }
    }

    func testSpaceOnTheFocusedMicRowUsesTheSameReorder() throws {
        var reorders: [[String]] = []
        try withHost(microphonePane { reorders.append($0) }, tab: .general) { _, window in
            try tab(window)
            try pressSpace(window)
            XCTAssertEqual(reorders, [["builtin", "wireless", "airpods", "usb"]])
        }
    }

    func testRecordingDoesNotAdmitAKeyboardMicrophoneChange() throws {
        var reorders: [[String]] = []
        try withHost(microphonePane(recording: true) { reorders.append($0) }, tab: .general) { host, window in
            try tab(window)
            try pressSpace(window)
            XCTAssertFalse(try lines(host).contains { $0.text.contains("make default") })
            XCTAssertTrue(reorders.isEmpty)
        }
    }

    func testDictionaryCopyEditDeleteRevealOnActionFocusAndShiftTabReturns() throws {
        try withHost(dictionaryPane(), tab: .dictionary) { host, window in
            // No row is selected and the pointer cannot hover this offscreen window.
            let rest = try EtanQA0510Tests.fixedScaleBitmap(host)
            try save(host, as: "before-dictionary-row-focus")
            var actionFrames: [CGRect] = []
            for _ in 0..<12 {
                try tab(window)
                guard let frame = (try? focusedFrame(window, in: host)), frame.minX > 280,
                      frame.width < 40, frame.height < 40 else { continue }
                actionFrames.append(frame)
                let focused = try EtanQA0510Tests.fixedScaleBitmap(host)
                XCTAssertGreaterThan(paintedDifference(rest, focused, in: frame), 0.1,
                                     "each formerly hidden action paints when it receives focus")
                XCTAssertNotNil(host.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
                if actionFrames.count == 3 { break }
            }
            XCTAssertEqual(actionFrames.count, 3, "Tab reaches Copy, Edit and Delete with no hover or selection")
            guard actionFrames.count == 3 else { return }
            XCTAssertLessThan(actionFrames[0].midX, actionFrames[1].midX)
            XCTAssertLessThan(actionFrames[1].midX, actionFrames[2].midX)
            try save(host, as: "after-dictionary-row-focus")
            try tab(window, backwards: true)
            XCTAssertEqual(try focusedFrame(window, in: host), actionFrames[1])
            try pressSpace(window)
            XCTAssertTrue(try lines(host).contains { $0.text.contains("edit term") }, "Space on Edit opens the real editor")
        }
    }

    func testIncludedDictionaryCopyAlsoRevealsOnFocus() throws {
        try withHost(dictionaryPane(included: true), tab: .dictionary) { host, window in
            let rest = try EtanQA0510Tests.fixedScaleBitmap(host)
            for _ in 0..<12 {
                try tab(window)
                guard let frame = try? focusedFrame(window, in: host), frame.minX > 280,
                      frame.width < 40, frame.height < 40 else { continue }
                let focused = try EtanQA0510Tests.fixedScaleBitmap(host)
                XCTAssertGreaterThan(paintedDifference(rest, focused, in: frame), 0.1)
                XCTAssertNotNil(host.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
                try save(host, as: "after-included-dictionary-row-focus")
                return
            }
            XCTFail("Tab must reach the included term's Copy action without selecting or hovering the row")
        }
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
