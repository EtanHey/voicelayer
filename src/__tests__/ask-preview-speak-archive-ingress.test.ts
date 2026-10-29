import { flushSpeechArchives } from "../speech-archive-live";
import { speechArchiveWriter } from "../speech-archive-writer";
import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { createHash } from "crypto";
import * as fs from "fs";
const realOpenForArchiveFault = fs.openSync;
import { join, relative, resolve } from "path";
import * as archive from "../speak-archive";
import * as tts from "../tts";
import * as input from "../input";
import * as booking from "../session-booking";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import * as controls from "../tts-controls-status";
import { handleVoiceAsk, handleConverse } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
import { parseCommand } from "../socket-protocol";
import { createVoiceToolContext, type McpNotification } from "../mcp-notifications";
import { hasActiveVoiceOperation, reserveArchiveRetranscription } from "../voice-operation-reservation";
import { TTS_DISABLED_FILE } from "../paths";

const raw = " \t<speak>**Bun**\n\nשלום🙂 fu… no, full</speak>\r\n  ";
const sample = "Here is a sample of this voice. Clear speech, at your preferred pace.";
const realCreate = archive.createSpeakReceipt, realSpeak = tts.speak;
let root: string, savedRoot: string | undefined, fixture: string;
let contexts: archive.SpeakArchiveContext[], notifications: McpNotification[];
let spies: Array<{ mockRestore(): void }> = [];
let speak: ReturnType<typeof spyOn<typeof tts, "speak">>;
let capture: ReturnType<typeof spyOn<typeof input, "waitForInput">>;
let log: ReturnType<typeof spyOn<typeof console, "error">>;
let bookingSpy: ReturnType<typeof spyOn<typeof booking, "isVoiceBooked">>;
let stateSpy: ReturnType<typeof spyOn<typeof input, "getRecordingState">>;
let previewActive: boolean;
function setting<T>(effective: T): { source: "default"; raw: null; effective: T } {
  return { source: "default", raw: null, effective };
}
function disk(context = contexts[0]) {
  expect(context).toBeDefined(); // Direct baseline witness before any missing-context access.
  return JSON.parse(fs.readFileSync(join(context.path, "metadata.json"), "utf8"));
}
function retained(text: string, status: string) {
  expect(contexts).toHaveLength(1);
  expect(fs.readFileSync(join(contexts[0].path, "input.txt"))).toEqual(Buffer.from(text));
  expect(disk()).toMatchObject({ status, generation_id: null,
    input: { bytes: Buffer.byteLength(text), sha256: createHash("sha256").update(text).digest("hex") } });
  expect(disk().artifacts ?? []).toEqual([]);
  expect(disk().lifecycle?.summary.generated_audio_ms ?? null).toBeNull();
  expect(disk().lifecycle?.timing.first_player_start_ms ?? null).toBeNull();
  expect(fs.readdirSync(contexts[0].path).filter(name => !name.endsWith(".partial")).sort()).toEqual(["input.txt", "metadata.json"]);
}
const preview = (profile: "short" | "long" = "long") =>
  handleSocketCommand({ cmd: "preview_tts_profile", profile, id: "synthetic-preview" });

