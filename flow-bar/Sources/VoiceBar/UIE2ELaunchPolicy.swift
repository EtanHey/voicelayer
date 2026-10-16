#if VOICEBAR_QA
import Foundation

/// Bundle identity is persistent; a missing environment flag must never turn a UI-only
/// executable into the production daemon/hotkey owner. Resolve before NSApplication exists.
enum UIE2ELaunchPolicy {
    static let bundleIdentifier = "com.voicelayer.voicebar.uie2e"
    static let markerKey = "VoiceBarUIE2EOnly"
    enum Mode: Equatable { case production, fixture }
    enum Refusal: Error { case invalidConfiguration, muteUnconfirmed }

    static func resolve(bundleIdentifier: String?, marker: Any?, environment: [String: String],
                        confirmMute: () throws -> Bool) throws -> Mode {
        let marked = bundleIdentifier == Self.bundleIdentifier || marker != nil
        guard marked || environment["VOICEBAR_UIE2E"] != nil else { return .production }
        guard bundleIdentifier == Self.bundleIdentifier, marker as? Bool == true,
              environment["VOICEBAR_UIE2E"] == "1" else { throw Refusal.invalidConfiguration }
        _ = try UIE2ESandbox(environment: environment)
        guard try confirmMute() else { throw Refusal.muteUnconfirmed }
        return .fixture
    }
}
#endif
