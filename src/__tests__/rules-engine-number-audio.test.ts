import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { applyRules } from "../rules-engine";

// Personal audio, expectations, and decode output never enter the repository.
// CI skips without the local manifest; an explicit manifest must be usable.
const override = process.env.VOICELAYER_NUMBERS_CORPUS_PATH;
const manifestPath = override ?? join(
  homedir(), "Gits/voicelayer/docs.local/va-numbers/bakeoff-corpus.private.json",
);
const corpusTest = existsSync(manifestPath) || override ? test : test.skip;
if (!existsSync(manifestPath) && !override) {
  console.error("[number-audio] SKIPPING: private local corpus manifest absent.");
}

interface Specimen {
  archiveDirectory: string;
  audioSha256: string;
  modelPath: string;
  spanStartS: number;
  spanEndS: number;
  expectedRawSpan: string;
  expectedNumericTokens: string[];
}

const values = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"];
const numberPattern = /\b(?:zero|one|two|three|four|five|six|seven|eight|nine|\d+)\b/gi;
function numericTokens(text: string): string[] {
  return (text.match(numberPattern) ?? []).map((word) => {
    const value = values.indexOf(word.toLowerCase());
    return value < 0 ? word : String(value);
  });
}
function normalizedWords(text: string): string {
  return text.toLowerCase().replace(numberPattern, (word) => {
    const value = values.indexOf(word);
    return value < 0 ? word : String(value);
  }).match(/[\p{L}\p{N}]+/gu)?.join(" ") ?? "";
}

corpusTest("local timestamped audio keeps independently spoken number values", async () => {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as { specimens: Specimen[] };
  expect(manifest.specimens.length > 0).toBe(true);
  for (const specimen of manifest.specimens) {
    const wav = join(specimen.archiveDirectory, "audio.wav");
    expect(createHash("sha256").update(readFileSync(wav)).digest("hex") === specimen.audioSha256).toBe(true);
    const work = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT ?? tmpdir(), "number-audio-"));
    try {
      const prefix = join(work, "decode");
      const proc = Bun.spawn([
        "whisper-cli", "-m", specimen.modelPath, "-f", wav,
        "-l", "auto", "-t", "4", "-bo", "5", "-bs", "5",
        "-oj", "-of", prefix,
      ], { stdout: "pipe", stderr: "pipe" });
      // Drain both streams without echoing personal transcript text on failure.
      await Promise.all([new Response(proc.stdout).arrayBuffer(), new Response(proc.stderr).arrayBuffer()]);
      expect(await proc.exited).toBe(0);
      const decoded = JSON.parse(readFileSync(`${prefix}.json`, "utf8")) as {
        transcription: Array<{ text: string; offsets: { from: number; to: number } }>;
      };
      const rawSpan = decoded.transcription.filter((segment) =>
        segment.offsets.from / 1000 >= specimen.spanStartS - 0.2 &&
        segment.offsets.to / 1000 <= specimen.spanEndS + 0.2
      ).map((segment) => segment.text.trim()).join(" ");
      expect(normalizedWords(rawSpan) === normalizedWords(specimen.expectedRawSpan)).toBe(true);
      const formatted = applyRules(rawSpan);
      // Boolean comparisons deliberately keep private expected/actual text out
      // of Bun's assertion diffs, logs, and public CI artifacts.
      expect(JSON.stringify(numericTokens(formatted)) === JSON.stringify(specimen.expectedNumericTokens)).toBe(true);
      expect(normalizedWords(formatted) === normalizedWords(specimen.expectedRawSpan)).toBe(true);
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  }
}, 180_000);
