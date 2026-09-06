import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { allocateFreeLocalhostPort } from "../corpus-replay-verify";
import { WhisperCppBackend, WhisperServerBackend } from "../stt";
import { stopServer } from "../whisper-server";
import {
  GOLDEN_FIXTURE_PATH,
  loadSmartChunkGolden,
  type SmartChunkGolden,
} from "./smart-chunk-golden-fixture";

/**
 * RED gate — golden clip B through the ≥90 s saved-WAV chunk path, N=5.
 *
 * The fixed 30 s cut is nondeterministic on this clip and produces two named
 * defects (docs.local/recon-2026-09-05/m2-repro/summary.md, 2026-09-05):
 * a seam duplicate and an invented sentence break, in the RAW whisper output —
 * before any cleanup or polish. This suite asserts what Etan is owed
 * (AGENTS.md: nothing added, nothing repeated, nothing lost) against the CURRENT
 * merge logic, and is EXPECTED TO FAIL. Do not change the merge to make it pass;
 * that is a separate PR.
 *
 * The same assertions run a second time with VOICELAYER_STT_SMART_CHUNKS=1, so
 * the pause-driven boundary is measured on identical bytes rather than argued.
 *
 * Opt-in and isolated on purpose:
 *  - VOICELAYER_SMART_CHUNK_GOLDEN=1 — 2×5 decodes of a 109 s clip is minutes.
 *  - the gitignored fixture must exist (the anchors are Etan's own speech and
 *    this repo is public — AGENTS.md private-data pass).
 *  - a freshly allocated port, never 8178. On 8178 whisper-server's stale-orphan
 *    branch SIGKILLs the daily driver's resident server; that happened on
 *    2026-09-05 (m2-repro/SURPRISE-whisper-server-killed.md) and this suite
 *    fails loudly if the live listener changes underneath it.
 */

const N_RUNS = 5;
const SMART_CHUNK_ENV = "VOICELAYER_STT_SMART_CHUNKS";

const optedIn = process.env.VOICELAYER_SMART_CHUNK_GOLDEN === "1";
const golden = loadSmartChunkGolden();
const modelInfo = new WhisperCppBackend().getModelInfo();
const hasWhisper = Boolean(modelInfo.binary && modelInfo.model);
const ready = optedIn && Boolean(golden) && hasWhisper;

if (!ready) {
  console.error(
    `[smart-chunk-golden] SKIPPING — ${[
      optedIn ? null : "VOICELAYER_SMART_CHUNK_GOLDEN=1 not set",
      golden ? null : `no fixture at ${GOLDEN_FIXTURE_PATH}`,
      hasWhisper ? null : "no whisper binary/model",
    ]
      .filter(Boolean)
      .join("; ")}.`,
  );
}
const goldenTest = ready ? test : test.skip;

function liveWhisperListenerPids(): string {
  const probe = Bun.spawnSync(
    ["lsof", "-nP", "-iTCP:8178", "-sTCP:LISTEN", "-t"],
    { stdout: "pipe", stderr: "ignore" },
  );
  return probe.stdout.toString().trim().split(/\s+/).filter(Boolean).sort().join(",");
}

