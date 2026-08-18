import XCTest

final class BoundaryContractTests: XCTestCase {
    func testVoiceBarUISourcesDoNotReferenceExecutableBoundaryTokens() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources/VoiceBarUI", isDirectory: true)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
            "VoiceBarUI source directory should exist"
        )
        XCTAssertTrue(isDirectory.boolValue, "VoiceBarUI source path should be a directory")

        let forbiddenTokens = [
            "SocketServer",
            "NWListener",
            "/tmp/voicelayer",
            "mcp-",
            "voice_speak",
            "voice_ask",
            "AXUIElement",
            "CGEvent",
            "AXIsProcessTrusted",
            "STTVocabularySnapshotLoader",
            "VoiceBarDaemon",
        ]

        let sourceFiles = try swiftSourceFiles(in: sourceRoot)
        XCTAssertFalse(sourceFiles.isEmpty, "VoiceBarUI should contain Swift source files")

        // AIDEV-NOTE: `SettingsArchiveSchema.swift` is the single declared home for the archive's
        // ask `source` discriminator, which Settings → History must match to keep ask exchanges out
        // of the recording list. That is a stored value in a JSON file the UI already reads, not a
        // call into the MCP layer, so it is exempted for that one token only — every other file,
        // and every other token, is still forbidden.
        let exemptions: [String: Set<String>] = [
            "SettingsArchiveSchema.swift": ["voice_ask"],
        ]

        var violations: [String] = []
        for fileURL in sourceFiles {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let exempt = exemptions[fileURL.lastPathComponent] ?? []
            for token in forbiddenTokens where contents.contains(token) && !exempt.contains(token) {
                violations.append("\(fileURL.lastPathComponent): \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "VoiceBarUI must stay presentation-only. Forbidden boundary tokens found: \(violations.joined(separator: ", "))"
        )
    }

    private func swiftSourceFiles(in directory: URL) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys)
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let fileURL = item as? URL,
                  fileURL.pathExtension == "swift"
            else {
                return nil
            }

            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            return values.isRegularFile == true ? fileURL : nil
        }
    }
}
