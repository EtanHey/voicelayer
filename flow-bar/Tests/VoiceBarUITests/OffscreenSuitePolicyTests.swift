import AppKit
import OffscreenTestSupport
import Foundation
import XCTest

/// This runs without opening a window: unsafe fixture calls must go through the shared policy.
final class OffscreenSuitePolicyTests: XCTestCase {
    @MainActor
    func testPolicyIsInstalledBeforeAnyWindowCanBePresented() throws {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        guard VLOffscreenPolicyInstalled() else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        XCTAssertTrue(window.isVisible, "controller show/close assertions must retain their meaning")
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApplication.shared.isActive)
        XCTAssertEqual(window.alphaValue, 0)
        for screen in NSScreen.screens {
            XCTAssertFalse(window.frame.intersects(screen.frame))
        }
    }

    @MainActor
    func testNativeGlassCaptureCannotMoveOrResizeOntoAnyScreen() {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        guard VLOffscreenPolicyInstalled() else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        VLOrderCompositorTestWindow(window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, "native glass compositor capture cannot use a transparent window")
        window.setFrameOrigin(.zero)
        for screen in NSScreen.screens { XCTAssertFalse(window.frame.intersects(screen.frame)) }
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: true)
        XCTAssertEqual(window.frame.size, NSSize(width: 900, height: 600))
        for screen in NSScreen.screens { XCTAssertFalse(window.frame.intersects(screen.frame)) }
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSApplication.shared.isActive)
    }

    func testFixturesNeverRequestKeyFocusOrAppActivationDirectly() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        let forbidden = [".makeKeyAndOrderFront(", ".makeKeyWindow(", ".activate(ignoringOtherApps:", ".orderFront(", ".orderFrontRegardless("]
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "OffscreenSuitePolicyTests.swift" {
            let source = try String(contentsOf: url)
            for (offset, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("//"), forbidden.contains(where: { code.contains($0) }) {
                    XCTFail("\(url.lastPathComponent):\(offset + 1): unsafe focus/activation request: \(code)")
                }
            }
        }
    }
}
