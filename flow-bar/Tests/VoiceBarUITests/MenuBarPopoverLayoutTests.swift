import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class MenuBarPopoverLayoutTests: XCTestCase {
    func testProductionPopoverRowsAndFooterGeometry() throws {
        var frames: [String: CGRect] = [:]
        let (window, _) = makeHost(transcript: String(repeating: "A synthetic sentence. ", count: 8)) {
            frames = $0
        }
        defer { window.contentView = nil }
        let status = try XCTUnwrap(frames["status"])
        let hotkey = try XCTUnwrap(frames["hotkey"])
        let mic = try XCTUnwrap(frames["mic"])
        let locality = try XCTUnwrap(frames["locality"])
        let transcript = try XCTUnwrap(frames["transcript"])
        let transcriptRow = try XCTUnwrap(frames["transcript-row"])
        let copy = try XCTUnwrap(frames["copy"])
        let divider = try XCTUnwrap(frames["divider"])
        let footer = try XCTUnwrap(frames["footer"])
        let settings = try XCTUnwrap(frames["settings"])
        let quit = try XCTUnwrap(frames["quit"])

        XCTAssertEqual(status.midY, hotkey.midY, accuracy: 1)
        XCTAssertEqual(transcript.midY, copy.midY, accuracy: 1)
        XCTAssertEqual(copy.width, 24, accuracy: 1)
        XCTAssertEqual(copy.height, 24, accuracy: 1)
        XCTAssertEqual(settings.midY, quit.midY, accuracy: 1)
        XCTAssertEqual(settings.width, quit.width, accuracy: 1)
        XCTAssertEqual(locality.minY - max(status.maxY, hotkey.maxY), 10, accuracy: 1)
        XCTAssertEqual(mic.minY - locality.maxY, 10, accuracy: 1)
        XCTAssertEqual(transcriptRow.minY - mic.maxY, 10, accuracy: 1)
        XCTAssertEqual(divider.minY - transcriptRow.maxY, 10, accuracy: 1)
        XCTAssertEqual(footer.minY - divider.maxY, 10, accuracy: 1)
        // F3: "Run setup…" sits on its own row under Open Settings… / Quit, on the same 10 pt rhythm.
        let setup = try XCTUnwrap(frames["setup"])
        XCTAssertEqual(setup.minY - footer.maxY, 10, accuracy: 1)
        XCTAssertEqual(setup.minX, footer.minX, accuracy: 1)
    }

    /// Source wiring only. Actual MenuBarExtra opening/keyboard-focus behavior is native acceptance.
    /// An active control appearance does not prove keyboard focus or exercise its transition.
    func testProductionPopoverRootDisablesFocusEffects() throws {
        let source = try popoverSource()
        XCTAssertTrue(rootSuppressesFocusEffects(source),
                      "Keep focusEffectDisabled on the production popover root, after padding and before its coordinate space")
    }

    func testFocusSuppressionContractRejectsRemovalAndNestedOnlySuppression() throws {
        let source = try popoverSource()
        let rootWiring = "        .focusEffectDisabled()"
        XCTAssertEqual(source.components(separatedBy: rootWiring).count - 1, 1)
        let removed = source.replacingOccurrences(of: rootWiring, with: "")
        XCTAssertFalse(rootSuppressesFocusEffects(removed), "positive control: removing suppression must be rejected")
        let nestedOnly = removed.replacingOccurrences(of: "Button(action: onSettings) {",
            with: "Button(action: onSettings) { EmptyView().focusEffectDisabled();")
        XCTAssertFalse(rootSuppressesFocusEffects(nestedOnly), "child-only suppression does not protect the popover root")
    }

    private func popoverSource() throws -> String {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: package.appendingPathComponent("Sources/VoiceBarUI/MenuBarPopoverView.swift"))
    }

    private func rootSuppressesFocusEffects(_ source: String) -> Bool {
        // Match the root's modifier chain, not an occurrence on an individual control or in a comment.
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let rootChain = #"\.padding\(12\)\s*\.focusEffectDisabled\(\)\s*\.coordinateSpace\(name: "popover"\)"#
        return code.range(of: rootChain, options: .regularExpression) != nil
    }

    func testNumberedListPreviewCollapsesNewlinesWithoutChangingOriginal() {
        let original = "Three things.\n1. Fix the popover.\n2. Ship it.\n3. Tell Etan."
        XCTAssertEqual(popoverTranscriptPreview(original),
                       "Three things. 1. Fix the popover. 2. Ship it. 3. Tell Etan.")
        XCTAssertTrue(original.contains("\n"))
    }

    func testLongNumberedListPreviewUsesThreeLines() throws {
        let original = "Three things.\n1. Fix the popover and its focus ring.\n" +
            "2. Ship it with a clean preview.\n3. Tell Etan."
        var frames: [String: CGRect] = [:]
        let (window, _) = makeHost(transcript: original) { frames = $0 }
        defer { window.contentView = nil }
        let text = try XCTUnwrap(frames["transcript"])
        XCTAssertGreaterThanOrEqual(text.height, 42)
        XCTAssertLessThanOrEqual(text.height, 48)
        XCTAssertEqual(popoverTranscriptPreview(original).components(separatedBy: "\n").count, 1)
    }

    func testTranscribingStateLaysOutCompletePopover() {
        var frames: [String: CGRect] = [:]
        let (window, _) = makeHost(transcript: "", mode: .transcribing) { frames = $0 }
        defer { window.contentView = nil }
        XCTAssertTrue(["status", "hotkey", "locality", "mic", "divider", "footer", "settings", "quit"]
            .allSatisfy { frames[$0] != nil })
    }

    func testRemoteProcessingLabelStaysWithinPopoverWidth() throws {
        var frames: [String: CGRect] = [:]
        let (window, _) = makeHost(transcript: "", remoteSTTConfigured: true) { frames = $0 }
        defer { window.contentView = nil }
        XCTAssertLessThanOrEqual(try XCTUnwrap(frames["locality"]).width, 276)
    }

    private func makeHost(
        transcript: String,
        mode: VoiceMode = .idle,
        remoteSTTConfigured: Bool = false,
        onLayout: @escaping ([String: CGRect]) -> Void = { _ in }
    ) -> (NSWindow, NSHostingView<MenuBarPopoverView>) {
        let view = MenuBarPopoverView(
            footer: .resolve(isConnected: true, mode: mode, captureLive: false,
                             errorMessage: nil, remoteSTTConfigured: remoteSTTConfigured, hasFreshHealth: true),
            hotkeyHint: "Hold F5 to dictate", defaultMicrophoneName: "Fixture Microphone",
            transcript: transcript, onLayout: onLayout
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 334, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

}
