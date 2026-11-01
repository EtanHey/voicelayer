import XCTest
@testable import VoiceBarUI
@MainActor final class NativeFixReadCadenceTests: XCTestCase {
 func testStatusReadsAreVisibleOnlyAtMostOncePerSecondAndNeverScheduled() {
  let state=VoiceState(recentTranscriptionsLoader:{[]},recentTranscriptionsSaver:{_ in},recentTranscriptionEntriesLoader:{[]},recentTranscriptionEntriesSaver:{_ in},transcriptionVocabularyLoader:{[]},transcriptionVocabularyAliasLoader:{[]})
  var visible=false;var now:TimeInterval=10;var commands:[[String:Any]]=[]
  state.recognizerSettingsIsVisible={visible};state.recognizerStatusReadClock={now};state.sendCommand={commands.append($0)}
  state.setConnectionStatus(true)
  for _ in 0..<20 {state.refreshRecognizerStatus()}
  XCTAssertTrue(commands.isEmpty,"Connect and refresh must be silent while the page is hidden")
  visible=true;state.refreshRecognizerStatus()
  XCTAssertEqual(commands.count,1)
  for i in 0..<100 {now=10+Double(i)/100;state.refreshRecognizerStatus()}
  XCTAssertEqual(commands.count,1,"Burst of visible lifecycle events is limited to one read per second")
  now=11;state.refreshRecognizerStatus();XCTAssertEqual(commands.count,2)
  visible=false;now=30;state.mode = .recording;state.mode = .transcribing;state.mode = .speaking;state.mode = .idle
  state.refreshRecognizerStatus();XCTAssertEqual(commands.count,2,"Hidden capture transitions cannot poll")
  visible=true;state.refreshRecognizerStatus();XCTAssertEqual(commands.count,3)
  XCTAssertTrue(commands.allSatisfy{Set($0.keys)==["cmd","id"] && $0["cmd"] as? String == "get_recognizer_status"})
 }
 func testEventBurstCoalescesOnceAndHiddenPageCancelsTheSend() async throws {
  let state=VoiceState(recentTranscriptionsLoader:{[]},recentTranscriptionsSaver:{_ in},recentTranscriptionEntriesLoader:{[]},recentTranscriptionEntriesSaver:{_ in},transcriptionVocabularyLoader:{[]},transcriptionVocabularyAliasLoader:{[]})
  var visible=true;var times:[TimeInterval]=[]
  state.recognizerSettingsIsVisible={visible};state.sendCommand={_ in times.append(ProcessInfo.processInfo.systemUptime)}
  state.setConnectionStatus(true)
  for _ in 0..<20 {state.refreshRecognizerStatus()}
  visible=false
  try await Task.sleep(for:.milliseconds(1100));XCTAssertEqual(times.count,1,"Hidden trailing event cannot send")
  visible=true;state.refreshRecognizerStatus()
  for _ in 0..<20 {state.refreshRecognizerStatus()}
  try await Task.sleep(for:.milliseconds(1100));XCTAssertEqual(times.count,3,"One coalesced read for the visible burst")
  try await Task.sleep(for:.milliseconds(1100));XCTAssertEqual(times.count,3,"No periodic poll after the coalesced read")
  XCTAssertTrue(zip(times.dropFirst(),times).allSatisfy{$0.0-$0.1>=1})
 }

}
