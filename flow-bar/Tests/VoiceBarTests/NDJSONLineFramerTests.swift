@testable import VoiceBar
import XCTest

/// UXP-1: socket reads are split at arbitrary byte offsets, so the framer must decode whole lines only.
final class NDJSONLineFramerTests: XCTestCase {
    func testALineSplitInsideAMultiByteCharacterDecodesWhole() throws {
        var framer = NDJSONLineFramer()
        let bytes = Array(#"{"v":"אבג — ok"}"#.utf8) + [0x0A]
        let split = try XCTUnwrap(bytes.firstIndex(of: 0xD7)) + 1

        XCTAssertEqual(framer.append(bytes[..<split]), [])
        XCTAssertEqual(framer.append(bytes[split...]), [#"{"v":"אבג — ok"}"#])
    }

    func testEveryByteBoundaryYieldsTheSameLine() {
        let line = #"{"type":"vocab_list","variants":["אבג","ד"],"note":"— …"}"#
        let bytes = Array(line.utf8) + [0x0A]
        for split in 1 ..< bytes.count {
            var framer = NDJSONLineFramer()
            let first = framer.append(bytes[..<split])
            let second = framer.append(bytes[split...])
            XCTAssertEqual(first + second, [line], "split at byte \(split)")
        }
    }

    func testSeveralLinesInOneReadAndAPartialTailAreFramedInOrder() {
        var framer = NDJSONLineFramer()
        XCTAssertEqual(framer.append(Array("a\n\nb\nc".utf8)), ["a", "b"])
        XCTAssertEqual(framer.append(Array("d\n".utf8)), ["cd"])
        XCTAssertEqual(framer.append(Array("\n".utf8)), [])
    }
}
