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
}
