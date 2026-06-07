@testable import VoiceBarUI
import XCTest

final class V5IslandVoiceStateMappingTests: XCTestCase {
    func testVoiceModesMapToCanonicalV5IslandRenderKinds() {
        XCTAssertEqual(V5IslandProjection.make(mode: .idle).renderKind, .idle)
        XCTAssertEqual(V5IslandProjection.make(mode: .disconnected).renderKind, .idle)
        XCTAssertEqual(V5IslandProjection.make(mode: .recording).renderKind, .recording)
        XCTAssertEqual(V5IslandProjection.make(mode: .transcribing).renderKind, .transcribing)
        XCTAssertEqual(V5IslandProjection.make(mode: .speaking).renderKind, .speaking)
        XCTAssertEqual(V5IslandProjection.make(mode: .error).renderKind, .error)
    }

    func testDisconnectedUsesDimmedIdleMicWithoutHoverReveal() {
        let projection = V5IslandProjection.make(mode: .disconnected)

        XCTAssertEqual(projection.renderKind, .idle)
        XCTAssertEqual(projection.micOpacity, 0.35, accuracy: 0.001)
        XCTAssertFalse(projection.allowsHoverReveal)
    }

    func testRecordingAndSpeakingCarryRealAudioLevels() throws {
        let startedAt = Date(timeIntervalSinceReferenceDate: 120)
        let recording = V5IslandProjection.make(
            mode: .recording,
            audioLevel: 0.42,
            recordingStartedAt: startedAt
        )
        XCTAssertEqual(try XCTUnwrap(recording.audioLevel), 0.42, accuracy: 0.001)
        XCTAssertEqual(recording.recordingStartedAt, startedAt)
        XCTAssertFalse(recording.usesStaticSpeakingBars)

        let speakingWithLevels = V5IslandProjection.make(mode: .speaking, audioLevel: 0.73)
        XCTAssertEqual(try XCTUnwrap(speakingWithLevels.audioLevel), 0.73, accuracy: 0.001)
        XCTAssertFalse(speakingWithLevels.usesStaticSpeakingBars)

        let speakingWithoutLevels = V5IslandProjection.make(mode: .speaking, audioLevel: nil)
        XCTAssertTrue(speakingWithoutLevels.usesStaticSpeakingBars)
    }

    func testErrorIsTransientTwoSecondWake() {
        let projection = V5IslandProjection.make(mode: .error, errorMessage: "Mic unavailable")

        XCTAssertEqual(projection.renderKind, .error)
        XCTAssertEqual(projection.errorTTL, 2.0, accuracy: 0.001)
        XCTAssertEqual(projection.errorMessage, "Mic unavailable")
    }

    func testSheetsProjectRecentTranscriptionsAndDictionaryReadOnlyData() {
        let projection = V5IslandProjection.make(
            mode: .idle,
            recentTranscriptions: ["latest transcript", "older transcript"],
            vocabularyTerms: ["VoiceLayer", "repoGolem"],
            vocabularyAliases: [
                STTVocabularyAliasPreview(from: "voice layer", to: "VoiceLayer"),
                STTVocabularyAliasPreview(from: "rapporteur golem", to: "repoGolem"),
            ]
        )

        XCTAssertEqual(projection.historyRows.map(\.text), ["latest transcript", "older transcript"])
        XCTAssertEqual(projection.preservedTerms.map(\.term), ["VoiceLayer", "repoGolem"])
        XCTAssertEqual(projection.correctedTerms.map(\.from), ["voice layer", "rapporteur golem"])
        XCTAssertEqual(projection.correctedTerms.map(\.to), ["VoiceLayer", "repoGolem"])
    }

    func testV5SurfaceStyleOnlyAppliesToTopCenterWhenEnabled() {
        XCTAssertEqual(
            VoiceBarSurfaceStyle.resolved(anchorMode: .topCenter, v5Enabled: true),
            .v5Island
        )
        XCTAssertEqual(
            VoiceBarSurfaceStyle.resolved(anchorMode: .bottomCenter, v5Enabled: true),
            .floatingPill
        )
        XCTAssertEqual(
            VoiceBarSurfaceStyle.resolved(anchorMode: .follow, v5Enabled: true),
            .floatingPill
        )
        XCTAssertEqual(
            VoiceBarSurfaceStyle.resolved(anchorMode: .topCenter, v5Enabled: false),
            .menuBarIsland
        )
    }
}
