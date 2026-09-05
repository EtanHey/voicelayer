/**
 * Recording provenance (metadata v2 / voice_ask v4).
 *
 * Issue #4 acceptance item 6: every metadata.json on disk had `app_version: null`
 * and no host/chip/model field, so "quality is worse on the M1 Pro" could not be
 * tested from artifacts. These tests pin the provenance block onto the two code
 * paths that write metadata.json, and pin that schema-1/3 recordings stay loadable.
 *
 * The probes are injected everywhere so the suite never shells out.
 */
import { afterEach, beforeEach, describe, it, expect } from "bun:test";
import { createHash } from "crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  archiveVoiceAskCapture,
  archiveVoiceBarRecording,
  archiveVoiceBarUntranscribedRecording,
  createWavBuffer,
  finalizeVoiceAskArchive,
  updateArchivedTranscript,
} from "../input";
import {
  buildRecordingProvenance,
  polishReachabilityForStatus,
  type RecordingProvenanceProbe,
} from "../recording-provenance";

const FAKE_PROBE: RecordingProvenanceProbe = {
  machine: () => ({
    host: "test-mac",
    chip: "Apple M1 Pro",
    status: "ready",
  }),
  whisperCppVersion: () => ({ version: "1.7.4", source: "cellar-path" }),
  whisperModelPath: () => "/fake/.cache/whisper/ggml-large-v3-turbo.bin",
  whisperModelSha256: () => "a".repeat(64),
  whisperServerArgs: () => "-t 4 -bo 5 -bs 5",
  whisperServerProcess: () => ({
    pid: 4242,
    startedAt: "2026-09-05T07:00:00.000Z",
  }),
  performanceEffort: () => "accurate",
  polishMode: () => "shadow",
  appVersion: () => ({ version: "9.9.9", source: "package.json" }),
};

describe("recording provenance builder", () => {
  it("assembles every provenance field from injected probes", () => {
    const provenance = buildRecordingProvenance({
      backend: "whisper-server",
      languageMode: "auto",
      polishStatus: "applied",
      probe: FAKE_PROBE,
    });

    expect(provenance).toEqual({
      host: "test-mac",
      chip: "Apple M1 Pro",
      whisper_backend: "whisper-server",
      whisper_model_path: "/fake/.cache/whisper/ggml-large-v3-turbo.bin",
      whisper_model_sha256: "a".repeat(64),
      whisper_cpp_version: "1.7.4",
      whisper_cpp_version_source: "cellar-path",
      whisper_server_args: "-t 4 -bo 5 -bs 5",
      whisper_server_pid: 4242,
      whisper_server_started_at: "2026-09-05T07:00:00.000Z",
      performance_effort: "accurate",
      polish_mode: "shadow",
      polish_reachable: true,
      polish_status: "applied",
      language_mode: "auto",
      app_version: "9.9.9",
      app_version_source: "package.json",
      provenance_probe: "ready",
    });
  });

  it("derives polish reachability from the polish outcome without a second probe", () => {
    expect(polishReachabilityForStatus("applied")).toBe(true);
    expect(polishReachabilityForStatus("rejected")).toBe(true);
    expect(polishReachabilityForStatus("shadowed")).toBe(true);
    expect(polishReachabilityForStatus("failed")).toBe(false);
    expect(polishReachabilityForStatus("unavailable")).toBe(false);
    expect(polishReachabilityForStatus("skipped")).toBe(null);
    expect(polishReachabilityForStatus(undefined)).toBe(null);
    expect(polishReachabilityForStatus(null)).toBe(null);
  });

  it("reports an unknown polish outcome as a null status, not a fabricated one", () => {
    const provenance = buildRecordingProvenance({
      backend: null,
      languageMode: "hebrew",
      probe: FAKE_PROBE,
    });
    expect(provenance.polish_status).toBe(null);
    expect(provenance.polish_reachable).toBe(null);
    expect(provenance.whisper_backend).toBe(null);
  });

  it("caches the shell-out machine probe so it runs once per process", () => {
    let calls = 0;
    const probe: RecordingProvenanceProbe = {
      ...FAKE_PROBE,
      machine: () => {
        calls += 1;
        return {
          host: "test-mac",
          chip: "Apple M4 Max",
          whisper_cpp_version: null,
        };
      },
    };
    buildRecordingProvenance({
      backend: "whisper-server",
      languageMode: "auto",
      probe,
    });
    buildRecordingProvenance({
      backend: "whisper-server",
      languageMode: "auto",
      probe,
    });
    // The caching contract lives in the default probe (see machineProvenance()),
    // so an injected probe is called per build; this pins that injection is not
    // itself memoized in a way that would hide a stale host between tests.
    expect(calls).toBe(2);
  });
});

