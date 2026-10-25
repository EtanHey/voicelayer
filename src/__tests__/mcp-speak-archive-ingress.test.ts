import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { createHash } from "crypto";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import * as archive from "../speak-archive";
import { recoverSpeakArchive, updateSpeakLifecycle } from "../speak-archive-store";
import * as tts from "../tts";
import * as health from "../tts-health";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import * as launcher from "../voice-bar-launcher";
import { TTS_DISABLED_FILE } from "../paths";
import { handleVoiceSpeak, handleToggle } from "../handlers";
import { createVoiceToolContext, type McpNotification } from "../mcp-notifications";
import { reserveArchiveRetranscription, hasActiveVoiceOperation } from "../voice-operation-reservation";
import { __resetBinarySpawnForTests } from "../resolve-binary";
import { formatSpeak } from "../format-response";
import { sanitizeTtsText } from "../sanitize";
import { SPEAK_TEXT_MAX_CHARS } from "../socket-protocol";

const raw = " \t<speak>**Bun**\n\nשלום🙂 fu… no, full</speak>\r\n  ";
const realCreate = archive.createSpeakReceipt, realSpeak = tts.speak;
let fixture: string, root: string, saved: Record<string, string | undefined>;
let contexts: archive.SpeakArchiveContext[], notifications: McpNotification[], synthesized: string[];
let spies: Array<ReturnType<typeof spyOn>> = [];
let errorLog: ReturnType<typeof spyOn>;
let failSynthesis = false;

function disk(context = contexts[0]) {
  return JSON.parse(fs.readFileSync(join(context.path, "metadata.json"), "utf8"));
}
function entries() {
  return fs.readdirSync(root).flatMap(day => fs.readdirSync(join(root, day)));
}
function noAudio(status: string) {
  expect(contexts).toHaveLength(1);
  const m = disk();
  expect(m.status).toBe(status);
  expect(m.generation_id).toBeNull();
  expect(m.lifecycle.summary.generated_audio_ms).toBeNull();
  expect(m.lifecycle.timing.first_player_start_ms).toBeNull();
  expect(m.lifecycle.played_spans).toEqual([]);
  expect(m.artifacts).toEqual([]);
  expect(fs.readdirSync(contexts[0].path).sort()).toEqual(["input.txt", "metadata.json"]);
  expect(fs.readFileSync(join(contexts[0].path, "input.txt"), "utf8")).toBe(raw);
}

