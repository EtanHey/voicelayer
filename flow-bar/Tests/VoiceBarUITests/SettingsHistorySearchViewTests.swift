import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

/// H1-c: a search field per History scope. Matching and paging are proven on the index
/// (SettingsArchiveIndexTests); these pin the count label, and that each scope sends its trimmed query to its own
/// search loader, plus the light/dark shots.
@MainActor
final class SettingsHistorySearchViewTests: XCTestCase {
    func testTheCountLabelSaysSearchingWhileASearchLoads() {
        XCTAssertEqual(
            SettingsView.historyCountLabel(0, hasMore: false, noun: "transcripts", searching: true, loading: true),
            "Searching…"
        )
        XCTAssertEqual(
            SettingsView.historyCountLabel(40, hasMore: false, noun: "transcripts", searching: false, loading: true),
            "40 transcripts"
        )
    }

    func testTheCountLabelSaysMatchesWhileSearching() {
        XCTAssertEqual(SettingsView.historyCountLabel(12, hasMore: false, noun: "transcripts", searching: false),
                       "12 transcripts")
        XCTAssertEqual(SettingsView.historyCountLabel(3, hasMore: false, noun: "transcripts", searching: true),
                       "3 matches")
        XCTAssertEqual(SettingsView.historyCountLabel(1, hasMore: false, noun: "exchanges", searching: true),
                       "1 match")
        XCTAssertEqual(SettingsView.historyCountLabel(100, hasMore: true, noun: "exchanges", searching: true),
                       "100+ matches")
    }

    func testDictationsSendTheTrimmedQueryToTheSearchLoader() async {
        let log = QueryLog()
        let host = hostSettings(
            makeView(log: log, scope: .recording, historySearch: "  notch  ")
        )
        let searched = await settle { log.events.contains("dictations-search:notch") }
        XCTAssertTrue(searched, "events: \(log.events)")
        XCTAssertFalse(log.events.contains("dictations-page"), "a search never loads the unfiltered page")
        host.contentViewController = nil
    }

    func testAskSendsTheTrimmedQueryToItsOwnSearchLoader() async {
        let log = QueryLog()
        let host = hostSettings(
            makeView(log: log, scope: .ask, askSearch: " timeout ")
        )
        let searched = await settle { log.events.contains("ask-search:timeout") }
        XCTAssertTrue(searched, "events: \(log.events)")
        XCTAssertFalse(log.events.contains("ask-page"))
        host.contentViewController = nil
    }

    func testABlankQueryLoadsTheUnfilteredPage() async {
        let log = QueryLog()
        let host = hostSettings(makeView(log: log, scope: .recording, historySearch: "   "))
        let loaded = await settle { log.events.contains("dictations-page") }
        XCTAssertTrue(loaded, "events: \(log.events)")
        XCTAssertFalse(log.events.contains { $0.hasPrefix("dictations-search") })
        host.contentViewController = nil
    }

