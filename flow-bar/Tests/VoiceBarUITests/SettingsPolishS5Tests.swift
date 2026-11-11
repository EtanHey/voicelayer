import AppKit
import OffscreenTestSupport
import SwiftUI
@testable import VoiceBarUI
import Vision
import XCTest

/// Synthetic, production-view renders. No resident app, microphone, permissions or native-glass proof.
@MainActor
final class SettingsPolishS5Tests: XCTestCase {
    static let output = "/Users/happycampr/Gits/voicelayer/docs.local/2.4-lanes/c7/S5"
    static var phase: String { ProcessInfo.processInfo.environment["S5_PHASE"] ?? "after" }
    static func pane(_ tab: SettingsTab) -> SettingsView {
        if tab == .speech || tab == .dictionary { return SettingsDrawerLaneS3Tests.pane(tab) }
        return SettingsDrawerLaneSSnapshotTests.pane(tab, advanced: true)
    }
    static func drawer(_ tab: SettingsTab, light: Bool = false, updates: NotchUpdateController? = nil) -> some View {
        NotchSettingsDrawer(selectedTab: tab, appearance: light ? .light : .dark,
            context: .init(updates: updates, pane: { tab, _ in AnyView(pane(tab).notchDrawerPane(tab)) }), onSelectTab: { _ in })
    }
    static func render(_ view: some View, width: CGFloat = 420, height: CGFloat = 1100,
                       light: Bool = false, name: String? = nil, scrollOffset: CGFloat? = nil) throws -> NSBitmapImageRep {
        let framed = VStack(spacing: 0) {
            view.frame(width: width, height: height)
            Color.clear.frame(width: width, height: 24)
        }.background(light ? Color(white: 0.95) : Color(white: 0.16))
            .overlay(alignment: .bottom) {
                Text(width < 300 ? "M1 synthetic · no native glass" : "M1 synthetic · macOS 26: native glass unavailable")
                    .font(.system(size: width < 300 ? 9 : 10))
                    .foregroundStyle(light ? Color.black : Color.white)
                    .frame(width: width, height: 24)
                    .background(light ? Color(white: 0.95) : Color(white: 0.16))
            }
            .environment(\.colorScheme, light ? .light : .dark)
        let host = NSHostingView(rootView: framed)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height + 24),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        host.appearance = window.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        VLOrderTestWindow(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let offset = scrollOffset, let scroll = SettingsDrawerLaneSSnapshotTests.scrollViews(in: host).first,
           let document = scroll.documentView {
            let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? min(offset, end) : end - min(offset, end)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        let bitmap = try EtanQA0510Tests.fixedScaleBitmap(host)
        if let name {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(phase)-\(name).png"))
        }
        return bitmap
    }
    static func ocr(_ bitmap: NSBitmapImageRep) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
            .filter { !$0.hasPrefix("m1 synthetic") }
    }
    func testCaptureAllChangedPanes() async throws {
        let updates = await SettingsDrawerLaneSSnapshotTests.updates()
        for tab in [SettingsTab.general, .transcription, .speech, .dictionary] {
            _ = try Self.render(Self.drawer(tab, updates: tab == .general ? updates : nil), height: tab == .general ? 1500 : 1100, name: "\(tab.title.lowercased())-drawer-dark")
            _ = try Self.render(Self.pane(tab), width: 780, height: tab == .general ? 1500 : 1100, name: "\(tab.title.lowercased())-window-dark")
        }
        for tab in [SettingsTab.speech, .dictionary] {
            _ = try Self.render(Self.drawer(tab), height: 470, name: "\(tab.title.lowercased())-scrolled", scrollOffset: 150)
        }
        _ = try Self.render(Self.drawer(.speech).environment(\.settingsHoverPreview,
            SettingsHoverPreview(lockedReasons: true)), name: "speech-hover")
        _ = try Self.render(Self.drawer(.transcription, light: true), light: true, name: "transcription-drawer-light")
        _ = try Self.render(Self.pane(.transcription), width: 780, light: true, name: "transcription-window-light")
    }
    func testDictionaryLoadingAndEmptyStatesUseCompactRows() throws {
        for loaded in [false, true] {
            let preview = STTVocabularyPreview(updatedAt: nil, entries: [])
            let loadingGate = DispatchSemaphore(value: 0)
            defer { loadingGate.signal() }
            let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
                selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {},
                vocabularyPreview: { if !loaded { loadingGate.wait() }; return preview },
                vocabularyRevision: { 0 }, initialTab: .dictionary,
                initialDictionaryPreview: loaded ? preview : nil)
            let lines = try Self.ocr(Self.render(pane.notchDrawerPane(.dictionary), height: 470,
                name: loaded ? "dictionary-empty" : "dictionary-loading"))
            XCTAssertTrue(lines.contains { $0.contains(loaded ? "no terms yet" : "loading") })
            XCTAssertEqual(lines.filter { $0.contains("loading") }.count, loaded ? 0 : 1,
                           "One known Loading state; Included terms must not duplicate it")
            XCTAssertFalse(lines.contains { $0 == "built in" })
        }
    }

    func testWindowWrapsTheEntireLongMicrophoneName() throws {
        let name = "Studio microphone with a deliberately long descriptive device name that continues through multiple lines and ends in Cedar"
        let image = try Self.render(SettingsRowLabel(title: name, description: "Connected"), width: 180, height: 240,
                                    name: "long-device-window")
        let lines = try Self.ocr(image)
        XCTAssertTrue(lines.contains { $0.contains("cedar") }, "Full device name must paint: \(lines)")
    }
    func testEmptyMicrophoneListDoesNotOfferReordering() throws {
        let pane = SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices: { [] },
            selectedDeviceID: { nil }, modelsStatus: { .loading }, onRefreshModelsStatus: {}, vocabularyRevision: { 0 }, initialTab: .general)
        let lines = try Self.ocr(Self.render(pane.notchDrawerPane(.general), name: "empty-mics"))
        XCTAssertTrue(lines.contains { $0.contains("no known input") })
        XCTAssertFalse(lines.contains { $0.contains("drag to") }, "Nothing exists to reorder: \(lines)")
    }
    func testBothProfilesExplainWhenChangesApply() throws {
        let lines = try Self.ocr(Self.render(Self.drawer(.speech)))
        XCTAssertEqual(lines.filter { $0.contains("changes apply") }.count, 2, "Shared rule belongs to both profiles: \(lines)")
    }
    func testSpeechShowsAControlInsteadOfTelemetry() throws {
        let lines = try Self.ocr(Self.render(Self.drawer(.speech)))
        XCTAssertTrue(lines.contains { $0.contains("short / long split") })
        XCTAssertFalse(lines.contains { $0.contains("last reported cutoff") || $0.contains("first sound after") })
        XCTAssertEqual(lines.filter { $0.contains("unavailable") }.count, 1)
    }
    func testLockedToggleHasVisibleStateAtRest() throws {
        let lines = try Self.ocr(Self.render(Self.drawer(.transcription)))
        XCTAssertTrue(lines.contains { $0.contains("locked") }, "A forced Off must not read as a choice: \(lines)")
    }
    func testLongVariantsKeepOneRowAndShowAnOverflowCount() throws {
        let entry = STTDictionaryEntry(canonical: "Kubernetes", variants: ["cooper netties", "kuber nets", "coober net ease", "kube er net is"])
        let lines = try Self.ocr(Self.render(SettingsView.dictionaryTermLine(entry), width: 280, height: 100,
                                            name: "long-variants"))
        XCTAssertTrue(lines.contains { $0.contains("+3 more") }, "Overflow count must remain visible: \(lines)")
    }
    func testIncludedSummaryUsesNoChipSamples() throws {
        let lines = try Self.ocr(Self.render(Self.drawer(.dictionary)))
        XCTAssertFalse(lines.contains { $0 == "github" || $0 == "json" || $0 == "npm" || $0 == "macos" },
                       "Collapsed Included terms should show a counted header, not chip samples: \(lines)")
    }
}
