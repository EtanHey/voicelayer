import AppKit
import SwiftUI
import OffscreenTestSupport
@testable import VoiceBarUI
import XCTest

/// Synthetic, silent Settings fixtures. The native lane owns actual compositor acceptance.
@MainActor final class NativeFixRegressionTests: XCTestCase {
    private var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["NATIVEFIX_OUTPUT"] ?? NSTemporaryDirectory()) }
    private func requireOutput() throws {
        guard let path = ProcessInfo.processInfo.environment["NATIVEFIX_OUTPUT"], !path.isEmpty else {
            throw XCTSkip("Set NATIVEFIX_OUTPUT to run synthetic nativefix geometry/render artifacts")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    private var baseline: Bool { ProcessInfo.processInfo.environment["NATIVEFIX_BASELINE"] == "1" }
    private func settle(_ host: NSView, seconds: Double = 0.3) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }
    private func scrolls(_ root: NSView) -> [NSScrollView] {
        (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap(scrolls)
    }
    private func capture(_ host: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    private func withHost<V: View>(_ view: V, size: CGSize, dark: Bool, body: (NSHostingView<V>) throws -> Void) throws {
        XCTAssertTrue(VLOffscreenPolicyInstalled())
        let host = NSHostingView(rootView: view); host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        settle(host); try body(host)
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
    }
    private func history() -> some View {
        let date = Date(timeIntervalSince1970: 1793512800)
        let entries = (0..<12).map { i in
            SettingsHistoryEntry(id: "nativefix-\(i)", dayKey: "2026-11-01", recordingID: "nativefix-\(i)",
                createdAt: date.addingTimeInterval(-Double(i) * 120), transcript: i == 0 ? "Synthetic saved transcript." : "Synthetic list row \(i).",
                audioPath: output.appendingPathComponent("absent-\(i).wav"), durationMs: 32000)
        }
        let page = SettingsHistoryPage(groups: [.init(dayKey: "2026-11-01", date: date, entries: entries)], hasMore: false)
        let empty = SettingsAskHistoryPage(groups: [], hasMore: false)
        return SettingsView(hotkeyEnabled: false, missingPermissions: [], availableDevices: { [] }, selectedDeviceID: { nil },
            modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 },
            historyPage: { _ in page }, initialHistoryPage: page, askHistoryPage: { _ in empty },
            historySearchPage: { _, _ in page }, askHistorySearchPage: { _, _ in empty }, searchPrewarm: {}, initialAskHistoryPage: empty,
            historyDiagnostics: { _ in .init(archiveState: .transcribed, savedTextState: .present, selection: "nativefix-0", summary: "Saved transcript present", savedResult: "Synthetic", capturedAt: date, backend: nil, model: nil, detail: nil, warnings: []) },
            initialTab: .history, speechHistoryRoot: output.appendingPathComponent("absent-speech"),
            historyPlayback: SettingsAudioPlayback(start: { _ in XCTFail("No audio"); return false }, stop: {}, canPlay: { false }))
    }
    func testHistoryAtSupportedSizes() throws {
        try requireOutput()
        var measurements: [[String: Any]] = []
        for dark in [false, true] {
            for (width, height) in [(780.0,620.0),(920.0,760.0),(1280.0,880.0)] {
                let name = "history-\(Int(width))x\(Int(height))-\(dark ? "dark" : "light")"
                try withHost(history().environment(\.colorScheme, dark ? .dark : .light), size: CGSize(width: width, height: height), dark: dark) { host in
                    let all = scrolls(host)
                    let detail = try XCTUnwrap(all.last)
                    let list = try XCTUnwrap(all.dropLast().last)
                    measurements.append(["name":name, "detailScrollHeight":detail.contentView.bounds.height,
                        "listScrollHeight":list.contentView.bounds.height,
                        "detailScrollRect":NSStringFromRect(detail.convert(detail.bounds,to:host)),
                        "listScrollRect":NSStringFromRect(list.convert(list.bounds,to:host))])
                    try capture(host,name: name)
                    if !baseline {
                        XCTAssertGreaterThanOrEqual(detail.contentView.bounds.height, 180, name)
                        XCTAssertGreaterThanOrEqual(list.contentView.bounds.height, 4 * 48, name)
                    }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("geometry.json"))
    }
    func testMinimumWorkspaceKeepsFourRowsAndUsableDetailAcrossDividerTravel() {
        for fraction: CGFloat in [0.2,0.32,0.6,0.85] {
            let r = SettingsHistoryLayout.regions(size: CGSize(width: 607, height: 345), listFraction: fraction)
            XCTAssertTrue(r.sideBySide)
            XCTAssertGreaterThanOrEqual(r.list.width,220)
            XCTAssertGreaterThanOrEqual(r.list.height,4 * 48 + 40)
            XCTAssertGreaterThanOrEqual(r.detail.width,360)
            XCTAssertGreaterThanOrEqual(r.detail.height,240)
        }
    }
    func testScopeDelayedEndpoints() throws {
        try requireOutput()
        for dark in [false,true] {
            for scope in SettingsHistoryScope.allCases {
                let view = SettingsHistoryScopePicker(selection: .constant(scope)).padding(20)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor))
                try withHost(view, size: CGSize(width: 330,height: 90),dark:dark) { host in
                    // One 15-second endpoint for each scope; both appearances are captured.
                    settle(host, seconds: dark ? 15 : 0.3)
                    try capture(host,name:"scope-\(scope.rawValue)-\(dark ? "dark-15s" : "light")")
                }
            }
        }
    }
    func testProcessingBusySnapshots() throws {
        try requireOutput()
        for (name,recording,depth,disabledReason) in [
            ("queued","idle",1, nil as String?),
            ("recording","recording",0,"Finish recording before switching recognizers."),
            ("transcribing","transcribing",0,"Wait for transcription before switching recognizers.")
        ] {
            let health: [String:Any] = ["type":"health","recording_state":recording,"queue_depth":depth,
                "model_status":["configured_model":["name":"synthetic","installed":true],"residency":"loaded","configured_effort":"accurate"],
                "polish_controls":["model_polish":["source":"default","raw":NSNull(),"effective":"off"],
                    "outro_gate":["source":"default","raw":NSNull(),"effective":false],"smart_chunks":["source":"settings","raw":NSNull(),"effective":true]]]
            let recognizer=RecognizerPickerState(selected:.whisper,effective:.whisper,parakeet:.unloaded,whisper:.loaded,disabledReason:disabledReason)
            let view=ModelsSettingsView(state:ModelsSettingsState(healthEvent:health),onToggleProcessing:{ _,_ in XCTFail("No setting writes") },
                recognizerState:recognizer,onSelectRecognizer:{ _ in XCTFail("No engine switch") }).environment(\.colorScheme,.dark)
            try withHost(view,size:CGSize(width:650,height:620),dark:true) { host in try capture(host,name:"processing-busy-"+name) }
        }
    }
    func testParakeetToggleDisabledWithSavedValuePreserved() throws {
        try requireOutput()
        let health: [String:Any] = ["type":"health","recording_state":"idle","model_status":["configured_model":["name":"large-v3-turbo","size_bytes":100,"installed":true],"residency":"loaded","active_model":"large-v3-turbo","configured_effort":"accurate","active_effort":"accurate"],"polish_controls":["model_polish":["source":"default","raw":NSNull(),"effective":"off"],"outro_gate":["source":"default","raw":NSNull(),"effective":false],"smart_chunks":["source":"settings","raw":NSNull(),"effective":true]]]
        for dark in [false,true] {
            for engine in ["parakeet","whisper"] {
                let payload=RecognizerBindingTests.event(desired:engine,effective:engine)["recognizer_status"] as! [String:Any]
                let recognizer=RecognizerPickerState(snapshot: try XCTUnwrap(RecognizerStatusSnapshot(payload:payload)))
                let state=ModelsSettingsState(healthEvent:health)
                let row=try XCTUnwrap(ModelsSettingsView.processingRows(for:try XCTUnwrap(state.polishControls),recognizer:recognizer).first { $0.key == .smartChunks })
                XCTAssertTrue(row.isOn); XCTAssertEqual(row.lockedReason != nil,engine == "parakeet")
                let view=ModelsSettingsView(state:state,onToggleProcessing:{ _,_ in XCTFail("No settings writes") },recognizerState:recognizer,onSelectRecognizer:{_ in XCTFail("No engine switch")})
                    .environment(\.colorScheme,dark ? .dark : .light)
                try withHost(view,size:CGSize(width:650,height:620),dark:dark) { host in
                    try capture(host,name:"processing-\(engine)-\(dark ? "dark" : "light")")
                }
            }
        }
    }
}