describe("MCP raw speak ingress (canonical preload, synthetic adapters only)", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, redirected = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !redirected ||
        relative(resolve(run), resolve(redirected)).startsWith("..") || resolve(run) === resolve(redirected)) {
      throw new Error("canonical isolated preload required");
    }
    const keys = ["QA_VOICE_RECORDINGS_DIR", "QA_VOICE_PRONUNCIATION_PATH", "VOICELAYER_TTS_SETTINGS_PATH",
      "QA_VOICE_TTS_VOICE", "QA_VOICE_TTS_RATE", "QA_VOICE_TTS_REQUIRE_CLONE"];
    saved = Object.fromEntries(keys.map(key => [key, process.env[key]]));
    fixture = fs.mkdtempSync(join(redirected, "mcp-ingress-"));
    root = join(fixture, "recordings"); fs.mkdirSync(root, { mode: 0o700 });
    process.env.QA_VOICE_RECORDINGS_DIR = root;
    process.env.QA_VOICE_PRONUNCIATION_PATH = join(fixture, "pronunciation.yaml");
    process.env.VOICELAYER_TTS_SETTINGS_PATH = join(fixture, "settings.json");
    fs.writeFileSync(process.env.QA_VOICE_PRONUNCIATION_PATH, 'tech:\n  Bun: "bun runtime"\n');
    fs.writeFileSync(process.env.VOICELAYER_TTS_SETTINGS_PATH, JSON.stringify({ profiles: { short: { engine: "edge" } } }));
    process.env.QA_VOICE_TTS_VOICE = "en-US-JennyNeural";
    delete process.env.QA_VOICE_TTS_RATE; delete process.env.QA_VOICE_TTS_REQUIRE_CLONE;
    contexts = []; notifications = []; synthesized = []; failSynthesis = false;
    __resetBinarySpawnForTests();
    spies.push(spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}),
      spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(socket, "broadcast").mockImplementation(() => {}));
    errorLog = spyOn(console, "error").mockImplementation(() => {}); spies.push(errorLog);
    spies.push(spyOn(archive, "createSpeakReceipt").mockImplementation(request => {
      const result = realCreate(request);
      if (result.kind === "created") contexts.push(result.context);
      return result;
    }), spyOn(tts, "speak").mockImplementation((message, options) => {
      expect(options?.archiveContext).toBe(contexts.at(-1));
      return realSpeak(message, options);
    }));
    spies.push(spyOn(health, "synthesizeWithRetry").mockImplementation(async (text, _voice, _rate, audioFile) => {
      // Causal check: durable original input exists before the engine sees its projection.
      expect(fs.readFileSync(join(contexts.at(-1)!.path, "input.txt"), "utf8")).toContain("Bun");
      if (failSynthesis) throw new Error("synthetic engine unavailable");
      synthesized.push(text); fs.writeFileSync(audioFile, "synthetic mp3");
      return { success: true, attempts: 1, audioFile, wordBoundaries: [], durationMs: 1000 };
    }));
    // Same deterministic subprocess boundary fixtures as tts-settings-wiring; never delegate to a real child.
    spies.push(spyOn(Bun, "spawn").mockImplementation(((cmd: string[]) => ({
      pid: 89999, exited: Promise.resolve(0), kill() {},
      stdout: new Blob([cmd[0] === "which" ? "ffmpeg\n" : new Uint8Array([0, 0])]).stream(),
    })) as never), spyOn(Bun, "spawnSync").mockImplementation(((cmd: string[]) => ({
      exitCode: 0, stdout: Buffer.from(cmd[0] === "which" ? `${cmd[1]}\n` : "1.0"), stderr: Buffer.alloc(0),
    })) as never));
    fs.rmSync(TTS_DISABLED_FILE, { force: true });
  });
  afterEach(async () => {
    tts.stopPlayback(); await tts.awaitCurrentPlayback();
    fs.rmSync(TTS_DISABLED_FILE, { force: true });
    for (const key of ["QA_VOICE_PRONUNCIATION_PATH", "VOICELAYER_TTS_SETTINGS_PATH"]) {
      if (process.env[key]) fs.rmSync(process.env[key]!, { force: true });
    }
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    fs.rmSync(fixture, { recursive: true, force: true });
    __resetBinarySpawnForTests();
  });

  for (const [requested, suffix, effective] of [
    ["announce", "", "announce"], ["brief", "", "brief"], ["consult", "", "consult"],
    ["auto", "", "announce"], ["auto", "?", "consult"], ["auto", " more".repeat(60), "brief"],
    [undefined, "", "announce"], ["unknown-mode", "", "announce"],
  ] as const) it(`retains original bytes once: ${requested ?? "default"}/${effective}/${suffix.length}`, async () => {
    const input = raw + suffix;
    const context = createVoiceToolContext(undefined, n => { notifications.push(n); }, "stdio");
    const result = await handleVoiceSpeak({ message: input, mode: requested, rate: "+020%", voice: "en-US-JennyNeural" }, context);
    await tts.awaitCurrentPlayback();
    expect(entries()).toHaveLength(1); expect(contexts).toHaveLength(1);
    expect(fs.readFileSync(join(contexts[0].path, "input.txt"))).toEqual(Buffer.from(input));
    expect(disk()).toMatchObject({ source: "speak", request_source: "voice_speak", connection: "stdio",
      format: null, blocking: false, status: "completed", generation_id: null,
      input: { bytes: Buffer.byteLength(input), sha256: createHash("sha256").update(input).digest("hex") },
      requested: { mode: requested ?? null, profile: null, engine: null, voice: "en-US-JennyNeural", rate: null, rate_raw: "+020%" },
      build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
    expect(disk()).not.toHaveProperty("effective");
    expect(disk().speech.state).toBe("completed");
    expect(disk().speech.generated.map((g: { text: string }) => g.text).join(" ")).toBe(synthesized.join(" "));
    expect(disk().artifacts).toHaveLength(1);
    expect(fs.readFileSync(join(contexts[0].path, disk().artifacts[0].relative_path), "utf8")).toBe("synthetic mp3");
    const outcome = notifications[0]?.params.data;
    if (!outcome || typeof outcome !== "object" || !("playback_id" in outcome)) throw new Error("missing playback notification");
    expect(result.content[0].text).toBe(formatSpeak(effective, sanitizeTtsText(input), undefined, String(outcome.playback_id)));
    expect(synthesized.join(" ")).toContain("bun runtime");
    expect(synthesized.join(" ")).not.toContain("<speak>");
    expect(hasActiveVoiceOperation()).toBe(false);
    expect(notifications).toHaveLength(1);
    expect(JSON.stringify(notifications)).not.toContain("שלום");
    const telemetry = errorLog.mock.calls.flat().join(" ");
    expect(telemetry).not.toContain("שלום"); expect(telemetry).not.toContain(root);
    for (const name of ["input.txt", "metadata.json"]) expect(fs.statSync(join(contexts[0].path, name)).mode & 0o777).toBe(0o600);
    expect(fs.statSync(contexts[0].path).mode & 0o777).toBe(0o700);
  });

  it("retains exact raw rate through creator, lifecycle parse and recovery; absent field stays absent", async () => {
    await handleVoiceSpeak({ message: raw, rate: "-005%" }); await tts.awaitCurrentPlayback();
    const context = contexts[0];
    expect(updateSpeakLifecycle(context, { status: "preparing", generation_id: null,
      timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
      summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: null }, played_spans: [] })).toEqual({ kind: "failed", code: "FINALIZED" });
    expect(disk().requested.rate_raw).toBe("-005%");
    expect(recoverSpeakArchive(context.id).kind).toBe("stored");
    expect(disk().requested).toMatchObject({ rate: null, rate_raw: "-005%" });
    await handleVoiceSpeak({ message: raw }); await tts.awaitCurrentPlayback();
    expect(recoverSpeakArchive(contexts[1].id).kind).toBe("stored");
    expect(disk(contexts[1]).requested).not.toHaveProperty("rate_raw");
    expect(contexts[1].metadata.request_id).not.toBe(context.metadata.request_id);
  });

  for (const connection of ["stdio", "daemon", undefined] as const) it(`records explicit transport or unknown: ${connection}`, async () => {
    const context = createVoiceToolContext(undefined, undefined, connection);
    await handleVoiceSpeak({ message: raw, connection: "untrusted", format: "markdown", token: "synthetic-secret" }, context);
    await tts.awaitCurrentPlayback();
    expect(disk().connection).toBe(connection ?? null); expect(disk().format).toBeNull();
    expect(JSON.stringify(disk())).not.toContain("synthetic-secret");
    // Entry modules are read as source, never imported (they own the resident daemon lifecycle).
    expect(fs.readFileSync(new URL("../mcp-server.ts", import.meta.url), "utf8")).toContain('}, "stdio");');
    expect(fs.readFileSync(new URL("../mcp-server-daemon.ts", import.meta.url), "utf8")).toContain('connection: "daemon"');
  });

  for (const mode of ["announce", "brief", "consult", "auto", "unknown-mode"] as const) {
    it(`refuses oversized original padding before receipt allocation or synthesis: ${mode}`, async () => {
      const input = raw + " ".repeat(SPEAK_TEXT_MAX_CHARS + 1 - raw.length);
      const result = await handleVoiceSpeak({ message: input, mode });
      expect(input.length).toBe(SPEAK_TEXT_MAX_CHARS + 1);
      expect(result).toEqual({ isError: true, content: [{ type: "text",
        text: "voice_speak refused: raw input exceeds archive admission limit" }] });
      expect(archive.createSpeakReceipt).not.toHaveBeenCalled();
      expect(tts.speak).not.toHaveBeenCalled();
      expect(health.synthesizeWithRetry).not.toHaveBeenCalled();
      expect(entries()).toEqual([]); expect(contexts).toEqual([]);
      expect(notifications).toEqual([]); expect(synthesized).toEqual([]);
      expect(hasActiveVoiceOperation()).toBe(false);
    });
  }

  for (const length of [SPEAK_TEXT_MAX_CHARS - 1, SPEAK_TEXT_MAX_CHARS]) {
    it(`admits exact original Unicode and whitespace bytes at raw length ${length}`, async () => {
      const input = raw + " ".repeat(length - raw.length);
      const result = await handleVoiceSpeak({ message: input });
      await tts.awaitCurrentPlayback();
      expect(input.length).toBe(length); expect(result.isError).toBeUndefined();
      expect(entries()).toHaveLength(1); expect(contexts).toHaveLength(1);
      expect(fs.readFileSync(join(contexts[0].path, "input.txt"))).toEqual(Buffer.from(input));
      expect(disk().input).toEqual({ bytes: Buffer.byteLength(input),
        sha256: createHash("sha256").update(input).digest("hex") });
      expect(synthesized.join(" ")).toContain("bun runtime");
    });
  }

  for (const length of [1201, SPEAK_TEXT_MAX_CHARS]) {
    it(`retains the ordinary speech-policy rejection receipt at raw length ${length}`, async () => {
      const input = "Bun " + "x".repeat(length - 4);
      const result = await handleVoiceSpeak({ message: input });
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("the limit is 1,200");
      expect(contexts).toHaveLength(1); expect(entries()).toHaveLength(1);
      expect(disk().status).toBe("rejected");
      expect(fs.readFileSync(join(contexts[0].path, "input.txt"))).toEqual(Buffer.from(input));
      expect(tts.speak).not.toHaveBeenCalled();
      expect(synthesized).toEqual([]);
    });
  }

  it("keeps explicit and auto-detected silent think exempt from raw speech admission", async () => {
    const input = "insight: Bun " + "x".repeat(SPEAK_TEXT_MAX_CHARS);
    for (const mode of ["think", "auto"] as const) {
      expect((await handleVoiceSpeak({ message: input, mode })).isError).toBeUndefined();
    }
    expect(archive.createSpeakReceipt).not.toHaveBeenCalled();
    expect(entries()).toEqual([]); expect(synthesized).toEqual([]);
  });

  it("retains overlong and admission-backpressure refusals before synthesis", async () => {
    const long = raw + "x".repeat(1201);
    expect((await handleVoiceSpeak({ message: long })).isError).toBe(true);
    expect(disk().status).toBe("rejected");
    expect(fs.readFileSync(join(contexts[0].path, "input.txt"), "utf8")).toBe(long);
    contexts = [];
    const reservation = reserveArchiveRetranscription(); expect(reservation).not.toBeNull();
    try {
      const result = await handleVoiceSpeak({ message: raw });
      expect(result.content[0].text).toContain("archive retranscription"); noAudio("rejected");
      expect(hasActiveVoiceOperation()).toBe(true);
    } finally { reservation?.release(); }
    expect(synthesized).toEqual([]); expect(hasActiveVoiceOperation()).toBe(false);
  });

  it("keeps disabled and synthesis-failed inputs without claiming audio or completion", async () => {
    await handleToggle({ enabled: false, scope: "tts" });
    const result = await handleVoiceSpeak({ message: raw });
    expect(result.content[0].text).toBe(formatSpeak("announce", sanitizeTtsText(raw))); noAudio("rejected");
    await handleToggle({ enabled: true, scope: "tts" }); contexts = []; failSynthesis = true;
    await expect(handleVoiceSpeak({ message: raw })).rejects.toThrow("synthetic engine unavailable");
    noAudio("failed"); expect(hasActiveVoiceOperation()).toBe(false);
  });

  it("refuses synthesis if initial persistence fails and exposes only an allowlisted error", async () => {
    const write = spyOn(fs, "writeFileSync").mockImplementation(() => { throw new Error(`private ${root} ${raw}`); });
    try {
      const result = await handleVoiceSpeak({ message: raw, token: "synthetic-secret" });
      expect(result.isError).toBe(true); expect(result.content[0].text).toContain("input archive unavailable (IO_ERROR)");
      expect(JSON.stringify(result)).not.toContain(root); expect(JSON.stringify(result)).not.toContain(raw);
      expect(JSON.stringify(notifications)).not.toContain("synthetic-secret"); expect(synthesized).toEqual([]);
    } finally { write.mockRestore(); }
  });

  it("keeps stopped preparation and sanitized-empty requests without inventing generation", async () => {
    const synth = spyOn(health, "synthesizeWithRetry").mockRejectedValue(new tts.SpeechPreparationStoppedError());
    try {
      expect((await handleVoiceSpeak({ message: raw })).content[0].text).toBe("Stopped by the user before playback.");
      noAudio("stopped"); expect(hasActiveVoiceOperation()).toBe(false);
    } finally { synth.mockRestore(); }
    contexts = [];
    expect((await handleVoiceSpeak({ message: "<speak></speak>" })).isError).toBe(true);
    expect(contexts).toHaveLength(1); expect(disk().status).toBe("rejected");
  });

  for (const [error, status, code] of [
    [new Error(tts.SPEAKER_OUTPUT_REFUSED_MESSAGE), "rejected", "REJECTED"],
    [new tts.SpeechPreparationStoppedError(), "stopped", null],
    [new Error("synthetic output unavailable"), "failed", "OUTPUT_UNAVAILABLE"],
  ] as const) it(`persists MCP preparation outcome: ${status}/${code}`, async () => {
    const speak = spyOn(tts, "speak").mockRejectedValue(error);
    try {
      if (error instanceof tts.SpeechPreparationStoppedError) {
        expect(await handleVoiceSpeak({ message: raw })).toEqual({
          content: [{ type: "text", text: error.message }],
        });
      } else {
        await expect(handleVoiceSpeak({ message: raw })).rejects.toBe(error);
      }
      expect(speak).toHaveBeenCalledTimes(1);
      noAudio(status);
      expect(disk().lifecycle.summary.error_code).toBe(code);
      expect(entries()).toHaveLength(1);
      expect(synthesized).toEqual([]); expect(notifications).toEqual([]);
      expect(hasActiveVoiceOperation()).toBe(false);
    } finally { speak.mockRestore(); }
  });

  it("keeps the prior receipt when a late lifecycle write fails; logs no path, input or arbitrary exception", async () => {
    await handleToggle({ enabled: false, scope: "tts" });
    const rename = fs.renameSync;
    const fail = spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(from).endsWith(".partial")) throw new Error(`private ${root} ${raw}`);
      rename(from, to);
    });
    const log = spyOn(console, "error");
    try {
      await expect(handleVoiceSpeak({ message: raw })).rejects.toThrow("Speech archive transition: WRITE_UNCERTAIN");
      expect(disk().status).toBe("received");
      expect(log.mock.calls.flat().join(" ")).toContain("speak archive update failed: WRITE_UNCERTAIN");
      expect(log.mock.calls.flat().join(" ")).not.toContain(root);
      expect(log.mock.calls.flat().join(" ")).not.toContain(raw);
    } finally { fail.mockRestore(); log.mockRestore(); }
  });

  it("creates no receipts for invalid/blank inputs or silent think/toggle/replay", async () => {
    for (const args of [null, {}, { message: 2 }, { message: " \n\t" }, { message: raw, rate: "fast" }]) {
      expect((await handleVoiceSpeak(args)).isError).toBe(true);
    }
    await handleVoiceSpeak({ message: raw, mode: "think" });
    await handleVoiceSpeak({ message: "insight: synthetic silent note" });
    await handleVoiceSpeak({ enabled: true, scope: "tts", message: raw });
    const history = spyOn(tts, "getHistoryEntry").mockReturnValue(null);
    try { await handleVoiceSpeak({ replay_index: 0, message: raw }); } finally { history.mockRestore(); }
    expect(entries()).toEqual([]); expect(contexts).toEqual([]); expect(synthesized).toEqual([]);
  });
});
