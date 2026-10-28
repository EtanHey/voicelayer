import { createHash } from "crypto";
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, openSync, readFileSync, realpathSync } from "fs";
import { dirname, join, resolve } from "path";
import type { VoiceAskCaptureArchiveInput } from "./input";

/** Expectations come from the retained prompt and complete normalized capture, not a receipt UUID. */
export type PairedCaptureExpectation = Readonly<{
  archiveRoot: string;
  archivePath: string;
  archiveId: string;
  prompt: Readonly<NonNullable<VoiceAskCaptureArchiveInput["options"]["voiceAskArtifacts"]>>;
  userWav: VoiceAskCaptureArchiveInput["audioBytes"];
  source: "voice_ask";
  mode: "vad" | "ptt";
  format: Readonly<{ sampleRate: 16000; channels: 1; bitsPerSample: 16 }>;
}>;

type ArtifactEvidence = Readonly<{ bytes: number; sha256: string }>;
export type PairedCaptureEvidence =
  | Readonly<{ kind: "verified-paired"; archiveId: string; archivePath: string;
      audioStatus: "captured"; transcriptStatus: "unverified"; closureStatus: "closed";
      artifacts: Readonly<Record<string, ArtifactEvidence>> }>
  | Readonly<{ kind: "verification-unavailable"; code: "paired-capture-verification-failed";
      closureStatus: "closed" | "unconfirmed" }>;

function requireEvidence(condition: unknown): asserts condition {
  if (!condition) throw new Error("Paired capture verification unavailable");
}
function metadataRecord(value: unknown): Record<string, unknown> {
  requireEvidence(typeof value === "object" && value !== null && !Array.isArray(value));
  return Object.fromEntries(Object.entries(value));
}
const digest = (data: Uint8Array) => createHash("sha256").update(data).digest("hex");
const artifact = (data: Uint8Array): ArtifactEvidence => Object.freeze({ bytes: data.byteLength, sha256: digest(data) });