    func testWritesSearchArtifactsInLightAndDark() throws {
        try VisualArtifactTestPolicy.requireRegeneration()
        let outputDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs.local/design/2026-09-25-h1c-search")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let dictationMatches = SettingsHistoryPage(groups: [
            SettingsHistoryDayGroup(dayKey: "2026-09-25", date: Self.date(hour: 0), entries: [
                SettingsHistoryEntry(
                    id: "/tmp/h1c-a/audio.wav", dayKey: "2026-09-25", recordingID: "a",
                    createdAt: Self.date(hour: 9, minute: 30),
                    transcript: "The notch glass looks off in dark mode.",
                    audioPath: URL(fileURLWithPath: "/tmp/h1c-a/audio.wav"), durationMs: 6200
                ),
                SettingsHistoryEntry(
                    id: "/tmp/h1c-b/audio.wav", dayKey: "2026-09-25", recordingID: "b",
                    createdAt: Self.date(hour: 8, minute: 5),
                    transcript: "Deploy the notch build to the M1 after lunch.",
                    audioPath: URL(fileURLWithPath: "/tmp/h1c-b/audio.wav"), durationMs: 4100
                ),
            ]),
        ], hasMore: false)
        let askMatches = SettingsAskHistoryPage(groups: [
            SettingsAskHistoryDayGroup(dayKey: "2026-09-25", date: Self.date(hour: 0), entries: [
                SettingsAskHistoryEntry(
                    id: "/tmp/h1c-q", dayKey: "2026-09-25", askID: "q",
                    createdAt: Self.date(hour: 10, minute: 15),
                    questionText: "Raise the silence timeout to five seconds?",
                    questionAudioPath: URL(fileURLWithPath: "/tmp/h1c-q/agent-audio.mp3"),
                    responseTranscript: "Yes, but only when I'm mid-sentence.",
                    responseAudioPath: URL(fileURLWithPath: "/tmp/h1c-q/audio.wav")
                ),
            ]),
        ], hasMore: false)
        let cases: [(String, SettingsHistoryScope, String, String, Bool)] = [
            ("dictations-notch", .recording, "notch", "", false),
            ("ask-timeout", .ask, "", "timeout", false),
            ("dictations-no-match", .recording, "kubernetes", "", true),
        ]
        for (name, scope, historyQuery, askQuery, empty) in cases {
            for (appearance, appearanceName) in [
                (NSAppearance(named: .aqua), "light"),
                (NSAppearance(named: .darkAqua), "dark"),
            ] {
                let view = SettingsView(
                    hotkeyEnabled: true,
                    missingPermissions: [],
                    availableDevices: { [] },
                    selectedDeviceID: { nil },
                    onSelectDevice: { _ in },
                    modelsStatus: { .loading },
                    onRefreshModelsStatus: {},
                    vocabularyRevision: { 0 },
                    initialHistoryPage: empty ? SettingsHistoryPage(groups: [], hasMore: false) : dictationMatches,
                    askHistoryPage: { _ in askMatches },
                    historySearchPage: { _, _ in
                        empty ? SettingsHistoryPage(groups: [], hasMore: false) : dictationMatches
                    },
                    askHistorySearchPage: { _, _ in askMatches },
                    initialAskHistoryPage: askMatches,
                    initialTab: .history,
                    initialHistoryScope: scope,
                    initialHistorySearch: historyQuery,
                    initialAskHistorySearch: askQuery
                )
                let host = NSHostingView(rootView: view.frame(width: 900, height: 620))
                host.appearance = appearance
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
                // The search result lands asynchronously; shoot after it has, not the loading state.
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let landed = expectation(description: "search applied")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    landed.fulfill()
                }
                wait(for: [landed], timeout: 5)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                bitmap.size = host.bounds.size
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: outputDirectory.appendingPathComponent("\(name)-\(appearanceName).png"))
                window.contentView = nil
            }
        }
    }

    private static func date(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 9
        components.day = 25
        components.hour = hour
        components.minute = minute
        return components.date ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - Helpers

    private func makeView(
        log: QueryLog,
        scope: SettingsHistoryScope,
        historySearch: String = "",
        askSearch: String = ""
    ) -> SettingsView {
        SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            onSelectDevice: { _ in },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyRevision: { 0 },
            historyPage: { _ in
                log.append("dictations-page")
                return SettingsHistoryPage(groups: [], hasMore: false)
            },
            askHistoryPage: { _ in
                log.append("ask-page")
                return SettingsAskHistoryPage(groups: [], hasMore: false)
            },
            historySearchPage: { _, query in
                log.append("dictations-search:\(query)")
                return SettingsHistoryPage(groups: [], hasMore: false)
            },
            askHistorySearchPage: { _, query in
                log.append("ask-search:\(query)")
                return SettingsAskHistoryPage(groups: [], hasMore: false)
            },
            initialTab: .history,
            initialHistoryScope: scope,
            initialHistorySearch: historySearch,
            initialAskHistorySearch: askSearch
        )
    }

    private func hostSettings(_ view: SettingsView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }
}

private final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }
}
