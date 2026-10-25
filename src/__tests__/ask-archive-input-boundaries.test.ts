import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import * as archive from "../speak-archive";
import * as tts from "../tts";
import * as input from "../input";
import * as booking from "../session-booking";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import { handleVoiceAsk, VOICE_ASK_MESSAGE_MAX_CHARS } from "../handlers";
import { SPEAK_TEXT_MAX_CHARS } from "../socket-protocol";
import { hasActiveVoiceOperation } from "../voice-operation-reservation";
import { TTS_DISABLED_FILE } from "../paths";

const realCreate = archive.createSpeakReceipt;
const raw = " \tSynthetic שלום🙂 fu… no, full\r\n ";
let fixture: string, savedRoot: string;
let contexts: archive.SpeakArchiveContext[];
let spies: Array<{ mockRestore(): void }> = [];
let creator: ReturnType<typeof spyOn<typeof archive, "createSpeakReceipt">>;
let speak: ReturnType<typeof spyOn<typeof tts, "speak">>;
let capture: ReturnType<typeof spyOn<typeof input, "waitForInput">>;
let book: ReturnType<typeof spyOn<typeof booking, "bookVoiceSession">>;

describe("Ask raw archive admission (isolated preload; synthetic speech/capture)", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, root = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !root ||
        relative(resolve(run), resolve(root)).startsWith("..") || resolve(run) === resolve(root)) {
      throw new Error("canonical isolated preload required");
    }
    savedRoot = root;
    fixture = fs.mkdtempSync(join(root, "ask-bound-"));
    const recordings = join(fixture, "recordings");
    fs.mkdirSync(recordings, { mode: 0o700 });
    process.env.QA_VOICE_RECORDINGS_DIR = recordings;
    contexts = [];
    creator = spyOn(archive, "createSpeakReceipt").mockImplementation(request => {
      const result = realCreate(request);
      if (result.kind === "created") contexts.push(result.context);
      return result;
    });
    speak = spyOn(tts, "speak").mockImplementation(async text => ({
      playbackId: "synthetic-prompt", displayText: text, engine: "edge-tts", voice: "en-US-JennyNeural",
      audioArtifact: { bytes: new Uint8Array([0x49, 0x44, 0x33]), format: "mp3" },
    }));
    capture = spyOn(input, "waitForInput").mockResolvedValue("synthetic answer");
    book = spyOn(booking, "bookVoiceSession").mockReturnValue({ success: true });
    spies.push(creator, speak, capture, book,
      spyOn(input, "getRecordingState").mockReturnValue("idle"),
      spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
      spyOn(input, "clearInput").mockImplementation(() => {}),
      spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
      spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
      spyOn(socket, "isConnected").mockReturnValue(true),
      spyOn(socket, "broadcast").mockImplementation(() => {}));
    fs.rmSync(TTS_DISABLED_FILE, { force: true });
  });
  afterEach(() => {
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    fs.rmSync(TTS_DISABLED_FILE, { force: true });
    process.env.QA_VOICE_RECORDINGS_DIR = savedRoot;
    fs.rmSync(fixture, { recursive: true, force: true });
    expect(hasActiveVoiceOperation()).toBe(false);
  });

  for (const message of ["x".repeat(SPEAK_TEXT_MAX_CHARS + 1),
    "Ask?".padEnd(SPEAK_TEXT_MAX_CHARS + 1, " ")]) {
    it(`refuses raw cap+1 before allocation or voice work; trimmed=${message.trim().length}`, async () => {
      const result = await handleVoiceAsk({ message });
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("raw input exceeds archive admission limit");
      expect(creator).not.toHaveBeenCalled();
      expect(contexts).toHaveLength(0);
      expect(fs.readdirSync(process.env.QA_VOICE_RECORDINGS_DIR!)).toEqual([]);
      expect(speak).not.toHaveBeenCalled();
      expect(capture).not.toHaveBeenCalled();
      expect(book).not.toHaveBeenCalled();
    });
  }

  for (const [label, message, rejected] of [
    ["exact raw cap with short trimmed prompt", raw.padEnd(SPEAK_TEXT_MAX_CHARS, " "), false],
    ["exact raw cap with overlong trimmed prompt", "x".repeat(SPEAK_TEXT_MAX_CHARS), true],
    ["ordinary valid prompt", raw, false],
    ["ordinary bounded speech-policy refusal", " \t" + "x".repeat(VOICE_ASK_MESSAGE_MAX_CHARS + 1) + "\n ", true],
  ] as const) {
    it(`retains original bytes and existing policy: ${label}`, async () => {
      const result = await handleVoiceAsk({ message });
      expect(creator).toHaveBeenCalledTimes(1);
      expect(contexts).toHaveLength(1);
      expect(fs.readFileSync(join(contexts[0].path, "input.txt"))).toEqual(Buffer.from(message));
      const metadata = JSON.parse(fs.readFileSync(join(contexts[0].path, "metadata.json"), "utf8"));
      expect(metadata.status).toBe(rejected ? "rejected" : "received");
      if (rejected) {
        expect(result.isError).toBe(true);
        expect(result.content[0].text).toContain("voice_ask");
        expect(speak).not.toHaveBeenCalled();
        expect(capture).not.toHaveBeenCalled();
      } else {
        expect(result.content[0].text).toContain("synthetic answer");
        expect(speak).toHaveBeenCalledTimes(1);
        expect(speak.mock.calls[0][0]).toBe(message.trim());
        expect(speak.mock.calls[0][1]?.archiveContext).toBe(contexts[0]);
        expect(capture).toHaveBeenCalledTimes(1);
      }
      expect(book).not.toHaveBeenCalled();
    });
  }
});
