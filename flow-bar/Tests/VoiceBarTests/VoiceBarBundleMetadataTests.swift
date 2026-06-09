@testable import VoiceBar
import XCTest

final class VoiceBarBundleMetadataTests: XCTestCase {
    func testDevInstanceUsesIsolatedSocketPathsAndSkipsSingleton() {
        setenv("VOICELAYER_DEV_INSTANCE", "1", 1)
        defer { unsetenv("VOICELAYER_DEV_INSTANCE") }

        XCTAssertEqual(VoiceLayerPaths.socketPath, "/tmp/voicelayer-dev.sock")
        XCTAssertEqual(VoiceLayerPaths.mcpSocketPath, "/tmp/voicelayer-dev-mcp.sock")
        XCTAssertEqual(VoiceLayerPaths.daemonPIDPath, "/tmp/voicelayer-dev-mcp.pid")
        XCTAssertEqual(VoiceLayerPaths.retainedRecordingPath, "/tmp/voicelayer-dev-last-recording.wav")
        XCTAssertFalse(VoiceLayerPaths.enforcesSingletonInstance)
    }

    func testInfoPlistDeclaresVoiceBarUrlScheme() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bundle/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes.contains("voicebar"))
    }
}
