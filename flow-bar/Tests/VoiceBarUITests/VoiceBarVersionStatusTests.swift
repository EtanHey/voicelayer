import Foundation
@testable import VoiceBarUI
import XCTest

/// Settings › General › Version: cask parse, version compare, and the six-hour cached check. No network here;
/// every fetch is injected.
final class VoiceBarVersionStatusTests: XCTestCase {
    private static let cask = """
    # frozen_string_literal: true

    cask "voicebar" do
      version "2.2.58"
      sha256 "c9123e11977229029d8602ca4d6c701ed6fc75871103741e34a0cf10d717262b"

      url "https://github.com/EtanHey/voicelayer/releases/download/v#{version}/VoiceBar.zip"
      name "VoiceBar"
    end
    """

    // MARK: - Cask parse

    func testParsesTheTapCaskVersion() {
        XCTAssertEqual(VoiceBarCaskVersion.parse(Self.cask), "2.2.58")
        XCTAssertEqual(VoiceBarCaskVersion.parse(Self.cask.replacingOccurrences(of: "\n", with: "\r\n")), "2.2.58")
        XCTAssertEqual(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n  version \"2.3.0\" # pinned\nend"), "2.3.0")
    }

    func testGarbageIsNotAVersion() {
        XCTAssertNil(VoiceBarCaskVersion.parse(""))
        XCTAssertNil(VoiceBarCaskVersion.parse("<html><body>404: Not Found</body></html>"))
        XCTAssertNil(VoiceBarCaskVersion.parse("404: Not Found"))
        // Another cask's file, or a truncated body before the version stanza.
        XCTAssertNil(VoiceBarCaskVersion.parse(Self.cask.replacingOccurrences(of: "cask \"voicebar\"", with: "cask \"other\"")))
        XCTAssertNil(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n"))
        // Versions we cannot compare.
        XCTAssertNil(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n  version :latest\nend"))
        XCTAssertNil(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n  version \"2.2.58,abc\"\nend"))
        XCTAssertNil(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n  version \"2.2.58-rc1\"\nend"))
        XCTAssertNil(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n  version \"2.2.58\nend"))
        XCTAssertNil(VoiceBarCaskVersion.parse("cask \"voicebar\" do\n  version \"\"\nend"))
    }

    // MARK: - Compare

    func testEqualIsLatest() {
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2.58", latest: "2.2.58"), .latest)
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2", latest: "2.2.0"), .latest)
    }

    func testOlderInstallIsOfferedTheCaskVersion() {
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2.57", latest: "2.2.58"), .available("2.2.58"))
        // Numeric, not lexical: 2.2.9 is older than 2.2.10.
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2.9", latest: "2.2.10"), .available("2.2.10"))
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.9.0", latest: "3.0.0"), .available("3.0.0"))
    }

    /// The M4 today: candidate 2.2.59 installed, cask still 2.2.58. Never "available".
    func testNewerCandidateIsAheadNotAvailable() {
        let status = VoiceBarVersionStatus.resolve(installed: "2.2.59", latest: "2.2.58")
        XCTAssertEqual(status, .ahead(latest: "2.2.58"))
        XCTAssertFalse(status.message.contains("available"))
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2.10", latest: "2.2.9"), .ahead(latest: "2.2.9"))
    }

    func testUnknownOrGarbageVersionsCouldNotCheck() {
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: nil, latest: "2.2.58"), .couldNotCheck)
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2.58", latest: nil), .couldNotCheck)
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "dev", latest: "2.2.58"), .couldNotCheck)
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2.2.58", latest: "v2.2.58"), .couldNotCheck)
        XCTAssertEqual(VoiceBarVersionStatus.resolve(installed: "2..58", latest: "2.2.58"), .couldNotCheck)
    }

    func testCopy() {
        XCTAssertEqual(VoiceBarVersionStatus.latest.message, "You are on the latest version")
        XCTAssertEqual(VoiceBarVersionStatus.available("2.2.60").message, "VoiceBar 2.2.60 is available")
        XCTAssertEqual(VoiceBarVersionStatus.ahead(latest: "2.2.58").message, "Newer than the latest release (2.2.58)")
        XCTAssertEqual(VoiceBarVersionStatus.couldNotCheck.message, "Could not check for updates")
        let all: [VoiceBarVersionStatus] = [.checking, .latest, .ahead(latest: "1"), .available("1"), .couldNotCheck]
        for status in all { XCTAssertFalse(status.message.contains("\u{2014}"), "no em dash: \(status.message)") }
    }

    // MARK: - Installed version

    func testInstalledLabelCarriesTheShortReleaseCommit() {
        let stamped = VoiceBarInstalledVersion(version: "2.2.59", commit: "1234567890abcdef1234567890abcdef12345678")
        XCTAssertEqual(stamped.label, "2.2.59 (1234567)")
        XCTAssertEqual(VoiceBarInstalledVersion(version: "2.2.59", commit: nil).label, "2.2.59")
        XCTAssertEqual(VoiceBarInstalledVersion(version: "2.2.59", commit: "  ").label, "2.2.59")
        XCTAssertEqual(VoiceBarInstalledVersion(version: nil, commit: "abc").label, "Unknown")
    }

    // MARK: - Cached check

    func testOfflineCouldNotCheckAndIsNotCached() async {
        let fetches = Counter()
        let check = VoiceBarVersionCheck(fetch: {
            fetches.increment()
            throw URLError(.notConnectedToInternet)
        })
        let first = await check.status(installed: "2.2.58")
        XCTAssertEqual(first, .couldNotCheck)
        _ = await check.status(installed: "2.2.58")
        XCTAssertEqual(fetches.value, 2, "a failure is retried on the next Settings open")
    }

    func testUnparseableBodyCouldNotCheck() async {
        let check = VoiceBarVersionCheck(fetch: { "<html>rate limited</html>" })
        let status = await check.status(installed: "2.2.58")
        XCTAssertEqual(status, .couldNotCheck)
    }

    func testSuccessIsCachedForSixHours() async {
        let fetches = Counter()
        let clock = Clock()
        let check = VoiceBarVersionCheck(fetch: {
            fetches.increment()
            return Self.cask
        }, now: { clock.now })

        let first = await check.status(installed: "2.2.58")
        XCTAssertEqual(first, .latest)
        clock.advance(VoiceBarVersionCheck.cacheLifetime - 1)
        let cached = await check.status(installed: "2.2.57")
        XCTAssertEqual(cached, .available("2.2.58"))
        XCTAssertEqual(fetches.value, 1)

        clock.advance(2)
        _ = await check.status(installed: "2.2.58")
        XCTAssertEqual(fetches.value, 2, "refetched once the six hours are up")
    }

    func testConcurrentCallersShareOneRequest() async {
        let fetches = Counter()
        let check = VoiceBarVersionCheck(fetch: {
            fetches.increment()
            try await Task.sleep(for: .milliseconds(50))
            return Self.cask
        })
        async let a = check.latestVersion()
        async let b = check.latestVersion()
        let (first, second) = await (a, b)
        XCTAssertEqual(first, "2.2.58")
        XCTAssertEqual(second, "2.2.58")
        XCTAssertEqual(fetches.value, 1)
    }

    func testLiveCheckTargetsTheTapCaskWithAShortTimeout() {
        XCTAssertEqual(VoiceBarVersionCheck.caskURL.absoluteString,
                       "https://raw.githubusercontent.com/EtanHey/homebrew-layers/main/Casks/voicebar.rb")
        XCTAssertLessThanOrEqual(VoiceBarVersionCheck.timeout, 5)
        XCTAssertEqual(VoiceBarVersionCheck.cacheLifetime, 6 * 60 * 60)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}
