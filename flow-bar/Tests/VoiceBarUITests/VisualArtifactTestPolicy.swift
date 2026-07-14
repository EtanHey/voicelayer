import Foundation
import XCTest

enum VisualArtifactTestPolicy {
    static let environmentVariable = "VOICEBAR_REGENERATE_VISUAL_ARTIFACTS"

    static func isRegenerationEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentVariable] == "1"
    }

    static func requireRegeneration() throws {
        guard isRegenerationEnabled() else {
            throw XCTSkip(
                "Set \(environmentVariable)=1 to regenerate visual artifacts"
            )
        }
    }
}
