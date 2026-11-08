import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class E2E24MeasuredGeometryTests: XCTestCase {
    private final class MarkerView: NSView { var markerID = "" }
    private struct Marker: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> NSView { let v = MarkerView(); v.markerID = id; v.wantsLayer = true; v.layer?.backgroundColor = NSColor.systemRed.cgColor; return v }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    func testMeasuredDisplaysKeepControlsOutsidePhysicalNotchAndRender() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".build.noindex/e2e24-geometry")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for fixture in ["m4", "m1"] {
            let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/e2e-2.4/\(fixture)-screen.json"))
            let row = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
            let left = try XCTUnwrap(row["auxiliaryTopLeftArea"] as? [String: Double])
            let right = try XCTUnwrap(row["auxiliaryTopRightArea"] as? [String: Double])
            let gap = try XCTUnwrap(right["x"]) - XCTUnwrap(left["x"]) - XCTUnwrap(left["width"])
            for state in ["launcher", "recording", "history", "teleprompter"] {
                let p = VoiceBarNotchPresentation.resolve(hasTeleprompter: state == "teleprompter", isRecording: state == "recording", hasCompactStatus: false,
                    hasHistoryPanel: state == "history", isHovered: state == "launcher", isKeyboardFocused: false, coreWidth: gap)
                let view = VoiceBarNotchView(presentation: p,
                    leadingContent: { Marker(id: "leading").frame(maxWidth: .infinity, maxHeight: .infinity) },
                    trailingContent: { Marker(id: "trailing").frame(maxWidth: .infinity, maxHeight: .infinity) }, lowerContent: { EmptyView() })
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: p.geometry.totalWidth, height: p.geometry.totalHeight)
                let panel = NSPanel(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
                panel.contentView = host; panel.setFrameOrigin(NSPoint(x: -100_000, y: -100_000)); panel.orderBack(nil)
                defer { panel.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded()
                var markers: [String: CGRect] = [:]
                func walk(_ v: NSView) { if let marker = v as? MarkerView { markers[marker.markerID] = v.convert(v.bounds, to: host) }; v.subviews.forEach(walk) }
                walk(host)
                let physicalLeft = try XCTUnwrap(left["x"]) + XCTUnwrap(left["width"])
                let physicalRight = try XCTUnwrap(right["x"])
                let screenOffset = physicalLeft - p.geometry.coreOriginX
                if p.geometry.leadingWingWidth > 0 {
                    let leading = try XCTUnwrap(markers["leading"])
                    XCTAssertGreaterThanOrEqual(physicalLeft - (leading.maxX + screenOffset), 8, "\(fixture) \(state) leading")
                }
                if p.geometry.trailingWingWidth > 0 {
                    let trailing = try XCTUnwrap(markers["trailing"])
                    XCTAssertGreaterThanOrEqual(trailing.minX + screenOffset - physicalRight, 8, "\(fixture) \(state) trailing")
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(fixture)-\(state).png"))
            }
        }
    }
}
