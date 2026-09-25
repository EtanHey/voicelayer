import Foundation
@testable import VoiceBarUI
import XCTest

/// H1-c: the History search query. Matching, paging and freshness are proven on the index
/// (SettingsArchiveIndexTests); the view is in SettingsHistorySearchViewTests.
final class SettingsHistorySearchTests: XCTestCase {
    func testTheQueryIsTrimmedAndBlankIsNoSearch() {
        XCTAssertEqual(SettingsHistorySearch("  notch \n").query, "notch")
        XCTAssertTrue(SettingsHistorySearch(" notch").isActive)
        XCTAssertFalse(SettingsHistorySearch(" \n\t ").isActive)
        XCTAssertTrue(SettingsHistorySearch("").matches("anything"))
        XCTAssertTrue(SettingsHistorySearch("CAFE").matches("no", "the Café"))
        XCTAssertFalse(SettingsHistorySearch("notch").matches("pill", "glass"))
    }

    /// While a search runs, the count is unknown: "0 matches" next to a spinner reads as a finished empty result.
    // MARK: - Evidence (opt-in)

    /// A query that matches nothing walks (and decodes) the whole archive: the worst case for a first search.
    /// The real archive is read read-only, counts only.
    func testSearchTimingOnTheRealArchive() async throws {
        guard ProcessInfo.processInfo.environment["VOICELAYER_SETTINGS_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOICELAYER_SETTINGS_PERF_BENCHMARK=1 to run timing evidence")
        }
        let root = SettingsHistoryArchive.defaultRoot
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("no archive on this machine") }
        func ms(_ start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let index = SettingsArchiveIndex()
        var start = DispatchTime.now().uptimeNanoseconds
        let cold = await index.dictationPage(from: root, limit: 100, matching: "zq-no-such-word-zq")
        let coldMiss = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        let common = await index.dictationPage(from: root, limit: 100, matching: "the")
        let warmCommon = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        _ = await index.dictationPage(from: root, limit: 100, matching: "zq-other-miss-zq")
        let warmMiss = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        let asks = await index.askPage(from: root, limit: 100, matching: "zq-no-such-word-zq")
        let coldAskMiss = ms(start)
        print(String(
            format: "H1C_SEARCH real-readonly miss_count=%d common_count=%d ask_miss_count=%d "
                + "cold_full_walk_miss_ms=%.1f warm_common_ms=%.1f warm_full_miss_ms=%.1f cold_ask_full_miss_ms=%.1f",
            cold.loadedEntryCount, common.loadedEntryCount, asks.loadedEntryCount,
            coldMiss, warmCommon, warmMiss, coldAskMiss
        ))
        XCTAssertLessThan(warmMiss, 300, "once each entry's text is cached, searching the whole archive is memory-only")
    }

    /// Lead add-on target: close → release → reopen → the first page and the Ask prefetch → prewarm → the first
    /// search < 300 ms. Synthetic 11k archive always; the real archive read-only (counts only) when present.
    func testFirstSearchAfterPrewarmOnAnElevenThousandEntryArchive() async throws {
        guard ProcessInfo.processInfo.environment["VOICELAYER_SETTINGS_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOICELAYER_SETTINGS_PERF_BENCHMARK=1 to run timing evidence")
        }
        let synthetic = FileManager.default.temporaryDirectory.appendingPathComponent("prewarm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: synthetic) }
        for index in 0 ..< 11000 {
            let day = String(format: "2026-%02d-%02d", 1 + index / 3000 % 9, 1 + index % 28)
            let dir = synthetic.appendingPathComponent(day).appendingPathComponent(String(format: "e%05d", index))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0]).write(to: dir.appendingPathComponent("audio.wav"))
            try "Synthetic dictation \(index) about the notch".write(
                to: dir.appendingPathComponent("voicelayer-transcript.txt"), atomically: false, encoding: .utf8
            )
            try #"{"id": "e\#(index)", "created_at": "\#(day)T00:00:00.000Z"}"#
                .write(to: dir.appendingPathComponent("metadata.json"), atomically: false, encoding: .utf8)
        }
        var roots = [("synthetic", synthetic)]
        if FileManager.default.fileExists(atPath: SettingsHistoryArchive.defaultRoot.path) {
            roots.append(("real-readonly", SettingsHistoryArchive.defaultRoot))
        }
        for (label, root) in roots {
            func ms(_ start: UInt64) -> Double {
                Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            let index = SettingsArchiveIndex()
            _ = await index.dictationPage(from: root, limit: 100)
            await index.release()
            // Reopen: first page, Ask prefetch, then the prewarm, as the view runs them.
            _ = await index.dictationPage(from: root, limit: 100)
            _ = await index.askPage(from: root, limit: 100)
            var start = DispatchTime.now().uptimeNanoseconds
            await index.prewarmSearchText(from: root)
            let prewarm = ms(start)
            start = DispatchTime.now().uptimeNanoseconds
            let miss = await index.dictationPage(from: root, limit: 100, matching: "zq-no-such-word-zq")
            let firstSearch = ms(start)
            start = DispatchTime.now().uptimeNanoseconds
            _ = await index.askPage(from: root, limit: 100, matching: "zq-no-such-word-zq")
            let firstAskSearch = ms(start)
            let cached = await index.cachedSearchTextCount()
            print(String(
                format: "H1C_PREWARM %@ entries=%d misses=%d prewarm_ms=%.1f first_search_ms=%.1f first_ask_search_ms=%.1f",
                label, cached, miss.loadedEntryCount, prewarm, firstSearch, firstAskSearch
            ))
            XCTAssertLessThan(firstSearch, 300, "\(label): the first search after a prewarm")
            XCTAssertLessThan(firstAskSearch, 300, "\(label): the first Ask search after a prewarm")
        }
    }
}
