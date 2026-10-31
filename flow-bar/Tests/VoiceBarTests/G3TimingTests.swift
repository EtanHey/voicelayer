import XCTest
@testable import VoiceBar
@testable import VoiceBarUI

@MainActor final class G3TimingTests: XCTestCase {
    func testF5ToRecordTiming() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gate").path
        try Data(#"{"version":1,"kind":"OPEN","generation":0,"released":null}"#.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.createDirectory(atPath: path + ".admissions", withIntermediateDirectories: false)
        let gate = NativeUpdateGate(path: path), app = AppDelegate(), engine = UIE2ENoDeviceLevelEngine()
        app.configureAudioLevelMonitoringForTesting(engine: engine)
        var samples: [Double] = []
        for _ in 0..<1000 {
            let state = VoiceState()
            state.mode = .idle; state.isConnected = true
            state.frontmostAppProvider = { nil }
            state.onModeChange = { mode in
                if mode == .recording { app.startAudioLevelMonitoring(gate: gate) }
            }
            var sent = false
            let start = DispatchTime.now().uptimeNanoseconds
            state.sendCommand = { command in
                if command["cmd"] as? String == "record" {
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    sent = true
                }
            }
            state.record(pressToTalk: true)
            XCTAssertTrue(sent)
            app.stopAudioLevelMonitoring()
        }
        samples.sort()
        print("G3 F5->record n=1000 p50=\(samples[499])ms p99=\(samples[989])ms (no-device meter, synthetic socket sender)")
    }
}
