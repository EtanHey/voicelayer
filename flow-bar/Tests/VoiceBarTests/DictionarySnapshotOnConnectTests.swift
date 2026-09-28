@testable import VoiceBar
import XCTest

/// QA 2.2.25 C11: the daemon's bundled Dictionary rows arrive only in its `vocab_list` reply, which VoiceBar
/// used to request only after an edit, so Settings read "Included terms (0)". A (re)connect must ask for it.
@MainActor
final class DictionarySnapshotOnConnectTests: XCTestCase {
    func testConnectingRequestsTheDictionarySnapshot() {
        let app = AppDelegate()
        var sent: [String] = []
        app.voiceState.sendCommand = { command in
            if let cmd = command["cmd"] as? String { sent.append(cmd) }
        }

        app.voiceState.setConnectionStatus(true)

        XCTAssertTrue(sent.contains("vocab_list"), "sent on connect: \(sent)")
    }
}
