import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { allocateFreeLocalhostPort } from "../corpus-replay-verify";
import { WhisperCppBackend, WhisperServerBackend } from "../stt";
import { stopServer } from "../whisper-server";
import {
  findAdjacentDuplicateRun,
  findInventedBreaks,
  findMissingAnchors,
  findNearRepeat,
} from "./transcript-defects";
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

interface RunOutcome {
  run: number;
  text: string;
  backend: string;
  durationMs: number;
  missingAnchors: string[];
  adjacentDuplicate: string | null;
  nearRepeat: string | null;
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
        `near=${outcome.nearRepeat ? `"${outcome.nearRepeat}"` : "none"} ` +
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
  // AIDEV-NOTE: the fixed column must set "0", NOT unset. Since C1-b the
  // default is ON, so deleting the variable silently ran the SMART path in both
  // columns and made the comparison meaningless — it looked like the fixed cuts
  // had stopped losing words.
  process.env[SMART_CHUNK_ENV] = smartChunks ? "1" : "0";

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
      nearRepeat: findNearRepeat(result.text),
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
    // (b2) ...and nothing repeated across a small gap at a seam either.
    expect({ run: outcome.run, nearRepeat: outcome.nearRepeat }).toEqual({
      run: outcome.run,
      nearRepeat: null,
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

  goldenTest("the isolated run never killed the live :8178 listener", () => {
    // A listener APPEARING is fine and expected — :8178 is lazy, so the daemon
    // starts its own server on Etan's next utterance. What must never happen is
    // one that was serving before this run being gone after it.
    const after = liveWhisperListenerPids();
    for (const pid of livePidsBefore.split(",").filter(Boolean)) {
      expect({ pid, stillListening: after.split(",").includes(pid) }).toEqual({
        pid,
        stillListening: true,
      });
    }
  });
});
