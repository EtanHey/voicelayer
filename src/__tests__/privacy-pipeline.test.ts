import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { describeMicTouching } from "./setup/live-host-guard";
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { basename, join } from "path";
import * as stt from "../stt";
import * as vad from "../vad";
import * as socket from "../socket-client";
import * as launcher from "../voice-bar-launcher";
import { handleVoiceAsk } from "../handlers";
import { speakText, awaitCurrentPlayback, stopPlayback, loadHistory } from "../tts";
import { releaseVoiceSession } from "../session-booking";

// Run only under the parent process guard. All orchestration above OS/provider
// boundaries is real, including Ask's speak -> waitForInput -> archive/error flow.
(process.env.PRIV11_CHILD ? describeMicTouching : describe.skip)("PRIV11 real pipelines", () => {
  const spawn = Bun.spawn, spawnSync = Bun.spawnSync;
  let spies: ReturnType<typeof spyOn>[];
  let events: any[], synthTexts: string[], recorders: number, sttCalls: number, players: number;
  let vadCalls: number;
  const text = () => process.env.PRIV11_TEXT!;
  const child = (extra: object = {}) => ({ pid: 987654, exited: Promise.resolve(0),
    stdout: new Blob([]).stream(), stderr: new Blob([]).stream(), kill() {}, ...extra });

  beforeEach(() => {
    spies = []; events = []; synthTexts = []; recorders = 0; sttCalls = 0; players = 0; vadCalls = 0;
    spies.push(spyOn(socket, "isConnected").mockReturnValue(true));
    spies.push(spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); }));
    spies.push(spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}));
    spies.push(spyOn(vad, "resetVAD").mockResolvedValue());
    spies.push(spyOn(vad, "processVADChunk").mockImplementation(async () => ++vadCalls <= 24 ? 0.95 : 0));
    spies.push(spyOn(stt, "getBackend").mockResolvedValue({ name: "canary-stt", isAvailable: async () => true,
      transcribe: async () => { sttCalls++; return { text: text() + ".", backend: "canary-stt", durationMs: 1 }; } }));
    // Fail closed: no unknown subprocess can reach a microphone, speaker or network.
    Bun.spawnSync = ((argv: string[]) => {
      if (argv[0] === "which") return { exitCode: 0, stdout: Buffer.from(argv[1]), stderr: Buffer.alloc(0) };
      if (basename(argv[0]) === "ffprobe") return { exitCode: 0, stdout: Buffer.from("1\n"), stderr: Buffer.alloc(0) };
      if (argv[0].endsWith("fake-rec.sh") || argv[0] === "rec")
        return { exitCode: 0, stdout: Buffer.alloc(0), stderr: Buffer.from("Sample Rate : 16000\nChannels : 1\n") };
      throw new Error("Unexpected sync subprocess in privacy fixture: " + argv[0]);
    }) as any;
    Bun.spawn = ((argv: string[]) => {
      if (argv[0] === "which") return child({ stdout: new Blob([argv[1]]).stream() });
      if (argv[1] === "-version") return child();
      if (argv.some(a => a.startsWith("--text="))) {
        const spoken = argv.find(a => a.startsWith("--text="))!.slice(7);
        synthTexts.push(spoken);
        writeFileSync(argv.find(a => a.startsWith("--write-media="))!.slice(14), "fake audio");
        writeFileSync(argv.find(a => a.startsWith("--write-metadata="))!.slice(17),
          JSON.stringify({ text: spoken, offset: 0, duration: 1000000 }));
        return child();
      }
      if (argv[0].endsWith("fake-rec.sh") || argv[0] === "rec") {
        recorders++;
        const pcm = new Int16Array(512 * 48).fill(1800);
        return child({ stdout: new ReadableStream({ start(controller) {
          for (let i = 0; i < 48; i++) controller.enqueue(new Uint8Array(pcm.buffer, i * 1024, 1024));
          controller.close();
        } }) });
      }
      if (basename(argv[0]) === "ffmpeg") {
        if (argv.at(-1) !== "pipe:1") writeFileSync(argv.at(-1)!, "fake audio");
        return child({ stdout: new Blob([new Uint8Array(8)]).stream() });
      }
      if (["afplay", "paplay", "aplay"].includes(basename(argv[0]))) { players++; return child(); }
      throw new Error("Unexpected subprocess in privacy fixture: " + argv[0]);
    }) as any;
  });
  afterEach(async () => {
    stopPlayback(); await awaitCurrentPlayback(); releaseVoiceSession();
    for (const spy of spies) spy.mockRestore();
    Bun.spawn = spawn; Bun.spawnSync = spawnSync;
  });

  it("Ask answer crosses the real handler, capture, STT, archive and MCP return", async () => {
    const result = await handleVoiceAsk({ message: text(), timeout_seconds: 5, silence_mode: "quick" });
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain(text());
    expect(recorders).toBe(1); expect(sttCalls).toBe(1); expect(players).toBeGreaterThan(0);
    expect(synthTexts.length).toBeGreaterThan(0);
    const event = events.find(e => e.type === "transcription");
    expect(event.text).toContain(text());
    expect(readFileSync(event.recording_path.replace("audio.wav", "voicelayer-transcript.txt"), "utf8")).toContain(text());
    expect(readFileSync(event.recording_path.replace("audio.wav", "agent-transcript.txt"), "utf8")).toBe(text());
  }, 15_000);

  it("Ask archive failure keeps path detail in MCP errors and no diagnostic", async () => {
    const saved = process.env.QA_VOICE_RECORDINGS_DIR!;
    const blocked = join(process.env.PRIV11_PRIVATE_ROOT!, `CANARY-HOME-${process.env.PRIV11_NONCE}`, "blocked");
    mkdirSync(join(blocked, ".."), { recursive: true }); writeFileSync(blocked, "not a directory");
    process.env.QA_VOICE_RECORDINGS_DIR = blocked;
    try {
      const result = await handleVoiceAsk({ message: text(), timeout_seconds: 5, silence_mode: "quick" });
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("voice_ask archive failed:");
      expect(result.content[0].text).toContain(blocked);
      expect(recorders).toBe(1); expect(sttCalls).toBe(0); expect(players).toBeGreaterThan(0);
    } finally { process.env.QA_VOICE_RECORDINGS_DIR = saved; }
  }, 15_000);

  it("selection crosses real speakText, synthesis, player queue and private history", async () => {
    const selected = text() + " selection.";
    const read = speakText(selected, "short");
    await read.done;
    expect(await read.completion).toEqual({});
    expect(synthTexts.length).toBeGreaterThan(0); expect(players).toBeGreaterThan(0);
    expect(events.some(e => e.state === "speaking" && e.text === selected)).toBe(true);
    const history = loadHistory().find(entry => entry.text === selected);
    expect(history).toBeDefined();
    expect(readFileSync(history!.file, "utf8")).toBe("fake audio");
  });
});