describe("Ask and Preview real receipt ingress (canonical preload; synthetic speech/capture)", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, redirected = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !redirected ||
        relative(resolve(run), resolve(redirected)).startsWith("..") || resolve(run) === resolve(redirected)) {
      throw new Error("canonical isolated preload required");
    }
    savedRoot = redirected; fixture = fs.mkdtempSync(join(redirected, "ask-preview-ingress-"));
    root = join(fixture, "recordings"); fs.mkdirSync(root, { mode: 0o700 });
    process.env.QA_VOICE_RECORDINGS_DIR = root;
    contexts = []; notifications = []; previewActive = false;
    stateSpy = spyOn(input, "getRecordingState").mockReturnValue("idle"); spies.push(stateSpy);
    bookingSpy = spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }); spies.push(bookingSpy);
    spies.push(spyOn(archive, "createSpeakReceipt").mockImplementation(request => {
      const result = realCreate(request);
      if (result.kind === "created") contexts.push(result.context);
      return result;
    }), spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(input, "clearInput").mockImplementation(() => {}),
    spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0),
    spyOn(socket, "isConnected").mockReturnValue(true),
    spyOn(socket, "broadcast").mockImplementation(() => {}));
    // Synthetic controls avoid the real status reader's network and voice-inventory probes.
    const setActive = controls.setTTSPreviewActive;
    const profile = { engine: setting<"edge" | "clone">("edge"), voice: setting("synthetic"),
      rate: setting("+0%"), last_first_audio_ms: null, last_first_audio: null };
    spies.push(spyOn(controls, "setTTSPreviewActive").mockImplementation(active => { previewActive = active; setActive(active); }),
      spyOn(controls, "readTTSControlsStatus").mockImplementation(() => ({ profiles: { short: profile, long: profile },
        short_limit_chars: setting(400), available_voices: [], clone_daemon: "down", preview_active: previewActive })));
    log = spyOn(console, "error").mockImplementation(() => {}); spies.push(log);
    speak = spyOn(tts, "speak").mockImplementation(async (text, options) => {
      expect(options?.archiveContext).toBe(contexts.at(-1));
      expect(contexts).toHaveLength(1);
      expect(fs.existsSync(join(contexts[0].path, "input.txt"))).toBe(true);
      for (const name of ["input.txt", "metadata.json"]) expect(fs.statSync(join(contexts[0].path, name)).mode & 0o777).toBe(0o600);
      expect(fs.statSync(contexts[0].path).mode & 0o777).toBe(0o700);
      expect(hasActiveVoiceOperation()).toBe(true);
      if (options?.measurementOrigin === "preview") expect(controls.readTTSControlsStatus().preview_active).toBe(true);
      return { playbackId: "synthetic-prompt", displayText: text, engine: "edge-tts", voice: "en-US-JennyNeural",
        audioArtifact: { bytes: new Uint8Array([0x49, 0x44, 0x33]), format: "mp3" } };
    }); spies.push(speak);
    capture = spyOn(input, "waitForInput").mockResolvedValue("synthetic answer"); spies.push(capture);
    fs.rmSync(TTS_DISABLED_FILE, { force: true });
  });
  afterEach(async () => {
    await flushSpeechArchives();
    expect(previewActive).toBe(false);
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    fs.rmSync(TTS_DISABLED_FILE, { force: true });
    if (savedRoot === undefined) delete process.env.QA_VOICE_RECORDINGS_DIR;
    else process.env.QA_VOICE_RECORDINGS_DIR = savedRoot;
    fs.rmSync(fixture, { recursive: true, force: true });
    expect(hasActiveVoiceOperation()).toBe(false);
  });

  for (const connection of ["stdio", "daemon", undefined] as const) it(`Ask retains exact bytes and one context: ${connection}`, async () => {
    const result = await handleVoiceAsk({ message: raw, voice: "en-US-JennyNeural", connection: "untrusted" },
      createVoiceToolContext(undefined, n => { notifications.push(n); }, connection));
    retained(raw, "received");
    expect(disk()).toMatchObject({ source: "speak", request_source: "ask_prompt", connection: connection ?? null,
      format: null, blocking: true, requested: { mode: "converse", profile: null, engine: null,
        voice: "en-US-JennyNeural", rate: null },
      build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
    expect(speak).toHaveBeenCalledTimes(1);
    expect(speak.mock.calls[0][0]).toBe(raw.trim());
    expect(speak.mock.calls[0][1]).toMatchObject({ mode: "converse", waitForPlayback: true, captureAudioArtifact: true });
    expect(capture).toHaveBeenCalledTimes(1);
    expect(capture.mock.calls[0].slice(0, 3)).toEqual([30000, "thoughtful", false]);
    expect(capture.mock.calls[0][3]?.voiceAskArtifacts?.agentTranscript).toBe(raw.trim());
    expect(result.content[0].text).toContain("synthetic answer");
    expect(JSON.stringify(notifications)).not.toContain("שלום");
  });
  for (const fault of ["directory", "unwritable"] as const) it(`Ask proceeds when its history marker is ${fault}`, async () => {
    const index = root + ".speech-history-v1";
    fs.mkdirSync(index, { mode: 0o700 });
    if (fault === "unwritable") fs.chmodSync(index, 0o500);
    else {
      const create = realCreate;
      spies.push(spyOn(archive, "createSpeakReceipt").mockImplementation(request => {
        const id = "2026-10-27T12-00-00-000Z-aabbccdd";
        fs.mkdirSync(join(index, id), { mode: 0o700 });
        const result = create(request, { now: () => new Date("2026-10-27T12:00:00Z"), id: () => id });
        if (result.kind === "created") contexts.push(result.context);
        return result;
      }));
    }
    try {
      const result = await handleVoiceAsk({ message: raw });
      expect(result.isError).not.toBe(true);
      expect(result.content[0].text).toContain("synthetic answer");
      expect(speak).toHaveBeenCalledTimes(1); expect(capture).toHaveBeenCalledTimes(1);
      retained(raw, "received");
      expect(log.mock.calls).toContainEqual(["[speech] history membership write failed"]);
    } finally { fs.chmodSync(index, 0o700); }
  });
  it("Ask retains overlong, reservation, booking and capture-admission refusals without speech", async () => {
    const long = raw + "x".repeat(601);
    expect((await handleVoiceAsk({ message: long })).isError).toBe(true); retained(long, "rejected"); contexts = [];
    const reservation = reserveArchiveRetranscription(); expect(reservation).not.toBeNull();
    try { expect((await handleVoiceAsk({ message: raw })).content[0].text).toContain("archive retranscription"); retained(raw, "rejected"); }
    finally { reservation?.release(); }
    contexts = [];
    bookingSpy.mockReturnValue({ booked: true, ownedByUs: false });
    expect((await handleVoiceAsk({ message: raw })).isError).toBe(true); retained(raw, "rejected"); contexts = [];
    bookingSpy.mockReturnValue({ booked: true, ownedByUs: true });
    const admission = tts.reserveCaptureAdmission(); expect(admission).not.toBeNull();
    try { expect((await handleVoiceAsk({ message: raw })).content[0].text).toContain("capture admission"); retained(raw, "rejected"); }
    finally { admission?.release(); }
    expect(speak).not.toHaveBeenCalled(); expect(capture).not.toHaveBeenCalled();
  });
  for (const stopped of [false, true]) it(`Ask retains prompt preparation failure: stopped=${stopped}`, async () => {
    speak.mockRejectedValue(stopped ? new tts.SpeechPreparationStoppedError() : new Error("synthetic preparation failed"));
    const result = await handleVoiceAsk({ message: raw });
    retained(raw, stopped ? "stopped" : "failed"); expect(capture).not.toHaveBeenCalled();
    expect(result.content[0].text.toLowerCase()).toContain(stopped ? "stopped" : "synthetic preparation failed");
  });
  for (const failure of ["speaker", "post-booking", "book-failure", "admission-race"] as const)
    it(`Ask retains early ${failure} refusal without capture`, async () => {
      if (failure === "speaker") spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("recording"));
      if (failure === "post-booking") bookingSpy.mockReturnValueOnce({ booked: false, ownedByUs: false })
        .mockReturnValue({ booked: true, ownedByUs: false });
      if (failure === "book-failure") {
        bookingSpy.mockReturnValue({ booked: false, ownedByUs: false });
        spies.push(spyOn(booking, "bookVoiceSession").mockReturnValue({ success: false, error: "synthetic booking refused" }));
      }
      if (failure === "admission-race") spies.push(spyOn(tts, "reserveCaptureAdmission").mockReturnValue(undefined));
      expect((await handleVoiceAsk({ message: raw })).isError).toBe(true);
      retained(raw, "rejected"); expect(speak).not.toHaveBeenCalled(); expect(capture).not.toHaveBeenCalled();
    });
  for (const failure of ["timeout", "recording-error"] as const) it(`Ask capture ${failure} preserves received prompt evidence`, async () => {
    if (failure === "timeout") capture.mockResolvedValue(null);
    else capture.mockRejectedValue(new Error("synthetic recording failed"));
    const result = await handleVoiceAsk({ message: raw });
    retained(raw, "received"); expect(disk()).not.toHaveProperty("lifecycle");
    expect(capture).toHaveBeenCalledTimes(1); expect(speak).toHaveBeenCalledTimes(1);
    expect(result.content[0].text).toContain(failure === "timeout" ? "timeout after 30s" : "synthetic recording failed");
  });
  it("invalid Ask and silent retranscription create no prompt receipt; direct Converse stays compatible", async () => {
    for (const args of [null, {}, { message: 1 }, { message: " \n" }, { message: raw, timeout_seconds: 1 }])
      expect((await handleVoiceAsk(args)).isError).toBe(true);
    const retranscribe = spyOn(input, "retranscribeVoiceAskArchive").mockResolvedValue("synthetic recovered answer"); spies.push(retranscribe);
    await handleVoiceAsk({ retranscribe_archive_id: "2026-10-25T00-00-00-000Z-aabbccdd" });
    expect(contexts).toEqual([]); expect(speak).not.toHaveBeenCalled();
    speak.mockResolvedValue({ displayText: "direct", engine: "edge-tts", voice: "en-US-JennyNeural",
      audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } });
    expect((await handleConverse({ message: "direct" })).isError).not.toBe(true);
    expect(contexts).toEqual([]); expect(capture).toHaveBeenCalledTimes(1);
  });
  for (const profile of ["short", "long"] as const) it(`Preview retains the fixed sample once with profile ${profile} and cleanup`, async () => {
    expect(await preview(profile)).toMatchObject({ type: "ack", command: "preview_tts_profile", id: "synthetic-preview",
      outcome: "accept", tts_controls: { preview_active: false } });
    retained(sample, "received");
    expect(disk()).toMatchObject({ request_source: "preview", connection: null, format: "plain", blocking: true,
      requested: { mode: null, profile, engine: null, voice: null, rate: null } });
    expect(speak.mock.calls[0][0]).toBe(sample);
    expect(speak.mock.calls[0][1]).toMatchObject({ profile, waitForPlayback: true, measurementOrigin: "preview" });
    expect(speak).toHaveBeenCalledTimes(1); expect(capture).not.toHaveBeenCalled();
    expect(parseCommand('{"cmd":"preview_tts_profile","profile":"auto"}')).toBeNull();
  });
  it("Preview retains busy and failed requests with original ack and reservation cleanup", async () => {
    stateSpy.mockReturnValue("recording");
    expect(await preview()).toMatchObject({ outcome: "reject", reason: "Recording in progress" });
    retained(sample, "rejected"); expect(speak).not.toHaveBeenCalled(); stateSpy.mockReturnValue("idle"); contexts = [];
    speak.mockRejectedValue(new Error("synthetic preparation failed"));
    expect(await preview()).toMatchObject({ outcome: "reject", reason: "synthetic preparation failed", tts_controls: { preview_active: false } });
    retained(sample, "failed");
  });
  it("Preview retains a reservation refusal without clearing its owner", async () => {
    const reservation = reserveArchiveRetranscription(); expect(reservation).not.toBeNull();
    try {
      expect(await preview()).toMatchObject({ outcome: "reject", reason: "Voice session in progress", tts_controls: { preview_active: false } });
      retained(sample, "rejected"); expect(hasActiveVoiceOperation()).toBe(true); expect(speak).not.toHaveBeenCalled();
    } finally { reservation?.release(); }
  });
  it("Preview preparation Stop retains stopped evidence and original rejection", async () => {
    speak.mockRejectedValue(new tts.SpeechPreparationStoppedError());
    expect(await preview()).toMatchObject({ outcome: "reject", reason: "Stopped by the user before playback.", tts_controls: { preview_active: false } });
    retained(sample, "stopped"); expect(capture).not.toHaveBeenCalled();
  });
  for (const surface of ["Ask", "Preview"] as const) it(`${surface} speaker refusal during preparation retains rejected evidence`, async () => {
    speak.mockRejectedValue(new Error(tts.SPEAKER_OUTPUT_REFUSED_MESSAGE));
    const result = surface === "Ask" ? await handleVoiceAsk({ message: raw }) : await preview();
    await flushSpeechArchives();
    retained(surface === "Ask" ? raw : sample, "rejected"); expect(capture).not.toHaveBeenCalled();
    expect(JSON.stringify(result)).toContain(tts.SPEAKER_OUTPUT_REFUSED_MESSAGE);
  });
  for (const surface of ["Ask", "Preview"] as const) it(`${surface} queued playback failure does not fabricate synthesis failure`, async () => {
    speak.mockImplementation(async (_text, options) => {
      options?.onPlaybackQueued?.({ id: "synthetic-queued", generation: 1,
        exited: Promise.resolve({ type: "playback_outcome", playback_id: "synthetic-queued", status: "failed", stopped_at_ms: 0, progress: 0 }),
        playerExited: Promise.resolve(), waitForPlayerExit: async () => {} });
      throw new Error("synthetic player failed");
    });
    if (surface === "Ask") await handleVoiceAsk({ message: raw }); else await preview();
    retained(surface === "Ask" ? raw : sample, "received"); expect(disk()).not.toHaveProperty("lifecycle");
    expect(capture).not.toHaveBeenCalled(); expect(speak).toHaveBeenCalledTimes(1);
  });
  for (const surface of ["Ask", "Preview"] as const) it(`${surface} disabled TTS retains rejected evidence`, async () => {
    fs.writeFileSync(TTS_DISABLED_FILE, "1"); speak.mockImplementation(realSpeak);
    const result = surface === "Ask" ? await handleVoiceAsk({ message: raw }) : await preview();
    await flushSpeechArchives();
    retained(surface === "Ask" ? raw : sample, "rejected"); expect(capture).not.toHaveBeenCalled();
    expect(JSON.stringify(result)).toContain(surface === "Ask" ? "recording was not started" : "No preview audio was played");
  });
  for (const surface of ["Ask", "Preview"] as const) it(`${surface} initial archive failure refuses speech with fixed diagnostic`, async () => {
    const write = spyOn(fs, "openSync").mockImplementation(((file: any, ...args: any[]) => { if (String(file).startsWith(root + "/")) throw new Error(`private ${root} ${raw}`); return (realOpenForArchiveFault as any)(file, ...args); }) as any); spies.push(write);
    const result = surface === "Ask" ? await handleVoiceAsk({ message: raw }) : await preview();
    expect(JSON.stringify(result)).toContain("input archive unavailable (IO_ERROR)");
    expect(JSON.stringify(result)).not.toContain(root); expect(JSON.stringify(result)).not.toContain("שלום");
    expect(speak).not.toHaveBeenCalled(); expect(capture).not.toHaveBeenCalled();
  });
  for (const surface of ["Ask", "Preview"] as const) it(`${surface} disabled TTS and late archive failure retain original evidence`, async () => {
    fs.writeFileSync(TTS_DISABLED_FILE, "1"); speak.mockImplementation(realSpeak);
    const fault = spyOn(speechArchiveWriter, "write").mockRejectedValue(new Error(`private ${root} ${raw}`)); spies.push(fault);
    const result = surface === "Ask" ? await handleVoiceAsk({ message: raw }) : await preview();
    await flushSpeechArchives();
    retained(surface === "Ask" ? raw : sample, "received"); expect(capture).not.toHaveBeenCalled();
    expect(JSON.stringify(result)).not.toContain(root);
    const logs = log.mock.calls.flat().join(" ");
    expect(logs).toContain("[speech] archive write failed: move");
    expect(logs).not.toContain(root); expect(logs).not.toContain("שלום");
  });
});
