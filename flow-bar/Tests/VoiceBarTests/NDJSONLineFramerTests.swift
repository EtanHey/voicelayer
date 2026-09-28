@testable import VoiceBar
import XCTest

/// UXP-1: socket reads are split at arbitrary byte offsets, so the framer must decode whole lines only.
/// UXP-1 r2: a line may not grow without bound, and every byte is scanned for a newline once.
final class NDJSONLineFramerTests: XCTestCase {
    func testALineSplitInsideAMultiByteCharacterDecodesWhole() throws {
        var framer = NDJSONLineFramer()
        let bytes = Array(#"{"v":"אבג — ok"}"#.utf8) + [0x0A]
        let split = try XCTUnwrap(bytes.firstIndex(of: 0xD7)) + 1

        XCTAssertEqual(framer.append(bytes[..<split]).lines, [])
        XCTAssertEqual(framer.append(bytes[split...]).lines, [#"{"v":"אבג — ok"}"#])
    }

    func testEveryByteBoundaryYieldsTheSameLine() {
        let line = #"{"type":"vocab_list","variants":["אבג","ד"],"note":"— …"}"#
        let bytes = Array(line.utf8) + [0x0A]
        for split in 1 ..< bytes.count {
            var framer = NDJSONLineFramer()
            let first = framer.append(bytes[..<split]).lines
            let second = framer.append(bytes[split...]).lines
            XCTAssertEqual(first + second, [line], "split at byte \(split)")
        }
    }

    func testSeveralLinesInOneReadAndAPartialTailAreFramedInOrder() {
        var framer = NDJSONLineFramer()
        XCTAssertEqual(framer.append(Array("a\n\nb\nc".utf8)).lines, ["a", "b"])
        XCTAssertEqual(framer.append(Array("d\n".utf8)).lines, ["cd"])
        XCTAssertEqual(framer.append(Array("\n".utf8)).lines, [])
    }

    // MARK: - r2: the bound

    /// Measured with the daemon's own serializers on synthetic data (UXP-1 r2): a 2,000-entry vocab_list is
    /// 547,201 B, a 60-minute TTS subtitle event 528,250 B, a 60-minute Hebrew transcription 90,219 B.
    func testTheDefaultCapLeavesRoomAboveTheLargestLegitimateLine() {
        XCTAssertEqual(NDJSONLineFramer.defaultMaxLineBytes, 4 * 1024 * 1024)
        XCTAssertGreaterThan(NDJSONLineFramer.defaultMaxLineBytes, 7 * 547_201)
    }

    func testAnUnterminatedLinePastTheCapOverflowsAndDropsItsBytes() {
        var framer = NDJSONLineFramer(maxLineBytes: 16)
        XCTAssertEqual(framer.append(Array(repeating: 0x61, count: 10)), .init(lines: [], overflowed: false))

        let frame = framer.append(Array(repeating: 0x61, count: 7))

        XCTAssertTrue(frame.overflowed, "17 bytes without a newline must overflow a 16-byte cap")
        XCTAssertEqual(frame.lines, [])
        XCTAssertEqual(framer.pendingByteCount, 0, "the overflowing bytes are dropped, not kept")
    }

    func testALineAtTheCapStillArrives() {
        var framer = NDJSONLineFramer(maxLineBytes: 16)
        let line = String(repeating: "a", count: 16)

        XCTAssertEqual(framer.append(Array((line + "\n").utf8)), .init(lines: [line], overflowed: false))
    }

    func testACompleteLinePastTheCapOverflowsButEarlierLinesArrive() {
        var framer = NDJSONLineFramer(maxLineBytes: 16)
        let frame = framer.append(Array(("ok\n" + String(repeating: "a", count: 17) + "\n").utf8))

        XCTAssertEqual(frame.lines, ["ok"])
        XCTAssertTrue(frame.overflowed)
    }

    func testEachByteIsScannedForANewlineOnce() {
        var framer = NDJSONLineFramer()
        let chunks = 500
        for _ in 0 ..< chunks {
            XCTAssertEqual(framer.append(Array(repeating: 0x61, count: 100)).lines, [])
        }
        XCTAssertEqual(framer.append([0x0A]).lines.first?.count, chunks * 100)

        XCTAssertEqual(framer.scannedByteCount, chunks * 100 + 1, "the pending tail was rescanned on every read")
    }
}