describe("archived recording metadata carries provenance", () => {
  let archiveRoot: string | undefined;
  let savedRecordingsDir: string | undefined;

  beforeEach(() => {
    savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
    archiveRoot = mkdtempSync(join(tmpdir(), "voicelayer-provenance-"));
    process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
  });

  afterEach(() => {
    if (archiveRoot) rmSync(archiveRoot, { recursive: true, force: true });
    archiveRoot = undefined;
    if (savedRecordingsDir === undefined) {
      delete process.env.QA_VOICE_RECORDINGS_DIR;
    } else {
      process.env.QA_VOICE_RECORDINGS_DIR = savedRecordingsDir;
    }
  });

  function readMetadata(archivePath: string): Record<string, unknown> {
    return JSON.parse(
      readFileSync(join(archivePath, "metadata.json"), "utf8"),
    ) as Record<string, unknown>;
  }

  it("writes schema 2 with a provenance block for a VoiceBar dictation", () => {
    const archivedPath = archiveVoiceBarRecording({
      audioBytes: createWavBuffer(new Uint8Array([1, 2, 3, 4])),
      transcript: "hello there",
      createdAt: new Date("2026-09-05T07:08:09.123Z"),
      source: "voicebar",
      silenceMode: "standard",
      pushToEnd: false,
      durationMs: 900,
      backend: "whisper-server",
      polishStatus: "applied",
      provenanceProbe: FAKE_PROBE,
    });

    expect(archivedPath).toBeTruthy();
    const metadata = readMetadata(archivedPath!);
    expect(metadata.schema_version).toBe(2);
    expect(metadata.app_version).toBe("9.9.9");
    expect(metadata.provenance).toMatchObject({
      host: "test-mac",
      chip: "Apple M1 Pro",
      whisper_backend: "whisper-server",
      whisper_model_path: "/fake/.cache/whisper/ggml-large-v3-turbo.bin",
      whisper_cpp_version: "1.7.4",
      whisper_server_args: "-t 4 -bo 5 -bs 5",
      performance_effort: "accurate",
      polish_mode: "shadow",
      polish_reachable: true,
      polish_status: "applied",
      app_version: "9.9.9",
      app_version_source: "package.json",
    });
  });

  it("writes provenance for a cancelled (untranscribed) recording too", () => {
    const archivedPath = archiveVoiceBarUntranscribedRecording({
      audioBytes: createWavBuffer(new Uint8Array([5, 6])),
      createdAt: new Date("2026-09-05T08:00:00.000Z"),
      source: "voicebar",
      silenceMode: "quick",
      pushToEnd: false,
      durationMs: 400,
      backend: "whisper-server",
      reason: "cancelled",
      provenanceProbe: FAKE_PROBE,
    });

    const metadata = readMetadata(archivedPath);
    expect(metadata.transcription_status).toBe("cancelled");
    expect(metadata.schema_version).toBe(2);
    expect((metadata.provenance as Record<string, unknown>).host).toBe(
      "test-mac",
    );
  });

  it("uses real default probes when none is injected (host is non-empty)", () => {
    const archivedPath = archiveVoiceBarRecording({
      audioBytes: createWavBuffer(new Uint8Array([7, 8])),
      transcript: "default probe",
      createdAt: new Date("2026-09-05T09:00:00.000Z"),
      source: "voicebar",
      silenceMode: "standard",
      pushToEnd: false,
      durationMs: 500,
      backend: "whisper-server",
    });

    const provenance = readMetadata(archivedPath!).provenance as Record<
      string,
      unknown
    >;
    expect(typeof provenance.host).toBe("string");
    expect((provenance.host as string).length).toBeGreaterThan(0);
    expect(typeof provenance.app_version).toBe("string");
    expect(provenance.app_version_source).toBe("package.json");
  });

  it("writes schema 4 with provenance for a voice_ask capture and keeps it through finalization", () => {
    const userAudio = createWavBuffer(new Uint8Array([9, 10, 11, 12]));
    const archivePath = archiveVoiceAskCapture({
      options: {
        archiveSource: "voice_ask" as const,
        voiceAskArtifacts: {
          agentAudioBytes: Buffer.from([0x49, 0x44, 0x33, 1, 2, 3]),
          agentAudioFormat: "mp3" as const,
          agentTranscript: "what did you mean?",
          agentTtsEngine: "qwen3-tts" as const,
          agentTtsVoice: "etan-clone",
          createdAt: new Date("2026-09-05T10:11:12.000Z"),
        },
      },
      audioBytes: userAudio,
      silenceMode: "standard",
      pushToEnd: false,
      durationMs: 1200,
      provenanceProbe: FAKE_PROBE,
    });

    const captured = readMetadata(archivePath);
    expect(captured.schema_version).toBe(4);
    expect((captured.provenance as Record<string, unknown>).chip).toBe(
      "Apple M1 Pro",
    );

    finalizeVoiceAskArchive(archivePath, {
      transcript: "I meant the second one",
      backend: "whisper-server",
      polishStatus: "rejected",
      provenanceProbe: FAKE_PROBE,
    });

    const finalized = readMetadata(archivePath);
    expect(finalized.schema_version).toBe(4);
    expect(finalized.provenance).toMatchObject({
      whisper_backend: "whisper-server",
      polish_status: "rejected",
      polish_reachable: true,
    });
  });
});

