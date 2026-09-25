@testable import VoiceBarUI
import XCTest

/// R4/H1-a2: History loads through `SettingsArchiveIndex`; the app invalidates a re-transcribed entry before
/// reloading and releases the index when Settings closes. Memory stays flat across open/close cycles, and the
/// opt-in benchmark times a switch and a reopen on an ~11k-entry archive.
final class SettingsArchiveIndexWiringTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMemoryStaysFlatAcrossOpenCloseCycles() async throws {
        for hour in 0 ..< 400 {
            try writeDictation(day: "2026-09-\(10 + hour % 10)", id: "m\(hour)",
                               createdAt: "2026-09-\(10 + hour % 10)T00:00:00.000Z",
                               transcript: String(repeating: "word ", count: 60))
        }
        let index = SettingsArchiveIndex()
        var residentAfterCycle: [UInt64] = []
        for _ in 0 ..< 5 {
            _ = await index.dictationPage(from: root, limit: 400)
            _ = await index.askPage(from: root, limit: 400)
            await index.release()
            residentAfterCycle.append(Self.residentBytes())
        }
        let growth = Int64(residentAfterCycle[4]) - Int64(residentAfterCycle[1])
        XCTAssertLessThan(growth, 8 * 1024 * 1024, "resident memory must not grow per Settings open/close cycle")
        let cached = await index.cachedRootCount()
        XCTAssertEqual(cached, 0)
    }

    // MARK: - Wiring pins (the app target is not importable from these tests)

    func testHistoryLoadsGoThroughTheSharedIndexByDefault() throws {
        let source = try sourceFile("VoiceBarUI/SettingsView.swift")

        XCTAssertTrue(source.contains("public let historyPage: @Sendable (Int) async -> SettingsHistoryPage"))
        XCTAssertTrue(source.contains("public let askHistoryPage: @Sendable (Int) async -> SettingsAskHistoryPage"))
        XCTAssertTrue(source.contains("await SettingsArchiveIndex.shared.dictationPage(limit: limit)"))
        XCTAssertTrue(source.contains("await SettingsArchiveIndex.shared.askPage(limit: limit)"))
        XCTAssertFalse(source.contains("= { limit in\n            SettingsHistoryArchive.loadPage(limit: limit)"))
        XCTAssertEqual(source.components(separatedBy: "let page = await loader(limit)").count - 1, 2)
    }

    func testTheAppInvalidatesBeforeReloadingAndReleasesTheIndexWhenSettingsCloses() throws {
        let app = try sourceFile("VoiceBar/VoiceBarApp.swift")

        XCTAssertTrue(app
            .contains("historyPage: { limit in await SettingsArchiveIndex.shared.dictationPage(limit: limit) }"))
        XCTAssertTrue(app.contains("await SettingsArchiveIndex.shared.invalidate(entryPath: path)"))
        let invalidate = try XCTUnwrap(app.range(of: "await SettingsArchiveIndex.shared.invalidate(entryPath: path)"))
        let post = try XCTUnwrap(app
            .range(of: "NotificationCenter.default.post(name: .voiceBarHistoryArchiveDidChange"))
        XCTAssertLessThan(invalidate.lowerBound, post.lowerBound, "the reload must not read the stale entry")
        XCTAssertTrue(app.contains("window.delegate = self"))
        XCTAssertTrue(app.contains("await SettingsArchiveIndex.shared.release()"))
    }

    private func sourceFile(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources").appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Timing evidence (opt-in)

    /// Kickoff target: a Recording↔Ask switch and a History reopen under 300 ms on a ~11k-entry archive.
    /// Synthetic 11k archive always; the real archive read-only (counts only) when it exists.
    func testSwitchAndReopenTimingOnAnElevenThousandEntryArchive() async throws {
        guard ProcessInfo.processInfo.environment["VOICELAYER_SETTINGS_PERF_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOICELAYER_SETTINGS_PERF_BENCHMARK=1 to run timing evidence")
        }
        for index in 0 ..< 11000 {
            let day = String(format: "2026-%02d-%02d", 1 + index / 3000 % 9, 1 + index % 28)
            let createdAt = "\(day)T\(String(format: "%02d", index % 24)):00:00.000Z"
            if index % 10 == 0 {
                try writeAsk(
                    day: day,
                    id: String(format: "q%05d", index),
                    createdAt: createdAt,
                    question: "Question \(index)?"
                )
            } else {
                try writeDictation(day: day, id: String(format: "d%05d", index), createdAt: createdAt,
                                   transcript: "Synthetic dictation \(index)")
            }
        }
        try await report(root: root, label: "synthetic")
        let real = SettingsHistoryArchive.defaultRoot
        if FileManager.default.fileExists(atPath: real.path) {
            try await report(root: real, label: "real-readonly")
        }
    }

    private func report(root: URL, label: String) async throws {
        func ms(_ start: UInt64) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        let index = SettingsArchiveIndex()
        var start = DispatchTime.now().uptimeNanoseconds
        let first = await index.dictationPage(from: root, limit: 100)
        let coldDictations = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        let asks = await index.askPage(from: root, limit: 100)
        let firstAskSwitch = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        _ = await index.dictationPage(from: root, limit: 100)
        let switchBack = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        _ = await index.askPage(from: root, limit: 100)
        let warmAskSwitch = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        _ = await index.dictationPage(from: root, limit: 100)
        let reopen = ms(start)
        start = DispatchTime.now().uptimeNanoseconds
        _ = SettingsAskHistoryArchive.loadPage(from: root, limit: 100)
        let scannerAsk = ms(start)
        print(String(
            format: "H1A_INDEX %@ dictations=%d asks=%d cold_first_page_ms=%.1f first_ask_switch_ms=%.1f "
                + "switch_back_ms=%.1f warm_ask_switch_ms=%.1f reopen_ms=%.1f scanner_ask_page_ms=%.1f",
            label, first.loadedEntryCount, asks.loadedEntryCount, coldDictations, firstAskSwitch,
            switchBack, warmAskSwitch, reopen, scannerAsk
        ))
        XCTAssertLessThan(switchBack, 300)
        XCTAssertLessThan(warmAskSwitch, 300)
        XCTAssertLessThan(reopen, 300)
    }

    // MARK: - Fixtures

    private func writeDictation(day: String, id: String, createdAt: String, transcript: String) throws {
        let dir = root.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try transcript.write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id": "\#(id)", "created_at": "\#(createdAt)", "duration_ms": 1200}"#
            .write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    private func writeAsk(day: String, id: String, createdAt: String, question: String) throws {
        let dir = root.appendingPathComponent(day).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3]).write(to: dir.appendingPathComponent("audio.wav"))
        try question.write(to: dir.appendingPathComponent("agent-transcript.txt"), atomically: true, encoding: .utf8)
        try "an answer".write(
            to: dir.appendingPathComponent("voicelayer-transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"id": "\#(id)", "created_at": "\#(createdAt)", "source": "\#(SettingsArchiveSchema.askSourceValue)"}"#
            .write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
