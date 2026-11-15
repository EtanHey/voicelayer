import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import * as handlers from "../handlers";
import { getToolDefinitions } from "../mcp-tools";
import { voiceToolEventToMcpNotification } from "../mcp-notifications";

let root: string, saved: string | undefined;
const id = (n: number) => `2026-01-02T03-04-05-${String(n).padStart(3, "0")}Z-abcdef01`;
function fixture(n: number, answer?: string, source = "voice_ask") {
  const dir = join(root, "2026-01-02", id(n));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "metadata.json"), JSON.stringify({ id: id(n), source, created_at: `2026-01-02T03:04:05.${String(n).padStart(3, "0")}Z`, transcription_status: answer ? "transcribed" : "captured" }));
  writeFileSync(join(dir, "agent-transcript.txt"), "Synthetic question? ".repeat(8));
  if (answer !== undefined) writeFileSync(join(dir, "voicelayer-transcript.txt"), answer);
  return dir;
}
beforeEach(() => {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("isolated preload required");
  saved = process.env.QA_VOICE_RECORDINGS_DIR;
  root = mkdtempSync(join(saved!, "ask-results-"));
  process.env.QA_VOICE_RECORDINGS_DIR = root;
});
afterEach(() => {
  process.env.QA_VOICE_RECORDINGS_DIR = saved;
  rmSync(root, { recursive: true, force: true });
});
async function lookup(args = {}) {
  const result = await handlers.handleVoiceAskResults(args);
  expect(result.isError).not.toBe(true);
  return JSON.parse(result.content[0].text).results;
}
test("read-only tool is discoverable with bounded input", () => {
  const tool = getToolDefinitions().find(t => t.name === "voice_ask_results");
  expect(tool?.annotations?.readOnlyHint).toBe(true);
});
test("latest five and explicit ID preserve the entire raw answer and question preview", async () => {
  const answer = "  Synthetic fu… no, full. full.\n";
  for (let n = 1; n <= 7; n++) fixture(n, answer);
  fixture(8, "Other dictation", "voicebar");
  const results = await lookup();
  expect(results.map((r: any) => r.id)).toEqual([7, 6, 5, 4, 3].map(id));
  expect(results[0]).toEqual({ id: id(7), asked_at: "2026-01-02T03:04:05.007Z", question_preview: "Synthetic question? ".repeat(8).slice(0, 80), answer, status: "answered" });
  expect((await lookup({ archive_id: id(1) }))[0].answer).toBe(answer);
  expect(await lookup({ archive_id: id(9) })).toEqual([]);
});
test("unfinished archives need retranscription; only explicit no-speech evidence is away", async () => {
  fixture(1);
  const away = fixture(2);
  writeFileSync(join(away, "ask-result.json"), JSON.stringify({ status: "away" }));
  expect((await lookup()).map((r: any) => r.status)).toEqual(["away", "needs-retranscribe"]);
});
test("invalid input, malformed metadata and symlinks cannot read outside Ask entries", async () => {
  for (const args of [{limit: 0}, {limit: 21}, {limit: 1.5}, {archive_id: "../../private"}, {message: "speak"}]) {
    expect((await handlers.handleVoiceAskResults(args)).isError).toBe(true);
  }
  const dir = fixture(1, "Synthetic secret");
  rmSync(join(dir, "voicelayer-transcript.txt"));
  symlinkSync(join(dir, "agent-transcript.txt"), join(dir, "voicelayer-transcript.txt"));
  const broken = fixture(2); writeFileSync(join(broken, "metadata.json"), "{");
  expect((await lookup())[0].answer).toBeNull();
  expect(await lookup({archive_id: id(2)})).toEqual([]);
  expect(readdirSync(dir).sort()).toEqual(["agent-transcript.txt", "metadata.json", "voicelayer-transcript.txt"]);
  expect(readFileSync(join(broken, "metadata.json"), "utf8")).toBe("{");
});
test("archive receipt becomes a client-visible notification without question or answer", () => {
  const notification = voiceToolEventToMcpNotification({kind: "voice_ask_archive", archiveId: id(1)} as any);
  expect(notification.method).toBe("notifications/message");
  expect(notification.params.data).toEqual({kind: "voice_ask_archive", archive_id: id(1)});
});
test("even a rejected Ask reports an explicit null archive ID", async () => {
  expect((await handlers.handleVoiceAsk({})).structuredContent).toEqual({ archive_id: null });
});

test("daemon JSON-RPC admits the read-only tool", async () => {
  const { handleMcpRequest } = await import("../mcp-handler");
  fixture(1, "Synthetic recovered answer");
  const result = await handleMcpRequest({jsonrpc: "2.0", id: 1, method: "tools/call",
    params: {name: "voice_ask_results", arguments: {archive_id: id(1)}}}, {
    executeTool: async (name, args) => {
      expect(name).toBe("voice_ask_results");
      return handlers.handleVoiceAskResults(args);
    },
  });
  expect(result?.error).toBeUndefined();
  expect(JSON.stringify(result?.result)).toContain("Synthetic recovered answer");
});

test("retention notification precedes a gated answer; away is persisted without transcription", async () => {
  const { spyOn } = await import("bun:test");
  const tts = await import("../tts"), input = await import("../input");
  const booking = await import("../session-booking"), recording = await import("../recording-state");
  const socket = await import("../socket-client");
  const spies = [
    spyOn(tts, "speak").mockImplementation(async text => ({playbackId: "synthetic", displayText: text,
      engine: "edge-tts" as const, voice: "synthetic", audioArtifact: {bytes: new Uint8Array([73,68,51]), format: "mp3" as const}})),
    spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(booking, "isVoiceBooked").mockReturnValue({booked: true, ownedByUs: true}),
    spyOn(input, "clearInput").mockImplementation(() => {}),
    spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(socket, "isConnected").mockReturnValue(true),
    spyOn(socket, "broadcast").mockImplementation(() => {}),
  ];
  const retained = Promise.withResolvers<void>(), answer = Promise.withResolvers<string | null>();
  const dir = fixture(1);
  let settled = false;
  spies.push(spyOn(input, "waitForInput").mockImplementation(async (_timeout, _silence, _ptt, options) => {
    options?.onArchiveCreated?.(dir);
    retained.resolve();
    const response = await answer.promise;
    if (response === null) options?.onNoAnswer?.(false);
    return response;
  }));
  try {
    const events: any[] = [];
    const pending = handlers.handleVoiceAsk({message: "Synthetic question?"}, {emit: e => events.push(e)})
      .then(result => {settled = true; return result;});
    await retained.promise;
    expect(settled).toBe(false);
    expect(events).toContainEqual({kind: "voice_ask_archive", archiveId: id(1)});
    answer.resolve(null);
    const result = await pending;
    expect(result.structuredContent).toEqual({archive_id: id(1)});
    expect((await lookup({archive_id: id(1)}))[0].status).toBe("away");
  } finally {
    answer.resolve(null);
    for (const spy of spies.reverse()) spy.mockRestore();
  }
});


test("empty archive and maximum page size are deterministic", async () => {
  expect(await lookup()).toEqual([]);
  for (let n = 1; n <= 21; n++) fixture(n, "Synthetic answer");
  const page = await lookup({limit: 20});
  expect(page).toHaveLength(20);
  expect(page[0].id).toBe(id(21));
  expect(page[19].id).toBe(id(2));
});
