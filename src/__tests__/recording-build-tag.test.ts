import { afterEach, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import { recordingAppBuild } from "../recording-build";
import { archiveVoiceBarRecording, archiveVoiceBarUntranscribedRecording, archiveVoiceAskCapture,
  finalizeVoiceAskArchive, updateArchivedTranscript, createWavBuffer } from "../input";

const keys = ["VOICEBAR_VERSION", "VOICEBAR_GIT_COMMIT", "VOICEBAR_BUILD_TIME_UTC", "VOICEBAR_BUILD_SOURCE", "QA_VOICE_RECORDINGS_DIR"];
const saved = keys.map(key => [key, process.env[key]] as const);
const capture = { version: "2.3.0", git_commit: "a".repeat(40), build_time_utc: "2026-11-08T00:00:00Z", source: "VoiceBar.Info.plist" };
const retry = { ...capture, git_commit: "b".repeat(40) };
const unknown = { version: null, git_commit: null, build_time_utc: null, source: null };
let root: string | undefined;
afterEach(() => {
  for (const [key, value] of saved) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
  if (root) rmSync(root, { recursive: true, force: true });
});
function setBuild(build: typeof capture) {
  process.env.VOICEBAR_VERSION = build.version; process.env.VOICEBAR_GIT_COMMIT = build.git_commit;
  process.env.VOICEBAR_BUILD_TIME_UTC = build.build_time_utc; process.env.VOICEBAR_BUILD_SOURCE = build.source;
}
function metadata(path: string): any { return JSON.parse(readFileSync(join(path, "metadata.json"), "utf8")); }
for (const source of ["dictation", "captured", "cancelled", "voice_ask", "text-only ask"] as const) {
  it(`keeps the capture build through ${source} finalization and later retry`, () => {
    root = mkdtempSync(join(process.env.QA_VOICE_RECORDINGS_DIR!, "build-tag-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root; setBuild(capture);
    const audioBytes = createWavBuffer(new Uint8Array([1, 2, 3, 4]));
    const input = { audioBytes, source: "voicebar" as const, silenceMode: "standard" as const,
      pushToEnd: false, durationMs: 100, backend: "fixture" };
    const path = source.includes("ask") ? archiveVoiceAskCapture({ ...input, options: {
      archiveSource: "voice_ask", voiceAskArtifacts: { agentTranscript: "synthetic question",
        agentTtsEngine: "edge-tts", agentTtsVoice: "fixture", createdAt: new Date(),
        ...(source === "text-only ask" ? { promptDelivery: "text-only" as const }
          : { agentAudioBytes: Buffer.from([1]), agentAudioFormat: "mp3" as const }) } } })
      : source === "cancelled" || source === "captured" ? archiveVoiceBarUntranscribedRecording({ ...input, reason: source })
      : archiveVoiceBarRecording({ ...input, transcript: "synthetic capture" })!;
    expect(metadata(path).app_build).toEqual(capture);
    setBuild(retry);
    if (source === "captured") {
      updateArchivedTranscript(join(path, "audio.wav"), "synthetic first final", { backend: "fixture", languageMode: "auto", initialTranscription: true });
      expect(metadata(path).app_build).toEqual(capture);
      expect(metadata(path).retranscribed_by).toBeUndefined();
    }
    if (source.includes("ask")) {
      finalizeVoiceAskArchive(path, { transcript: "synthetic answer", backend: "fixture" });
      expect(metadata(path).app_build).toEqual(capture);
      expect(metadata(path).retranscribed_by).toBeUndefined();
    }
    updateArchivedTranscript(join(path, "audio.wav"), "synthetic retry", { backend: "fixture", languageMode: "auto" });
    expect(metadata(path).app_build).toEqual(capture);
    expect(metadata(path).retranscribed_by).toEqual(retry);
  });
}
it("unknown bundle facts stay null, without inferring the checkout or package version", () => {
  root = mkdtempSync(join(process.env.QA_VOICE_RECORDINGS_DIR!, "build-tag-"));
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  for (const key of keys.slice(0, 4)) delete process.env[key];
  const path = archiveVoiceBarRecording({ audioBytes: createWavBuffer(new Uint8Array([1, 2])),
    transcript: "synthetic", source: "voicebar", silenceMode: "standard", pushToEnd: false, durationMs: 100, backend: "fixture" })!;
  expect(metadata(path).app_build).toEqual(unknown);
});

it("rejects stale unmarked or invalid bundle facts", () => {
  expect(recordingAppBuild({ VOICEBAR_VERSION: "stale", VOICEBAR_GIT_COMMIT: "a".repeat(40) })).toEqual(unknown);
  expect(recordingAppBuild({ VOICEBAR_BUILD_SOURCE: "VoiceBar.Info.plist", VOICEBAR_VERSION: "unknown",
    VOICEBAR_GIT_COMMIT: "unknown", VOICEBAR_BUILD_TIME_UTC: "invalid" })).toEqual({ ...unknown, source: "VoiceBar.Info.plist" });
});
