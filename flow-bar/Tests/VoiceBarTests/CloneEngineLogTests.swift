import Foundation
import XCTest
@testable import VoiceBar

final class CloneEngineLogTests: XCTestCase {
    func testOversizedLegacyLogIsReducedToABoundedTailOnRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = CloneEngineLog(url: root.appendingPathComponent("clone-engine.log"), maxBytes: 64)
        try Data(repeating: 65, count: 200).write(to: logger.url)
        logger.append(Data([66])); logger.flush()
        XCTAssertEqual(try Data(contentsOf: logger.url), Data([66]))
        XCTAssertEqual(try Data(contentsOf: logger.url.appendingPathExtension("1")), Data(repeating: 65, count: 64))
    }

    func testAppendPreservesExistingBytesAndRotatesOnEveryWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = CloneEngineLog(url: root.appendingPathComponent("clone-engine.log"), maxBytes: 64)
        logger.append(Data(repeating: 65, count: 40)); logger.flush()
        logger.append(Data(repeating: 66, count: 10)); logger.flush()
        XCTAssertEqual(try Data(contentsOf: logger.url), Data(repeating: 65, count: 40) + Data(repeating: 66, count: 10))
        logger.append(Data(repeating: 67, count: 40)); logger.flush()
        XCTAssertEqual(try Data(contentsOf: logger.url.appendingPathExtension("1")).count, 50)
        XCTAssertEqual(try Data(contentsOf: logger.url).count, 40)
        logger.append(Data(repeating: 68, count: 200)); logger.flush()
        for file in [logger.url, logger.url.appendingPathExtension("1")] {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 64)
        }
        XCTAssertTrue(try Data(contentsOf: logger.url).allSatisfy { $0 == 68 })
    }
}