/** Read-only capture report; strict fsync is required, but this grants no lifecycle release authority. */
export function verifyConversationPairedCapture(expected: PairedCaptureExpectation): PairedCaptureEvidence {
  const owned: number[] = [];
  let closureStatus: "closed" | "unconfirmed" = "closed";
  let evidence: PairedCaptureEvidence | undefined;
  try {
    const { archiveRoot, archivePath, archiveId, prompt, format } = expected;
    const id = /^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z-[a-f0-9]{8}$/.exec(archiveId);
    requireEvidence(id);
    const createdAt = `${id[1]}T${id[2]}:${id[3]}:${id[4]}.${id[5]}Z`;
    requireEvidence(new Date(createdAt).toISOString() === createdAt);
    requireEvidence(archiveRoot === resolve(archiveRoot) && archiveRoot !== dirname(archiveRoot));
    requireEvidence(archivePath === join(archiveRoot, id[1], archiveId));
    requireEvidence(!prompt.createdAt || prompt.createdAt.toISOString() === createdAt);
    requireEvidence(expected.source === "voice_ask" && (expected.mode === "vad" || expected.mode === "ptt"));
    requireEvidence(format.sampleRate === 16000 && format.channels === 1 && format.bitsPerSample === 16);
    requireEvidence(prompt.agentAudioFormat === "mp3" && prompt.agentAudioBytes.byteLength > 0);
    requireEvidence(prompt.agentTranscript.trim() && prompt.agentTtsEngine && prompt.agentTtsVoice.trim());
    const promptAudio = Buffer.from(prompt.agentAudioBytes);
    const promptText = Buffer.from(prompt.agentTranscript, "utf8");
    const wav = Buffer.from(expected.userWav);
    requireEvidence(wav.length > 44 && (wav.length - 44) % 2 === 0);
    requireEvidence(wav.toString("ascii", 0, 4) === "RIFF" && wav.toString("ascii", 8, 16) === "WAVEfmt ");
    requireEvidence(wav.toString("ascii", 36, 40) === "data" && wav.readUInt32LE(4) === wav.length - 8);
    requireEvidence(wav.readUInt32LE(16) === 16 && wav.readUInt16LE(20) === 1);
    requireEvidence(wav.readUInt16LE(22) === format.channels && wav.readUInt32LE(24) === format.sampleRate);
    requireEvidence(wav.readUInt32LE(28) === 32000 && wav.readUInt16LE(32) === 2);
    requireEvidence(wav.readUInt16LE(34) === format.bitsPerSample && wav.readUInt32LE(40) === wav.length - 44);

    function openSelected(path: string, directory: boolean) {
      const before = lstatSync(path);
      requireEvidence(!before.isSymbolicLink() && (directory ? before.isDirectory() : before.isFile()));
      requireEvidence(directory ? realpathSync(path) === path : before.nlink === 1);
      const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK |
        (directory ? constants.O_DIRECTORY : 0));
      owned.push(fd);
      const stat = fstatSync(fd);
      requireEvidence(before.dev === stat.dev && before.ino === stat.ino);
      requireEvidence(directory ? stat.isDirectory() : stat.isFile() && stat.nlink === 1);
      return { path, fd, stat };
    }
    const directories = [dirname(archiveRoot), archiveRoot, dirname(archivePath), archivePath]
      .map(path => openSelected(path, true));
    const names = ["agent-audio.mp3", "agent-transcript.txt", "audio.wav", "metadata.json"];
    const files = names.map(name => openSelected(join(archivePath, name), false));
    const [agentAudio, agentText, userAudio, metadataBytes] = files.map(file => readFileSync(file.fd));
    requireEvidence(agentAudio.equals(promptAudio) && agentText.equals(promptText) && userAudio.equals(wav));
    const metadata = metadataRecord(JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(metadataBytes)));
    const requiredMetadata = {
      id: archiveId, created_at: createdAt, source: expected.source, schema_version: 4,
      mode: expected.mode, sample_rate: format.sampleRate, channels: format.channels,
      retention_policy: "indefinite", agent_tts_engine: prompt.agentTtsEngine, agent_tts_voice: prompt.agentTtsVoice,
      agent_transcript_chars: prompt.agentTranscript.length, audio_sha256: digest(wav),
      user_audio_sha256: digest(wav), agent_audio_sha256: digest(promptAudio),
    };
    requireEvidence(Object.entries(requiredMetadata).every(([key, value]) => metadata[key] === value));
    requireEvidence(metadata.transcription_status === "captured" || metadata.transcription_status === "transcribed");
    const declared = metadataRecord(metadata.artifacts);
    const expectedNames = { agent_audio: names[0], agent_transcript: names[1], user_audio: names[2],
      user_transcript: "voicelayer-transcript.txt" };
    requireEvidence(Object.keys(declared).length === 4 && Object.entries(expectedNames)
      .every(([key, value]) => declared[key] === value));

    // Pin all selected descriptors until every strict sync and identity recheck finishes.
    for (const handle of [...files, ...directories.slice().reverse()]) fsyncSync(handle.fd);
    for (const handle of [...directories, ...files]) {
      const pathStat = lstatSync(handle.path);
      const current = fstatSync(handle.fd);
      requireEvidence(!pathStat.isSymbolicLink() && pathStat.dev === current.dev && pathStat.ino === current.ino);
      requireEvidence(current.dev === handle.stat.dev && current.ino === handle.stat.ino &&
        current.size === handle.stat.size && current.mtimeMs === handle.stat.mtimeMs && current.ctimeMs === handle.stat.ctimeMs);
    }
    requireEvidence(realpathSync(archivePath) === archivePath);
    evidence = Object.freeze({ kind: "verified-paired", archiveId, archivePath, audioStatus: "captured",
      transcriptStatus: "unverified", closureStatus: "closed", artifacts: Object.freeze({
        "agent-audio.mp3": artifact(agentAudio), "agent-transcript.txt": artifact(agentText),
        "audio.wav": artifact(userAudio), "metadata.json": artifact(metadataBytes),
      }) });
  } catch {
    evidence = undefined;
  } finally {
    // Close errors leave ownership ambiguous; never retry even if stat identity matches.
    for (const fd of owned.reverse()) {
      try { closeSync(fd); } catch { evidence = undefined; closureStatus = "unconfirmed"; }
    }
  }
  return evidence ?? { kind: "verification-unavailable", code: "paired-capture-verification-failed", closureStatus };
}
