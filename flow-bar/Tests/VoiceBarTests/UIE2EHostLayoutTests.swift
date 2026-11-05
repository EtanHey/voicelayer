import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBar
import XCTest

@MainActor
final class UIE2EHostLayoutTests: XCTestCase {
    func testFixtureControlsStayInsideSettingsContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-ui-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("voicebar-ui-e2e-v1\n".utf8).write(to: root.appendingPathComponent(".uie2e-sandbox"))
        let fixture = UIE2EHost(sandbox: try UIE2ESandbox(environment: ["VOICEBAR_UIE2E_ROOT": root.path]))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 820, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var frames: [String: CGRect] = [:]
        let view = NSHostingView(rootView: fixture.settingsRoot(pasteFeedback: true) { frames = $0 })
        view.sizingOptions = []
        window.contentView = view
        window.setContentSize(NSSize(width: 820, height: 700))
        defer { window.orderOut(nil); window.contentView = nil }
        VLOrderTestWindow(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.bounds.size, NSSize(width: 820, height: 700))
#if VOICEBAR_UIE2E_GATE2245
        XCTAssertEqual(Set(frames.keys), ["baseline", "gate", "paste", "silent", "wings", "settings", "settings-viewport"])
#else
        XCTAssertEqual(Set(frames.keys), ["baseline", "paste", "silent", "wings", "settings", "settings-viewport"])
#endif
        // SwiftUI .global inside NSHostingView is hosting-view-relative, not window-relative.
        let bounds = CGRect(x: 0, y: 0, width: 820, height: 700)
        let settings = try XCTUnwrap(frames["settings"])
        let viewport = try XCTUnwrap(frames["settings-viewport"])
        XCTAssertEqual(settings.height, 620, accuracy: 0.01, "Settings must retain its production minimum viewport")
        let visibleHeight = settings.intersection(viewport).intersection(bounds).height
        XCTAssertGreaterThan(visibleHeight, 0)
        print("QA Settings frame: \(settings); visible: \(visibleHeight)/620 points; clipped: \(620 - visibleHeight) points")
        for (name, frame) in frames where name != "settings" && name != "settings-viewport" {
            print("QA row \(name): \(frame)")
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(bounds.contains(frame), "\(name) \(frame) outside \(bounds)")
        }
    }
}
