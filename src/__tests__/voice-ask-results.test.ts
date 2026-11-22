import { afterEach, beforeEach, expect, test, spyOn } from "bun:test";
import * as fs from "fs";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync, chmodSync } from "fs";
import { join } from "path";
import * as handlers from "../handlers";
import { getToolDefinitions } from "../mcp-tools";
import { formatVoiceAskTurnResult } from "../voice-turn-result";

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
test("an already-away outcome still carries its allocated archive ID", () => {
  const result = formatVoiceAskTurnResult({kind: "away", archiveId: id(1)});
  expect(result.content[0].text).toBe(`Still no answer. Do not make another voice call; continue as if the user is away. (archive ${id(1)})`);
  expect(result.isError).toBeUndefined();
});
test("a pre-allocation refusal keeps its exact envelope and never fabricates an archive ID", async () => {
  expect(await handlers.handleVoiceAsk({})).toEqual({content: [{type: "text", text:
    "Invalid voice_ask arguments: provide exactly one mode — {message: ...} or {retranscribe_archive_id: ...}."}], isError: true});
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

test("retention log precedes a gated answer; away is persisted without transcription", async () => {
  const { spyOn } = await import("bun:test");
  const tts = await import("../tts"), input = await import("../input");
  const booking = await import("../session-booking"), recording = await import("../recording-state");
  const socket = await import("../socket-client");
  const archiveLog: unknown[][] = [];
  const spies = [
    spyOn(console, "error").mockImplementation((...args) => { archiveLog.push(args); }),
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
    expect(archiveLog).toContainEqual([`[voicelayer] voice_ask archive_id=${id(1)}`]);
    expect(events.every(event => event.kind !== "voice_ask_archive")).toBe(true);
    answer.resolve(null);
    const result = await pending;
    expect(result.content[0].text).toContain(id(1));
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

test("a spoken-question ID explicitly has no Ask answer", async () => { fixture(1, undefined, "speak"); expect(JSON.parse((await handlers.handleVoiceAskResults({archive_id: id(1)})).content[0].text)).toEqual({results: [], message: "No Ask answer exists for this archive ID."}); });

for (const file of ["metadata.json", "voicelayer-transcript.txt", "ask-result.json", "agent-transcript.txt"]) {
  for (const code of ["EIO", "EACCES"]) {
    for (const explicit of [false, true]) test(`injected ${code} ${file} explicit=${explicit}`, async () => {
      const dir = fixture(1, "Synthetic answer");
      fixture(2, "Other answer");
      writeFileSync(join(dir, "ask-result.json"), '{}');
      const original = fs.readFileSync;
      const spy = spyOn(fs, "readFileSync").mockImplementation(((path: any, ...args: any[]) => {
        if (path === join(dir, file)) throw Object.assign(new Error("private path"), {code});
        return (original as any)(path, ...args);
      }) as any);
      try {
        const result = await handlers.handleVoiceAskResults(explicit ? {archive_id: id(1)} : {});
        if (file === "agent-transcript.txt") {
          expect(result.isError).not.toBe(true);
          const row = JSON.parse(result.content[0].text).results.find((r: any) => r.id === id(1));
          expect(row.answer).toBe("Synthetic answer");
          expect(row.question_preview).toBe("");
        } else if (explicit) {
          expect(result.isError).toBe(true);
          expect(result.content[0].text).toContain(code);
        } else {
          expect(result.isError).not.toBe(true);
          const rows = JSON.parse(result.content[0].text).results;
          expect(rows.map((r: any) => r.status)).toEqual(["answered", "unreadable"]);
          expect(rows[1].error).toBe(code);
        }
        expect(result.content[0].text).not.toContain(root);
      } finally { spy.mockRestore(); }
    });
  }
}
for (const code of ["ENOENT", "EIO", "EACCES"]) test(`day listing ${code} preserves other days`, async () => {
  fixture(1, "Other answer");
  mkdirSync(join(root, "2026-01-01"));
  const original = fs.readdirSync;
  const spy = spyOn(fs, "readdirSync").mockImplementation(((path: any, ...args: any[]) => {
    if (path === join(root, "2026-01-01")) throw Object.assign(new Error("private"), {code});
    return (original as any)(path, ...args);
  }) as any);
  try {
    const rows = await lookup();
    expect(rows[0].answer).toBe("Other answer");
    expect(rows).toHaveLength(code === "ENOENT" ? 1 : 2);
    if (code !== "ENOENT") expect(rows[1]).toMatchObject({status: "unreadable", error: code});
  } finally { spy.mockRestore(); }
});