/** Lowercase, strip punctuation, collapse whitespace — casing varies run to run. */
function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s.']/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function words(text: string): string[] {
  return normalize(text).replace(/[.']/g, "").split(" ").filter(Boolean);
}

/**
 * Longest run of ≥4 words that repeats immediately after itself.
 * This is AGENTS.md defect #2 — "a sentence sometimes repeats back-to-back".
 */
export function findAdjacentDuplicateRun(text: string): string | null {
  const list = words(text);
  for (let length = Math.floor(list.length / 2); length >= 4; length--) {
    for (let index = 0; index + 2 * length <= list.length; index++) {
      const left = list.slice(index, index + length).join(" ");
      const right = list.slice(index + length, index + 2 * length).join(" ");
      if (left === right) return left;
    }
  }
  return null;
}

/**
 * Anchor matching compares LETTER SEQUENCES, not tokens.
 *
 * Whisper splits the same audio as "CodeRabbit.yaml" or "code rabbit.yaml",
 * "ChatGPT" or "chat gpt", run to run. Those are spacing choices, not words
 * Etan lost, and a gate that fails on them measures the tokenizer instead of
 * the defect. Dropping separators keeps the check on the thing that matters:
 * did the sounds he actually said survive the chunk seam?
 */
export function anchorKey(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
}

export function findMissingAnchors(text: string, anchors: string[]): string[] {
  const haystack = anchorKey(text);
  return anchors.filter((anchor) => !haystack.includes(anchorKey(anchor)));
}

export function findInventedBreaks(
  text: string,
  breaks: Array<{ name: string; pattern: string }>,
): string[] {
  return breaks
    .filter((entry) => new RegExp(entry.pattern, "i").test(text))
    .map((entry) => entry.name);
}

interface RunOutcome {
  run: number;
  text: string;
  backend: string;
  durationMs: number;
  missingAnchors: string[];
  adjacentDuplicate: string | null;
  inventedBreaks: string[];
}

function summarize(label: string, outcomes: RunOutcome[]): string {
  const distinct = new Set(
    outcomes.map((o) => createHash("sha256").update(o.text).digest("hex").slice(0, 8)),
  );
  const lines = [
    `[smart-chunk-golden] ${label}: N=${outcomes.length}, distinct raw outputs=${distinct.size}`,
  ];
  for (const outcome of outcomes) {
    lines.push(
      `  run-${String(outcome.run).padStart(2, "0")} ` +
        `${(outcome.durationMs / 1000).toFixed(1)}s ${outcome.backend} ` +
        `missing=${outcome.missingAnchors.length} ` +
        `dup=${outcome.adjacentDuplicate ? `"${outcome.adjacentDuplicate}"` : "none"} ` +
        `breaks=${outcome.inventedBreaks.length ? outcome.inventedBreaks.join("|") : "none"}` +
        (outcome.missingAnchors.length
          ? `\n         missing: ${outcome.missingAnchors.map((a) => `"${a}"`).join(", ")}`
          : ""),
    );
  }
  return lines.join("\n");
}

const reports: Array<{ label: string; outcomes: RunOutcome[] }> = [];

/**
 * Optional receipt for a PR body. Off unless a path is given, and the path is
 * expected to be gitignored: the texts are Etan's own speech.
 */
function writeReport(label: string, outcomes: RunOutcome[]): void {
  const path = process.env.VOICELAYER_SMART_CHUNK_GOLDEN_REPORT;
  if (!path) return;
  reports.push({ label, outcomes });
  writeFileSync(path, JSON.stringify(reports, null, 2));
}

let livePidsBefore = "";

beforeAll(async () => {
  if (!ready) return;
  livePidsBefore = liveWhisperListenerPids();
  const port = await allocateFreeLocalhostPort();
  if (port === 8178) throw new Error("refusing to run on the live whisper port");
  process.env.QA_VOICE_WHISPER_SERVER_PORT = String(port);
  console.error(`[smart-chunk-golden] isolated whisper-server port ${port}; live :8178 = ${livePidsBefore || "none"}`);
});

afterAll(() => {
  if (!ready) return;
  stopServer();
  delete process.env[SMART_CHUNK_ENV];
  const after = liveWhisperListenerPids();
  console.error(`[smart-chunk-golden] live :8178 after = ${after || "none"} (before = ${livePidsBefore || "none"})`);
});

async function runGolden(
  fixture: SmartChunkGolden,
  smartChunks: boolean,
): Promise<RunOutcome[]> {
  if (smartChunks) process.env[SMART_CHUNK_ENV] = "1";
  else delete process.env[SMART_CHUNK_ENV];

  const backend = new WhisperServerBackend();
  const outcomes: RunOutcome[] = [];
  for (let run = 1; run <= N_RUNS; run++) {
    const result = await backend.transcribe(fixture.wav);
    outcomes.push({
      run,
      text: result.text,
      backend: result.backend,
      durationMs: result.durationMs,
      missingAnchors: findMissingAnchors(result.text, fixture.anchors),
      adjacentDuplicate: findAdjacentDuplicateRun(result.text),
      inventedBreaks: findInventedBreaks(result.text, fixture.forbiddenBreaks),
    });
  }
  delete process.env[SMART_CHUNK_ENV];
  return outcomes;
}

function assertClean(outcomes: RunOutcome[]): void {
  for (const outcome of outcomes) {
    // (a) nothing Etan said went missing.
    expect({ run: outcome.run, missing: outcome.missingAnchors }).toEqual({
      run: outcome.run,
      missing: [],
    });
    // (b) nothing repeated back-to-back at a chunk seam.
    expect({ run: outcome.run, duplicate: outcome.adjacentDuplicate }).toEqual({
      run: outcome.run,
      duplicate: null,
    });
    // (c) no sentence boundary invented at a seam.
    expect({ run: outcome.run, breaks: outcome.inventedBreaks }).toEqual({
      run: outcome.run,
      breaks: [],
    });
  }
}

describe("golden clip B through the ≥90 s chunk path", () => {
  goldenTest("the recording is the clip the fixture pins", () => {
    const fixture = golden as SmartChunkGolden;
    const sha = createHash("sha256")
      .update(readFileSync(fixture.wav))
      .digest("hex");
    expect(sha).toBe(fixture.audioSha256);
  });

  goldenTest(
    `RED: fixed 30 s cuts, N=${N_RUNS} — expected to FAIL until the merge lands`,
    async () => {
      const outcomes = await runGolden(golden as SmartChunkGolden, false);
      console.error(summarize("fixed 30s cuts", outcomes));
      writeReport("fixed-30s", outcomes);
      assertClean(outcomes);
    },
    900_000,
  );

  goldenTest(
    `${SMART_CHUNK_ENV}=1: pause-driven cuts, N=${N_RUNS} — measured, not forced`,
    async () => {
      const outcomes = await runGolden(golden as SmartChunkGolden, true);
      console.error(summarize("smart pause-driven cuts", outcomes));
      writeReport("smart-pause-driven", outcomes);
      assertClean(outcomes);
    },
    900_000,
  );

  goldenTest("the isolated run never touched the live :8178 listener", () => {
    expect(liveWhisperListenerPids()).toBe(livePidsBefore);
  });
});
