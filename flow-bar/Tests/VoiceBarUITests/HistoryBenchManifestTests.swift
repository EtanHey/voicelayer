import Foundation
@testable import VoiceBarUI
import XCTest

/// E review r1, M2: a malformed shape manifest could make the synthetic-archive builder write outside its own
/// temporary root (e.g. into a real archive). Every day/entry must be one safe path component, or nothing is written.
@MainActor
final class HistoryBenchManifestTests: XCTestCase {
    private var container: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-bench-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let container { try? FileManager.default.removeItem(at: container) }
    }

    private func manifest(_ rows: [String]) throws -> String {
        let url = container.appendingPathComponent("shape-\(UUID().uuidString).tsv")
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testAManifestCannotWriteOutsideItsSyntheticRoot() throws {
        let root = container.appendingPathComponent("synthetic", isDirectory: true)
        let outside = container.appendingPathComponent("outside/e", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("voicelayer-transcript.txt")
        try "SENTINEL".write(to: sentinel, atomically: true, encoding: .utf8)

        for row in [
            "../outside\te\tvoicebar\t100\t1000\t1\t0",
            "2026-09-27\t../../outside/e\tvoicebar\t100\t1000\t1\t0",
            "2026-09-27\t/abs\tvoicebar\t100\t1000\t1\t0",
            "2026-09-27\t..\tvoicebar\t100\t1000\t1\t0",
            "not-a-day\te\tvoicebar\t100\t1000\t1\t0",
        ] {
            XCTAssertThrowsError(
                try HistoryOpenAndScopeSwitchBenchmarkTests.buildSyntheticArchive(shape: manifest([row]), root: root),
                row
            )
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "SENTINEL", "nothing outside was written")
    }

    func testAValidManifestBuildsTheDeclaredTranscriptLength() throws {
        let root = container.appendingPathComponent("synthetic", isDirectory: true)
        let path = try manifest(["2026-09-27\t2026-09-27T10-00-00-000Z-abcd1234\tvoicebar\t20000\t1000\t1\t0"])

        XCTAssertEqual(try HistoryOpenAndScopeSwitchBenchmarkTests.buildSyntheticArchive(shape: path, root: root), 1)
        let transcript = try String(contentsOf: root.appendingPathComponent(
            "2026-09-27/2026-09-27T10-00-00-000Z-abcd1234/voicelayer-transcript.txt"
        ), encoding: .utf8)
        XCTAssertEqual(transcript.count, 20000, "CodeRabbit 4115144414: the declared length, not a capped one")
    }
}
