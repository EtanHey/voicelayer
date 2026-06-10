import Foundation
import XCTest

/// GREP GATE — the v9 notch must use NATIVE hit-testing only.
///
/// "Version A" routed clicks with CGEvent / event-taps / a global mouse monitor and froze
/// the whole Mac (memory: voicebar-mic + the version-A incident). The v9 notch hit-testing
/// must use ONLY native AppKit/SwiftUI: `NSView.hitTest` returning nil outside the live
/// shape, `NSTrackingArea`, `.onHover`, `.contentShape`.
///
/// This gate scans the UI layer (`Sources/VoiceBarUI`) for forbidden POINTER-ROUTING
/// symbols. It deliberately does NOT scan `Sources/VoiceBar` — the global record hotkey
/// (`HotkeyManager` CGEventTap) and the paste path (`simulatePaste` CGEvent) are the
/// existing, sanctioned KEYBOARD subsystem, unrelated to notch pointer handling.
final class ForbiddenPointerAPIGateTests: XCTestCase {
    /// Symbols that indicate synthetic-mouse / global-click interception — the version-A
    /// mechanism. None may appear anywhere in the UI (presentation) layer.
    private let forbiddenSymbols = [
        "CGEvent",
        "CGEventTap",
        "CGEventPost",
        "CGEventCreate",
        "addGlobalMonitorForEvents",
        "AXIsProcessTrusted",
    ]

    private func uiSourceDirectory() -> URL? {
        // This file lives at flow-bar/Tests/VoiceBarUITests/ — walk up to flow-bar/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let flowBar = thisFile
            .deletingLastPathComponent() // VoiceBarUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // flow-bar
        let ui = flowBar.appendingPathComponent("Sources/VoiceBarUI", isDirectory: true)
        return FileManager.default.fileExists(atPath: ui.path) ? ui : nil
    }

    func testUILayerHasNoForbiddenPointerRoutingSymbols() throws {
        guard let ui = uiSourceDirectory() else {
            throw XCTSkip("Source tree not reachable from test bundle (binary-only run)")
        }
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: ui, includingPropertiesForKeys: nil)
        var offenders: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: url, encoding: .utf8)
            for symbol in forbiddenSymbols where contents.contains(symbol) {
                offenders.append("\(url.lastPathComponent): \(symbol)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Forbidden pointer-routing symbol(s) found in VoiceBarUI — version-A risk:\n"
                + offenders.joined(separator: "\n")
        )
    }
}
