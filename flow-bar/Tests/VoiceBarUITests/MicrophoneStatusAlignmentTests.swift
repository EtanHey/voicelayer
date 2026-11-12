import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import XCTest
import Vision

/// MC2 A01: measure the real action frame against painted status text, independent of keyboard-focus reveal.
@MainActor
final class MicrophoneStatusAlignmentTests: XCTestCase {
    private final class Audit { var entries: [SettingsTextAuditEntry] = []; var controls: [String: CGRect] = [:] }
    func testActionCentreSharesTheConnectedLineWithoutHoverReflow() throws {
        let audit = Audit()
        let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
            selectedDeviceID: { nil }, prioritySnapshot: { SettingsDrawerLaneSSnapshotTests.micSnapshot() },
            onReorderPriority: { _ in }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyRevision: { 0 }, initialTab: .general)
        func root(hover: Bool) -> AnyView {
            AnyView(VStack(spacing: 0) {
                pane.notchDrawerPane(.general)
                    .environment(\.settingsHoverPreview, SettingsHoverPreview(microphoneRow: hover ? 1 : nil))
                    .onPreferenceChange(SettingsTextAuditKey.self) { audit.entries = $0 }
                    .frame(width: 420, height: 600)
                Text("M1 synthetic · native glass unavailable").font(.system(size: 10)).frame(height: 24)
            }.background(Color(white: 0.16)).environment(\.colorScheme, .dark)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SettingsControlFrameKey.self,
                        value: ["host-root": proxy.frame(in: .global)])
                })
                .onPreferenceChange(SettingsControlFrameKey.self) { audit.controls = $0 })
        }
        let host = NSHostingView(rootView: root(hover: false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 624), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func frames() throws -> (title: CGRect, status: CGRect, next: CGRect) {
            let title = try XCTUnwrap(audit.entries.first { $0.text == "MacBook Pro Microphone" }).frame
            let status = try XCTUnwrap(audit.entries.first {
                $0.text == "Connected" && $0.frame.minY >= title.maxY && $0.frame.minY < title.maxY + 40
            }).frame
            let next = try XCTUnwrap(audit.entries.first { $0.text == "USB Audio Device" }).frame
            return (title, status, next)
        }
        func actionFrame() throws -> CGRect {
            let origin = try XCTUnwrap(audit.controls["host-root"])
            let global = try XCTUnwrap(audit.controls["microphone-default-1"])
            // SwiftUI global coordinates include window chrome; OCR uses the hosting view's content origin.
            return global.offsetBy(dx: -origin.minX, dy: -origin.minY)
        }
        settle()
        let rest = try frames()
        let reserved = try actionFrame()
        host.rootView = root(hover: true)
        settle()
        let hover = try frames()
        // Candidate 7 deliberately reverted focus reveal. Measure the production button's actual bounds,
        // including its reserved rest frame, without treating a focused window as a focused action.
        let action = try actionFrame()
        XCTAssertLessThan(action.width, 110)
        XCTAssertGreaterThan(action.minX, 280)
        let painted = try EtanQA0510Tests.fixedScaleBitmap(host)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(painted.cgImage), options: [:]).perform([request])
        let statusInk = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.lowercased().contains("used for dictation") == true
        }).boundingBox
        let statusCentre = (1 - statusInk.midY) * host.bounds.height
        XCTAssertEqual(action.midY, statusCentre, accuracy: 1,
                       "A01: action centre \(action.midY), painted status centre \(statusCentre)")
        XCTAssertEqual(action, reserved, "Hover must preserve the reserved button frame")
        for candidate in [hover] {
            for pair in [(rest.title, candidate.title), (rest.status, candidate.status), (rest.next, candidate.next)] {
                XCTAssertEqual(pair.0.minX, pair.1.minX, accuracy: 0.1)
                XCTAssertEqual(pair.0.minY, pair.1.minY, accuracy: 0.1)
            }
        }
        let phase = ProcessInfo.processInfo.environment["A01_PHASE"] ?? "after"
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
            URL(fileURLWithPath: SettingsPolishS5Tests.output).appendingPathComponent("\(phase)-A01-status-alignment.png"))
        print("A01 action=\(action) paintedStatusY=\(statusCentre) delta=\(abs(action.midY - statusCentre))")
        XCTAssertFalse(NSApp.isActive)
    }
}
