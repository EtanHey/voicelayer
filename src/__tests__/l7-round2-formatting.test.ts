import { expect, test } from "bun:test";
import { finalizeTranscriptionResultForSurface } from "../input";
import * as chunks from "../stt-polish-chunks";
import { polishReachabilityForStatus } from "../recording-provenance";
import { archiveVoiceBarUntranscribedRecording, createWavBuffer } from "../input";
import { transcriptionStageReceiptDirectory } from "../transcription-stage-receipt";
import { readFileSync, readdirSync } from "fs";
import { join } from "path";

const env = () => ({ ...process.env, QA_VOICE_CORRECTOR: "identity", QA_VOICE_STT_POLISH: "off" });
const words = (s: string) => s.toLowerCase().match(/[\p{L}\p{M}\p{N}'’]+/gu);

for (const [raw, expected] of [
  ["I went there—it was closed—so I left.", "I went there, it was closed, so I left."],
  ["terrible anyway—that went pretty well", "terrible anyway, that went pretty well"],
  ["Keep this, — that stays.", "Keep this, that stays."],
  ["Keep this.—That stays.", "Keep this. That stays."],
  ["Keep this — `a—b` beside us.", "Keep this, `a—b` beside us."],
  ["Open https://x.test/a—b, — then leave.", "Open https://x.test/a—b, then leave."],
] as const) test("prose dash has no invented hesitation: " + raw, async () => {
  const r = await finalizeTranscriptionResultForSurface(raw, null, env());
  expect(r.text).toBe(expected); expect(words(r.text)).toEqual(words(raw));
});

test("the dash rule leaves code, paths, URLs and fenced bytes intact", async () => {
  const raw = "Run `a—b` and open https://x.test/a—b or ~/a—b/file. Outside—here.\n```txt\na—b\n```";
  const r = await finalizeTranscriptionResultForSurface(raw, null, env());
  expect(r.text).toBe(raw.replace("Outside—here", "Outside, here"));
});

for (const [raw, settings] of [
  ["That is the plan. new paragraph If you disagree, tell me now.", { QA_VOICE_CORRECTOR: "off" }],
  ["That is the plan.\n\nIf you disagree, tell me now.", {}],
  ["- First item.\n\nUntil Friday we wait.", {}],
] as const) test("retains supplied or dictated paragraph ownership: " + raw, async () => {
  const r = await finalizeTranscriptionResultForSurface(raw, null, { ...env(), ...settings });
  expect(r.text).toContain("\n\n");
});

test("a model cannot flatten an explicitly supplied paragraph", async () => {
  const raw = "That is the plan.\n\nIf you disagree, tell me now.";
  const server = Bun.serve({ port: 0, fetch: r => r.method !== "POST" ? Response.json({ data: [] })
    : Response.json({ choices: [{ message: { content: raw.replace("\n\n", " ") } }] }) });
  try {
    const result = await finalizeTranscriptionResultForSurface(raw, "dictation", {
      ...env(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
    });
    expect(result.text).toBe(raw); expect(result.polishStatus).toBe("rejected");
  } finally { server.stop(true); }
});

test("sentence-only chunks never let a closing-fragment model invent a seam", async () => {
  const raw = "a ".repeat(890) + "the long recording and the quiet parts " + "still belong together ".repeat(200) +
    ". " + "Now we keep the next complete sentence with every word intact. ".repeat(100);
  const requested: string[] = [];
  const server = Bun.serve({ port: 0, fetch: async r => {
    if (r.method !== "POST") return Response.json({ data: [] });
    const payload = await r.json() as { messages: Array<{ content: string }> };
    const body = payload.messages.at(-1)!.content.split("VoiceLayer cleaned text to fix:\n")[1]; requested.push(body);
    const closed = body[0].toUpperCase() + body.slice(1).replace(/[.!?]*$/u, ".");
    return Response.json({ choices: [{ message: { content: closed } }] });
  } });
  try {
    const r = await finalizeTranscriptionResultForSurface(raw, "dictation", {
      ...env(), QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
    });
    expect(requested.length).toBeGreaterThan(0);
    expect(requested.every(s => /[.!?]$/u.test(s))).toBe(true);
    expect(requested.every(s => s.length <= 3600)).toBe(true);
    expect(r.text).not.toContain("recording and. The quiet parts");
    expect(words(r.text)).toEqual(words(raw));
    expect(r.polishStatus).toBe("partial"); expect(r.polishReason).toMatch(/applied=\d+\/\d+/u);
  } finally { server.stop(true); }
});

test("chunk seam guard refuses a new terminal and continuation capitalization", () => {
  const guard = (chunks as any).preservesChunkSeam;
  expect(guard("the recording and", "The recording and.", true, true)).toBe(false);
  expect(guard("the quiet parts", "The quiet parts", true, false)).toBe(false);
  expect(guard('"the quiet parts', '"The quiet parts', true, false)).toBe(false);
  expect(guard("The next sentence.", "The next sentence.", false, true)).toBe(true);
});

test("an unpolished sentence without a safe bounded seam still gets its terminal floor", async () => {
  const raw = "keep every word in this unfinished recording ".repeat(150).trim();
  const r = await (chunks as any).polishLongTake({ rawText: raw, cleanedText: raw, surface: "dictation" }, 1,
    async () => { throw new Error("no safe seam should be sent"); });
  expect(r.text).toBe(raw + "."); expect(words(r.text)).toEqual(words(raw));
});

test("mixed applied and rejected chunks report partial and their exact counts", async () => {
  const raw = "The complete sentence keeps all of the spoken words in their original order. ".repeat(100);
  let attempted = 0;
  const r = await chunks.polishLongTake({ rawText: raw, cleanedText: raw }, 1000, async input => {
    const rejected = ++attempted === 2;
    return { inputText: input.cleanedText, text: input.cleanedText, polishedText: rejected ? null : input.cleanedText,
      mode: "on", status: rejected ? "rejected" : "applied", surface: "dictation", changed: false,
      polished: !rejected, retried: false, latencyMs: 0 };
  });
  expect(r.status).toBe("partial"); expect(r.polished).toBe(true); expect(r.polishedText).toBe(r.text);
  expect(r.chunkCounts).toEqual({ attempted, total: attempted, applied: attempted - 1 });
  expect(polishReachabilityForStatus(r.status)).toBe(true);
});

test("the receipt stores the exact post-boundary delivered text", async () => {
  const archive = archiveVoiceBarUntranscribedRecording({ audioBytes: createWavBuffer(new Uint8Array(3200)), source: "voicebar", silenceMode: "standard", pushToEnd: false, durationMs: 100, backend: "fixture", reason: "captured" });
  const audio = join(archive, "audio.wav"), raw = "Keep keep um— fu… here—this clause stays.";
  const r = await finalizeTranscriptionResultForSurface(raw, "dictation", env(), undefined, audio);
  const directory = transcriptionStageReceiptDirectory(audio);
  const receipt = JSON.parse(readFileSync(join(directory, readdirSync(directory)[0]), "utf8"));
  expect(receipt.stages.raw).toBe(raw);
  expect(receipt.stages.after_rules).toBe("Keep keep um… fu… here—this clause stays.");
  expect(r.text).toBe("Keep keep um… fu… here, this clause stays.");
  expect(receipt.stages.delivered).toBe(r.text);
});
