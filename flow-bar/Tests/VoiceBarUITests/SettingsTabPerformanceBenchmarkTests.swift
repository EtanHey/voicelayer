import AppKit
import Foundation
import SwiftUI
@testable import VoiceBarUI
import XCTest

final class SettingsTabPerformanceBenchmarkTests: XCTestCase {
    @MainActor
    func testDictionaryHostMountDoesNotWaitForVocabularyProvider() {
        let warmHost = NSHostingView(rootView: Text("Warm AppKit host"))
        warmHost.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
        warmHost.layoutSubtreeIfNeeded()
        let loaded = expectation(description: "background vocabulary snapshot")
        let view = SettingsView(
            hotkeyEnabled: true, missingPermissions: [],
            availableDevices: { [] }, selectedDeviceID: { nil }, onSelectDevice: { _ in },
            modelsStatus: { .loading }, onRefreshModelsStatus: {},
            vocabularyPreview: {
                XCTAssertFalse(Thread.isMainThread, "Vocabulary processing must leave the main thread")
                Thread.sleep(forTimeInterval: 0.8)
                loaded.fulfill()
                return STTVocabularyPreview(updatedAt: nil, entries: [])
            },
            vocabularyRevision: { 0 }, initialTab: .dictionary
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
        let start = DispatchTime.now().uptimeNanoseconds
        host.layoutSubtreeIfNeeded()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "P08_DICTIONARY host_mount_ms=%.3f", elapsed))
        XCTAssertLessThan(elapsed, 150)
        wait(for: [loaded], timeout: 2)
    }

    @MainActor
    func testDictionaryOpensWithoutWaitingForLargeVocabularySnapshot() {
        let entries = (0 ..< 300).map { STTDictionaryEntry(canonical: "Personal \($0)", variants: []) }
        let display = entries.map { STTDictionaryDisplayEntry(source: "personal", entry: $0) }
            + (0 ..< 120).map {
                STTDictionaryDisplayEntry(
                    source: "bundled",
                    entry: STTDictionaryEntry(canonical: "Built in \($0)", variants: [])
                )
            }
        let preview = STTVocabularyPreview(updatedAt: nil, entries: entries, displayEntries: display)
        let start = DispatchTime.now().uptimeNanoseconds
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            onSelectDevice: { _ in },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyPreview: {
                Thread.sleep(forTimeInterval: 0.2)
                return preview
            },
            vocabularyRevision: { 0 },
            initialTab: .dictionary
        )
        _ = view.body
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "P08_DICTIONARY first_body_ms=%.3f personal=300 bundled=120", elapsed))
        XCTAssertLessThan(elapsed, 150, "Dictionary construction and first body must stay interactive")
    }

    @MainActor
    func testSyntheticSettingsTabBenchmark() throws {
        guard ProcessInfo.processInfo.environment["VOICELAYER_SETTINGS_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOICELAYER_SETTINGS_PERF_BENCHMARK=1 to run timing evidence")
        }
        countVocabularyProviderEvaluations()
        for count in [512, 4096] {
            let terms = (0 ..< count).map { "Term \($0)" }
            let aliases = (0 ..< count).map {
                STTVocabularyAliasPreview(from: "Variant \($0)", to: "Term \($0)")
            }
            var preview = STTVocabularyPreview(updatedAt: nil, entries: [])
            XCTAssertEqual(metric("snapshot_build", count) { _ in
                preview = STTVocabularyPreview(updatedAt: nil, promptTerms: terms, aliases: aliases)
                return preview.entries.count
            }, count)
            XCTAssertEqual(metric("empty_projection", count) { _ in
                preview.filteredEntries(matching: "").count
            }, count)
            XCTAssertGreaterThan(metric("search_projection", count) { iteration in
                preview.filteredEntries(matching: query(iteration)).count
            }, 0)

            var index = STTDictionaryIndex(entries: [])
            XCTAssertEqual(metric("index_build", count) { _ in
                index = STTDictionaryIndex(entries: preview.entries)
                return index.sortedEntries.count
            }, count)
            XCTAssertEqual(metric("bounded_empty_page_input", count) { _ in
                index.page(matching: "", limit: 100).entries.count
            }, min(100, count))
            let pageCount = metric("bounded_search_page_input", count) { iteration in
                index.page(matching: query(iteration), limit: 100).entries.count
            }
            XCTAssertGreaterThan(pageCount, 0)
            XCTAssertLessThanOrEqual(pageCount, 100)
        }

        for count in [1000, 5000] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicelayer-settings-perf-\(UUID().uuidString)")
            try makeSyntheticHistory(root: root, entryCount: count)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(metric("archive_page_completion", count, surface: "history", samples: 20) { _ in
                SettingsHistoryArchive.loadPage(from: root).loadedEntryCount
            }, SettingsHistoryArchive.defaultPageSize)
        }
    }

    @MainActor
    private func countVocabularyProviderEvaluations() {
        let preview = STTVocabularyPreview(
            updatedAt: nil,
            entries: [STTDictionaryEntry(canonical: "VoiceLayer", variants: ["voice lair"])]
        )
        var snapshotCalls = 0
        var revisionCalls = 0
        let view = SettingsView(
            hotkeyEnabled: true,
            missingPermissions: [],
            availableDevices: { [] },
            selectedDeviceID: { nil },
            onSelectDevice: { _ in },
            modelsStatus: { .loading },
            onRefreshModelsStatus: {},
            vocabularyPreview: { snapshotCalls += 1
                return preview
            },
            vocabularyRevision: { revisionCalls += 1
                return 0
            }
        )
        XCTAssertEqual(snapshotCalls, 0)
        _ = view.body
        _ = view.body
        XCTAssertEqual(snapshotCalls, 0)
        XCTAssertEqual(revisionCalls, 2)
        print("SETTINGS_PERF surface=dictionary phase=vocabulary_provider_calls "
            + "snapshot_init_calls=0 snapshot_calls_per_body=0 revision_calls_per_body=1 body_passes=2")
    }

    private func query(_ iteration: Int) -> String {
        iteration.isMultiple(of: 2) ? "term 4" : "variant 3"
    }

    @discardableResult
    private func metric(
        _ phase: String,
        _ scale: Int,
        surface: String = "dictionary",
        samples: Int = 30,
        operation: (Int) -> Int
    ) -> Int {
        var result = 0
        let firstSample = timed { result = operation(0) }
        let repeated = (0 ..< samples).map { iteration in timed { result = operation(iteration) } }
        let sorted = repeated.sorted()
        let p50 = sorted[Int((Double(samples - 1) * 0.50).rounded(.up))]
        let p95 = sorted[Int((Double(samples - 1) * 0.95).rounded(.up))]
        print(String(
            format: "SETTINGS_PERF surface=%@ phase=%@ scale=%d first_sample_ms=%.3f repeated_p50_ms=%.3f repeated_p95_ms=%.3f samples=%d",
            surface, phase, scale, firstSample, p50, p95, samples
        ))
        return result
    }

    private func timed(_ operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func makeSyntheticHistory(root: URL, entryCount: Int) throws {
        let manager = FileManager.default
        let day = root.appendingPathComponent("2026-09-22")
        try manager.createDirectory(at: day, withIntermediateDirectories: true)
        for index in 0 ..< entryCount {
            let id = String(format: "%08d", entryCount - index)
            let entry = day.appendingPathComponent(id)
            try manager.createDirectory(at: entry, withIntermediateDirectories: false)
            try Data([0x52, 0x49, 0x46, 0x46]).write(to: entry.appendingPathComponent("audio.wav"))
            try Data("Synthetic retained transcript".utf8)
                .write(to: entry.appendingPathComponent("voicelayer-transcript.txt"))
            try Data("{\"id\":\"\(id)\",\"created_at\":\"2026-09-22T12:00:00.000Z\",\"source\":\"dictation\"}".utf8)
                .write(to: entry.appendingPathComponent("metadata.json"))
        }
    }
}
