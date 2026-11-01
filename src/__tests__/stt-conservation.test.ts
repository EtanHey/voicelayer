import { describe, test, expect } from "bun:test";
import { join } from "path";
import { writeFileSync } from "fs";
import { WhisperServerBackend, mergeChunkTranscripts, mergeChunkTranscriptsWithSegments } from "../stt";
import { stripHallucinatedOutro } from "../stt-outro-gate";
import { cleanupTranscriptionText } from "../stt-cleanup";
import { applyRules } from "../rules-engine";
import { polishTranscriptionText } from "../stt-polish";

// Synthetic speech-shaped WAV and scripted replies verify caller decisions.
// Neither the waveform nor the replies assert acoustic truth.
function wav(seconds: number): Buffer {
  const frames = seconds * 16000;
  const b = Buffer.alloc(44 + frames * 2);
  b.write("RIFF"); b.writeUInt32LE(b.length - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28);
  b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(frames * 2, 40);
  for (let i = 0; i < frames; i++) b.writeInt16LE(Math.round(1200 * Math.sin(i * Math.PI / 20)), 44 + i * 2);
  return b;
}
async function backendText(seconds: number, replies: string[]): Promise<string> {
  const path = join(process.env.VOICELAYER_TEST_RUN_ROOT!, `conserve-${seconds}.wav`);
  writeFileSync(path, wav(seconds));
  const saved = { smart: process.env.VOICELAYER_STT_SMART_CHUNKS, outro: process.env.VOICELAYER_STT_OUTRO_GATE };
  process.env.VOICELAYER_STT_SMART_CHUNKS = "0";
  process.env.VOICELAYER_STT_OUTRO_GATE = "0";
  let calls = 0;
  try {
    const backend = new WhisperServerBackend({
      isServerAvailable: () => true,
      fallbackBackend: { name: "forbidden", isAvailable: async () => false, transcribe: async () => { throw new Error("unexpected fallback"); } },
      transcribeViaServer: async () => {
        const value = replies[calls++];
        if (value === undefined) throw new Error("unexpected extra decode");
        return value;
      },
    });
    const result = await backend.transcribe(path);
    expect(calls).toBe(replies.length);
    return result.text;
  } finally {
    for (const [key, value] of [["VOICELAYER_STT_SMART_CHUNKS", saved.smart], ["VOICELAYER_STT_OUTRO_GATE", saved.outro]]) {
      if (value === undefined) delete process.env[key!]; else process.env[key!] = value;
    }
  }
}

describe("raw transcription conservation", () => {
  test("keeps a separated repeated tail through the complete backend", async () => {
    const text = "Keep every word. I really mean it. Keep every word.";
    expect(await backendText(2, [text])).toBe(text);
  });
  test("keeps six final words when another decode disagrees", async () => {
    const tail = "Keep these six final spoken words.";
    expect(await backendText(108, ["intro setup", "setup middle", "middle plan", "plan closing topic", tail, "unrelated alternative"]))
      .toBe("intro setup middle plan closing topic " + tail);
  });
  test("retains true adjacent repeats at silence seams while folding declared overlap", () => {
    const phrase = "Say these four words.";
    expect(mergeChunkTranscripts([phrase, phrase], ["anchor", "silence"])).toBe(`${phrase} ${phrase}`);
    expect(mergeChunkTranscripts([phrase, phrase], ["anchor", "anchor"])).toBe(phrase);
  });
  for (const fragment of ["fu…", "f...", "fu-", "fu—"]) {
    test(`keeps ${fragment} while folding the compact seam`, () => {
      const first = `Start the account with the long shared anchor ${fragment}`;
      const next = "the long shared anchor frustrating and continue";
      const expected = `Start the account with the long shared anchor ${fragment} frustrating and continue`;
      expect(mergeChunkTranscripts([first, next])).toBe(expected);
      expect(mergeChunkTranscriptsWithSegments([
        { text: first, startSeconds: 0, segments: [{ text: first, startS: 20, endS: 30 }] },
        { text: next, startSeconds: 25, segments: [{ text: next, startS: 0, endS: 10 }] },
      ]).text).toBe(expected);
    });
  }
  test("preserves short speech and repeated function words in cleanup", () => {
    const env = { ...process.env, QA_VOICE_STT_VOCABULARY_DISABLED: "1" };
    expect(cleanupTranscriptionText("Thank you.", env)).toBe("Thank you.");
    expect(cleanupTranscriptionText("I I meant the the second branch.", env)).toBe("I I meant the the second branch.");
    expect(cleanupTranscriptionText("[BLANK_AUDIO]", env)).toBe("");
  });
  test("refuses outro deletion when timestamps extend beyond the WAV", () => {
    const audio = wav(8);
    // Keep speech early and silence under the disputed closer.
    audio.fill(0, 44 + 4 * 16000 * 2);
    const raw = "Keep the account. Thank you.";
    const result = stripHallucinatedOutro(raw, audio, { segmentsText: raw, segments: [
      { text: "Keep the account.", startS: 0, endS: 4 },
      { text: "Thank you.", startS: 6, endS: 30 },
    ] });
    expect(result.text).toBe(raw);
    expect(result.removed).toHaveLength(0);
  });
  const disabledStages = new Set(["punctuation", "numbers", "fillers", "capitalization", "techVocab", "codeTokens", "caseFormatting", "enumerators"]);
  for (const text of ["src/prq.ts", "https://example.invalid/prq", "prq@example.invalid", "prq.value", "prq::run", "`prq`", "```ts\nprq\n```", "`prq", "Golan's", "x_prq", "prq…"]) {
    test(`dictionary abstains on literal ${text}`, () => {
      expect(applyRules(text, { aliases: { prq: "PR queue", Golan: "Golems" }, disabledStages })).toBe(text);
    });
  }
  test("dictionary still applies explicit prose and whole paths", () => {
    expect(applyRules("`prq` then prq.", { aliases: { prq: "PR queue" }, disabledStages })).toBe("`prq` then PR queue.");
    expect(applyRules("/old-command", { aliases: { "/old-command": "/new-command" }, disabledStages })).toBe("/new-command");
  });
  for (const surface of ["dictation", "voice_ask"] as const) {
    test(`rejects loss of a short fragment with multiplicity on ${surface}`, async () => {
      const savedFetch = globalThis.fetch;
      globalThis.fetch = (async () => Response.json({ choices: [{ message: { content: "That is f… frustrating." } }] })) as typeof fetch;
      try {
        const raw = "That is f… f… frustrating.";
        const result = await polishTranscriptionText({ rawText: raw, cleanedText: raw, surface, env: {
          ...process.env, QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: "http://synthetic.invalid/v1/chat/completions",
        } });
        expect(result.status).toBe("rejected");
        expect(result.text).toBe(raw);
      } finally { globalThis.fetch = savedFetch; }
    });
  }
});