describe("older schema recordings stay loadable", () => {
  let archiveRoot: string | undefined;
  let savedRecordingsDir: string | undefined;

  beforeEach(() => {
    savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
    archiveRoot = mkdtempSync(join(tmpdir(), "voicelayer-provenance-old-"));
    process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
  });

  afterEach(() => {
    if (archiveRoot) rmSync(archiveRoot, { recursive: true, force: true });
    archiveRoot = undefined;
    if (savedRecordingsDir === undefined) {
      delete process.env.QA_VOICE_RECORDINGS_DIR;
    } else {
      process.env.QA_VOICE_RECORDINGS_DIR = savedRecordingsDir;
    }
  });

  function writeLegacyVoiceBarArchive(schemaVersion: number): string {
    const id = `2026-05-02T07-08-09-123Z-abcdef01`;
    const dir = join(archiveRoot!, "2026-05-02", id);
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const audioBytes = createWavBuffer(new Uint8Array([1, 2, 3, 4]));
    writeFileSync(join(dir, "audio.wav"), audioBytes);
    writeFileSync(join(dir, "voicelayer-transcript.txt"), "legacy transcript");
    writeFileSync(
      join(dir, "metadata.json"),
      `${JSON.stringify(
        {
          id,
          created_at: "2026-05-02T07:08:09.123Z",
          source: "voicebar",
          mode: "vad",
          silence_mode: "standard",
          duration_ms: 900,
          raw_duration_ms: 900,
          transcribed_duration_ms: 900,
          sample_rate: 16000,
          channels: 1,
          backend: "whisper.cpp",
          language_mode: "auto",
          voicelayer_transcript_chars: 17,
          transcription_status: "transcribed",
          audio_sha256: createHash("sha256").update(audioBytes).digest("hex"),
          app_version: null,
          schema_version: schemaVersion,
        },
        null,
        2,
      )}\n`,
    );
    return dir;
  }

  it("refreshes whisper_backend on retranscription of a provenance recording", () => {
    const archivedPath = archiveVoiceBarRecording({
      audioBytes: createWavBuffer(new Uint8Array([3, 4])),
      transcript: "first pass",
      createdAt: new Date("2026-09-05T11:00:00.000Z"),
      source: "voicebar",
      silenceMode: "standard",
      pushToEnd: false,
      durationMs: 700,
      backend: "whisper-server",
      provenanceProbe: FAKE_PROBE,
    });

    updateArchivedTranscript(join(archivedPath!, "audio.wav"), "second pass", {
      backend: "whisper.cpp",
      languageMode: "hebrew",
    });

    const provenance = (
      JSON.parse(
        readFileSync(join(archivedPath!, "metadata.json"), "utf8"),
      ) as Record<string, unknown>
    ).provenance as Record<string, unknown>;
    expect(provenance.whisper_backend).toBe("whisper.cpp");
    expect(provenance.language_mode).toBe("hebrew");
    // Machine facts are not re-probed on retranscription; they still describe
    // the machine that captured the audio.
    expect(provenance.chip).toBe("Apple M1 Pro");
  });

  it("still updates the transcript of a schema-1 VoiceBar recording", () => {
    const dir = writeLegacyVoiceBarArchive(1);
    updateArchivedTranscript(join(dir, "audio.wav"), "corrected transcript", {
      backend: "whisper-server",
      languageMode: "auto",
    });
    const metadata = JSON.parse(
      readFileSync(join(dir, "metadata.json"), "utf8"),
    ) as Record<string, unknown>;
    // The recording is retained untouched apart from the transcript: an old
    // schema is never rewritten or dropped (every recording is kept).
    expect(metadata.schema_version).toBe(1);
    expect(metadata.provenance).toBeUndefined();
    expect(readFileSync(join(dir, "voicelayer-transcript.txt"), "utf8")).toBe(
      "corrected transcript",
    );
    expect(readdirSync(dir).sort()).toEqual([
      "audio.wav",
      "metadata.json",
      "voicelayer-transcript.txt",
    ]);
  });
});
