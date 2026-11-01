import XCTest
@testable import VoiceBarUI
final class NativeFixLegacyMetadataTests:XCTestCase {
 func testLegacyModelAndPresetSurviveInDetailsAndFullMetadataCopy() {
  let entry=SettingsHistoryEntry(id:"synthetic-legacy",dayKey:"2026-11-01",recordingID:"synthetic-legacy",createdAt:Date(timeIntervalSince1970:0),transcript:"Synthetic.",audioPath:URL(fileURLWithPath:"/synthetic/audio.wav"),modelLabel:"synthetic-model",performanceEffort:.accurate)
  let facts=SettingsHistoryDiagnosticsPanel.legacyRecognitionFacts(entry,hasAttempts:false)
  XCTAssertEqual(facts.map{$0.0},["Model","Recognition preset"])
  XCTAssertEqual(facts.map{$0.1},["synthetic-model","Accurate"])
  XCTAssertTrue(SettingsHistoryDiagnosticsPanel.legacyRecognitionFacts(entry,hasAttempts:true).isEmpty,"An attempt's actual facts must not be replaced by legacy archive settings")
  let payload=SettingsDiagnosticSummary.historyMetadata(entry)
  XCTAssertTrue(payload.contains("synthetic-model"));XCTAssertTrue(payload.contains("accurate"))
 }
}
