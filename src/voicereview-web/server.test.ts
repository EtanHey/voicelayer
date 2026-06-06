import {
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import {
  buildConverseMessages,
  buildConfirmation,
  buildDriverArgs,
  buildEvidenceArgs,
  buildInterpretMessages,
  buildWhisperArgs,
  buildWhisperPrompt,
  createVoiceReviewApp,
  decorateStatsWithSkippedCounts,
  decisionLockPath,
  DEFAULT_CONFIG,
  humanizeSpokenText,
  legacyDecisionsToKgFlagV1,
  parseInterpretDecision,
  type ConversationEvidence,
  type CommandCall,
  type CommandResult,
  type ReviewCluster,
} from "./server";

const cantaloupeCluster: ReviewCluster = {
  cluster_id: "diagnosis-flag:cantaloupe",
  category: "diagnosis-flag",
  stem: "cantaloupe",
  size: 4,
  members: [
    {
      id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
      name: "Cantaloupe",
      type: "company",
      chunks: 13,
    },
    {
      id: "141df1c6-0ee7-566c-a2a7-f03a76c294fd",
      name: "Cantaloupe",
      type: "project",
      chunks: 4,
    },
  ],
};

function commandResult(stdout: unknown): CommandResult {
  return {
    exitCode: 0,
    stdout: JSON.stringify(stdout),
    stderr: "",
    durationMs: 12,
  };
}


describe("VoiceReview web server helpers", () => {
  it("checks LiteRT health with the no-generation models endpoint", async () => {
    let requestedUrl = "";
    let requestedInit: RequestInit | undefined;
    const app = createVoiceReviewApp({
      config: {
        liteRtUrl: "http://127.0.0.1:9379/v1/chat/completions",
      },
      fetchImpl: async (url, init) => {
        requestedUrl = String(url);
        requestedInit = init;
        return new Response(JSON.stringify({ data: [] }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      },
    });

    const response = await app.fetch(new Request("http://localhost/api/health"));

    expect(response.status).toBe(200);
    expect(requestedUrl).toBe("http://127.0.0.1:9379/v1/models");
    expect(requestedInit?.method).toBe("GET");
    expect(requestedInit?.body).toBeUndefined();
    expect(requestedInit?.signal).toBeUndefined();
  });

  it("builds driver args as arrays with request data in its own argv slot", () => {
    const args = buildDriverArgs("next", {
      pythonScript: "/tmp/voice-review-wt/scripts/kg_review_session.py",
      batchPath: "/batch.json",
      decisionsPath: "/decisions.json",
      category: "diagnosis-flag; rm -rf /",
    });

    expect(args).toEqual([
      "python3",
      "/tmp/voice-review-wt/scripts/kg_review_session.py",
      "next",
      "--batch=/batch.json",
      "--decisions=/decisions.json",
      "--category=diagnosis-flag; rm -rf /",
    ]);
  });

  it("serves /api/next through the shared KG review driver", async () => {
    const calls: CommandCall[] = [];
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
      },
      runCommand: async (call) => {
        calls.push(call);
        return commandResult({ cluster: cantaloupeCluster, speak: "Cluster text" });
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/next?category=diagnosis-flag"),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      cluster: cantaloupeCluster,
      speak: "Cluster text",
      timings: { driver_ms: 12 },
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].args).toContain("--category=diagnosis-flag");
    expect(calls[0].env.PYTHONPATH).toBe("/tmp/voice-review-wt/src");
    expect(calls[0].cwd).toBe("/tmp/voice-review-wt");
  });

  it("serves explicit complete queue state with decided stats when /api/next has no cluster", async () => {
    const calls: CommandCall[] = [];
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
      },
      runCommand: async (call) => {
        calls.push(call);
        if (call.args.includes("stats")) {
          return commandResult({
            per_category: {
              "diagnosis-flag": {
                total: 7,
                explicit: 5,
                by_rule: 2,
                undecided: 0,
              },
            },
          });
        }
        return commandResult({ cluster: null, speak: "" });
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/next?category=diagnosis-flag"),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(calls.map((call) => call.args[2])).toEqual(["next", "stats"]);
    expect(body.queue_state).toEqual({
      kind: "complete",
      category: "diagnosis-flag",
      decided: 7,
      message: "All items in this queue are complete 🎉 7 decided.",
    });
  });

  it("serves explicit empty queue state when stats have no items for the category", async () => {
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
      },
      runCommand: async (call) => {
        if (call.args.includes("stats")) {
          return commandResult({
            per_category: {
              "diagnosis-flag": {
                total: 7,
                explicit: 5,
                by_rule: 2,
                undecided: 0,
              },
            },
          });
        }
        return commandResult({ cluster: null, speak: "" });
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/next?category=sep-variants"),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.queue_state).toEqual({
      kind: "empty",
      category: "sep-variants",
      decided: 0,
      message: "No items found for category sep-variants.",
    });
  });

  it("serves degraded stats JSON instead of hard-failing when rollups reject stale decisions", async () => {
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
      },
      runCommand: async () => ({
        exitCode: 1,
        stdout: "",
        stderr: "ValueError: decision references cluster not in loaded batch",
        durationMs: 9,
      }),
    });

    const response = await app.fetch(new Request("http://localhost/api/stats"));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toMatchObject({
      stats: null,
      degraded: true,
      error:
        "stats unavailable: kg_review_session.py failed with exit 1: ValueError: decision references cluster not in loaded batch",
      timings: { driver_ms: 9 },
    });
  });

  it("serves an explicit stats-error queue state when /api/next empties but stats fail", async () => {
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
      },
      runCommand: async (call) => {
        if (call.args.includes("stats")) {
          return {
            exitCode: 1,
            stdout: "",
            stderr: "ValueError: decision references cluster not in loaded batch",
            durationMs: 9,
          };
        }
        return commandResult({ cluster: null, speak: "" });
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/next?category=diagnosis-flag"),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.queue_state).toEqual({
      kind: "error",
      category: "diagnosis-flag",
      decided: 0,
      message:
        "Stats unavailable: kg_review_session.py failed with exit 1: ValueError: decision references cluster not in loaded batch",
    });
  });

  it("records /api/decide through the shared KG review driver with voice source", async () => {
    const calls: CommandCall[] = [];
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
      },
      runCommand: async (call) => {
        calls.push(call);
        return commandResult({
          recorded: "diagnosis-flag:cantaloupe",
          decision: { action: "merge", source: "voice" },
        });
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/decide", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          cluster_id: "diagnosis-flag:cantaloupe",
          decision: {
            action: "merge",
            canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
            note: "merge them all",
          },
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(calls[0].args).toContain("--batch=/batch.json");
    const decisionArg = calls[0].args.find((arg) =>
      arg.startsWith("--decision-json="),
    );
    expect(decisionArg).toBeString();
    const decisionJson = decisionArg?.slice("--decision-json=".length) || "{}";
    expect(JSON.parse(decisionJson)).toMatchObject({
      action: "merge",
      canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
      note: "merge them all",
      source: "voice",
    });
  });

  it("migrates the legacy voice decisions file shape into kg-flag-decisions-v1", () => {
    const migrated = legacyDecisionsToKgFlagV1(
      {
        version: 1,
        decisions: {
          "diagnosis-flag:cantaloupe": {
            action: "merge_all",
            canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
            note: "merge all",
            source: "voice",
            decided_at: "2026-06-05T12:21:57.391406+00:00",
          },
        },
        rules: [],
      },
      [cantaloupeCluster],
      "kg-phase1-flag-batch-2026-06-05",
    );

    expect(migrated?.schema).toBe("kg-flag-decisions-v1");
    expect(migrated?.merge).toEqual([
      {
        stem: "cantaloupe",
        category: "diagnosis-flag",
        source: "voice",
        canonical: {
          id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
          name: "Cantaloupe",
          type: "company",
        },
        members: [
          {
            id: "141df1c6-0ee7-566c-a2a7-f03a76c294fd",
            name: "Cantaloupe",
            type: "project",
          },
        ],
        note: "merge all",
        decided_at: "2026-06-05T12:21:57.391406+00:00",
      },
    ]);
    expect(migrated?.keep).toEqual([]);
  });

  it("runs legacy decisions migration inside the driver sidecar lock", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-lock-test-"));
    const batchPath = join(root, "batch.json");
    const decisionsPath = join(root, "decisions.json");
    await writeFile(
      batchPath,
      JSON.stringify({ "diagnosis-flag": [cantaloupeCluster] }),
    );
    await writeFile(
      decisionsPath,
      JSON.stringify({
        version: 1,
        decisions: {
          "diagnosis-flag:cantaloupe": {
            action: "merge_all",
            canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
          },
        },
      }),
    );

    let lockPathSeen: string | null = null;
    let migratedBeforeUnlock = false;
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath,
        decisionsPath,
      },
      lockDecisionFile: async (path, work) => {
        lockPathSeen = decisionLockPath(path);
        const result = await work();
        const migrated = JSON.parse(await readFile(decisionsPath, "utf8"));
        migratedBeforeUnlock = migrated.schema === "kg-flag-decisions-v1";
        return result;
      },
      runCommand: async () => commandResult({ cluster: cantaloupeCluster }),
    });

    try {
      const response = await app.fetch(
        new Request("http://localhost/api/next?category=diagnosis-flag"),
      );

      expect(response.status).toBe(200);
      expect(lockPathSeen as string | null).toBe(`${decisionsPath}.lock`);
      expect(migratedBeforeUnlock).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("uses loopback as the default bind host unless explicitly overridden", () => {
    expect(DEFAULT_CONFIG.hostname).toBe("127.0.0.1");
  });

  it("rejects cluster members without a numeric chunk count", async () => {
    const app = createVoiceReviewApp({
      fetchImpl: async () =>
        new Response(
          JSON.stringify({
            choices: [{ message: { content: '{"action":"keep"}' } }],
          }),
          { headers: { "content-type": "application/json" } },
        ),
    });

    const response = await app.fetch(
      new Request("http://localhost/api/interpret", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          transcript: "keep these separate",
          cluster: {
            ...cantaloupeCluster,
            members: [
              {
                id: "bad",
                name: "Bad",
                type: "concept",
              },
            ],
          },
        }),
      }),
    );

    expect(response.status).toBe(400);
  });

  it("decorates driver stats with skipped counts without changing undecided semantics", () => {
    const decorated = decorateStatsWithSkippedCounts(
      {
        per_category: {
          "diagnosis-flag": {
            total: 8,
            explicit: 2,
            by_rule: 0,
            undecided: 6,
          },
        },
      },
      {
        skipped: [
          { category: "diagnosis-flag", stem: "maybe" },
          { category: "sep-variants", stem: "other" },
        ],
      },
    );

    expect(decorated).toEqual({
      per_category: {
        "diagnosis-flag": {
          total: 8,
          explicit: 2,
          by_rule: 0,
          undecided: 6,
          skipped: 1,
        },
      },
    });
  });

  it("serves the natural conversation page with one session button and no tap-to-talk copy", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect((html.match(/<button\b/g) || [])).toHaveLength(1);
    expect(html).toContain("Start session");
    expect(html).toContain("End session");
    expect(html).toContain("LISTENING");
    expect(html).toContain("SETTLING");
    expect(html).toContain("THINKING");
    expect(html).toContain("SPEAKING");
    expect(html).toContain("THINKING_PAUSE_PHRASES");
    expect(html).toContain("רגע");
    expect(html).not.toContain("Tap Record");
    expect(html).not.toContain("tap Record");
  });

  it("renders a custom default category from the loaded batch as the selected option", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-category-test-"));
    const batchPath = join(root, "batch.json");
    await writeFile(
      batchPath,
      JSON.stringify({
        "etan-queue": [],
        "other-live": [],
      }),
    );
    const app = createVoiceReviewApp({
      config: {
        defaultCategory: "etan-queue",
        batchPath,
      },
    });

    try {
      const response = await app.fetch(new Request("http://localhost/"));
      const html = await response.text();
      const select = html.slice(
        html.indexOf('<select id="category"'),
        html.indexOf("</select>", html.indexOf('<select id="category"')),
      );

      expect(select).toContain(
        '<option value="etan-queue" selected>etan-queue</option>',
      );
      expect(select).toContain('<option value="other-live">other-live</option>');
      expect(select).toContain(
        '<option value="diagnosis-flag">diagnosis-flag</option>',
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects empty whisper transcripts before interpretation", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-transcribe-test-"));
    const calls: CommandCall[] = [];
    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
        sttVocabularyPath: join(root, "missing-vocab.json"),
        ffmpegPath: "/test/bin/ffmpeg",
        whisperCliPath: "/test/bin/whisper-cli",
      },
      runCommand: async (call) => {
        calls.push(call);
        return {
          exitCode: 0,
          stdout: call.args[0].includes("whisper-cli") ? " \n" : "",
          stderr: "",
          durationMs: 12,
        };
      },
    });

    try {
      const response = await app.fetch(
        new Request("http://localhost/api/transcribe", {
          method: "POST",
          headers: { "content-type": "application/octet-stream" },
          body: new Blob(["not real audio"]),
        }),
      );

      expect(response.status).toBe(422);
      expect(await response.json()).toEqual({ error: "empty transcript" });
      expect(calls).toHaveLength(2);
      expect(calls.map((call) => call.args[0])).toEqual([
        "/test/bin/ffmpeg",
        "/test/bin/whisper-cli",
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("preserves failed decode blobs under a capped failed directory", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-transcribe-failed-"));
    const failedDir = join(root, "failed");
    await mkdir(failedDir, { recursive: true });
    const validWebmThatFailsDecode = new Blob([
      new Uint8Array([0x1a, 0x45, 0xdf, 0xa3]),
      "broken webm",
    ]);
    const oldTime = new Date("2026-01-01T00:00:00.000Z");
    for (let index = 0; index < 22; index += 1) {
      const path = join(failedDir, `old-${String(index).padStart(2, "0")}.webm`);
      await writeFile(path, `old-${index}`);
      await utimes(path, oldTime, oldTime);
    }

    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
        sttVocabularyPath: join(root, "missing-vocab.json"),
        ffmpegPath: "/test/bin/ffmpeg",
        whisperCliPath: "/test/bin/whisper-cli",
      },
      runCommand: async () => ({
        exitCode: 1,
        stdout: "",
        stderr: "Invalid EBML header",
        durationMs: 5,
      }),
    });

    try {
      const response = await app.fetch(
        new Request("http://localhost/api/transcribe", {
          method: "POST",
          headers: { "content-type": "audio/webm;codecs=opus" },
          body: validWebmThatFailsDecode,
        }),
      );
      const body = await response.json();
      const failedFiles = await readdir(failedDir);
      const preservedContents = await Promise.all(
        failedFiles
          .filter((name) => name.endsWith(".webm"))
          .map((name) => readFile(join(failedDir, name), "utf8")),
      );

      expect(response.status).toBe(500);
      expect(body.error).toContain("Invalid EBML header");
      expect(failedFiles).toHaveLength(20);
      expect(preservedContents.some((content) => content.includes("broken webm"))).toBe(
        true,
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("transcribes webm audio that starts with an EBML header", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-transcribe-test-"));
    const calls: CommandCall[] = [];
    const validWebm = new Uint8Array([
      0x1a, 0x45, 0xdf, 0xa3, 0x01, 0x02, 0x03, 0x04,
    ]);
    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
        sttVocabularyPath: join(root, "missing-vocab.json"),
        ffmpegPath: "/test/bin/ffmpeg",
        whisperCliPath: "/test/bin/whisper-cli",
      },
      runCommand: async (call) => {
        calls.push(call);
        return {
          exitCode: 0,
          stdout: call.args[0].includes("whisper-cli") ? "turn two correction\n" : "",
          stderr: "",
          durationMs: 12,
        };
      },
    });

    try {
      const response = await app.fetch(
        new Request("http://localhost/api/transcribe", {
          method: "POST",
          headers: { "content-type": "audio/webm" },
          body: new Blob([validWebm], { type: "audio/webm" }),
        }),
      );

      expect(response.status).toBe(200);
      expect(await response.json()).toMatchObject({
        text: "turn two correction",
      });
      expect(calls.map((call) => call.args[0])).toEqual([
        "/test/bin/ffmpeg",
        "/test/bin/whisper-cli",
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("propagates client aborts into /api/transcribe subprocesses", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-transcribe-abort-"));
    const clientAbort = new AbortController();
    let commandSignal: AbortSignal | undefined;
    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
        sttVocabularyPath: join(root, "missing-vocab.json"),
        ffmpegPath: "/test/bin/ffmpeg",
        whisperCliPath: "/test/bin/whisper-cli",
      },
      runCommand: async (call) => {
        commandSignal = call.signal;
        clientAbort.abort();
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (!commandSignal?.aborted) {
          throw new Error("client abort did not reach transcribe subprocess");
        }
        throw new DOMException("request aborted", "AbortError");
      },
    });

    try {
      const response = await app.fetch(
        new Request("http://localhost/api/transcribe", {
          method: "POST",
          headers: { "content-type": "application/octet-stream" },
          body: new Blob(["not real audio"]),
          signal: clientAbort.signal,
        }),
      );

      expect(response.status).toBe(499);
      expect(commandSignal?.aborted).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("rejects headerless mid-stream webm slices before ffmpeg", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-transcribe-test-"));
    const calls: CommandCall[] = [];
    const warnings: string[] = [];
    const originalWarn = console.warn;
    const validWebm = new Uint8Array([
      0x1a, 0x45, 0xdf, 0xa3, 0x01, 0x02, 0x03, 0x04,
    ]);
    const headerlessMidstreamSlice = validWebm.slice(4);
    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
        sttVocabularyPath: join(root, "missing-vocab.json"),
        ffmpegPath: "/test/bin/ffmpeg",
        whisperCliPath: "/test/bin/whisper-cli",
      },
      runCommand: async (call) => {
        calls.push(call);
        return {
          exitCode: 0,
          stdout: call.args[0].includes("whisper-cli") ? "should not run\n" : "",
          stderr: "",
          durationMs: 12,
        };
      },
    });

    try {
      console.warn = (message?: unknown) => {
        warnings.push(String(message));
      };
      const response = await app.fetch(
        new Request("http://localhost/api/transcribe", {
          method: "POST",
          headers: { "content-type": "audio/webm" },
          body: new Blob([headerlessMidstreamSlice], { type: "audio/webm" }),
        }),
      );

      expect(response.status).toBe(422);
      expect(await response.json()).toEqual({
        error: "invalid webm audio",
        code: "invalid_webm_header",
        recoverable: true,
      });
      expect(calls).toHaveLength(0);
      expect(warnings).toHaveLength(1);
      expect(JSON.parse(warnings[0])).toMatchObject({
        event: "voicereview_transcribe_invalid_webm",
        code: "invalid_webm_header",
      });
    } finally {
      console.warn = originalWarn;
      await rm(root, { recursive: true, force: true });
    }
  });

  it("builds a bounded whisper prompt from vocabulary prompt terms", () => {
    const prompt = buildWhisperPrompt(
      ["BrainLayer", "Cantaloupe AI", "VoiceLayer", "one two three four five"],
      5,
    );

    expect(prompt).toBe("BrainLayer Cantaloupe AI VoiceLayer");
    expect(prompt.split(/\s+/)).toHaveLength(4);
  });

  it("builds whisper-cli args with --prompt and no shell string", () => {
    const args = buildWhisperArgs({
      binary: "/opt/homebrew/bin/whisper-cli",
      modelPath: "/model.bin",
      wavPath: "/tmp/input.wav",
      prompt: "BrainLayer Cantaloupe",
    });

    expect(args).toEqual([
      "/opt/homebrew/bin/whisper-cli",
      "-m",
      "/model.bin",
      "-f",
      "/tmp/input.wav",
      "--no-timestamps",
      "--prompt",
      "BrainLayer Cantaloupe",
      "--no-prints",
    ]);
  });

  it("builds strict LiteRT interpretation messages with examples and cluster ids", () => {
    const messages = buildInterpretMessages({
      transcript: "merge them all, the company one is the real one",
      cluster: cantaloupeCluster,
    });

    expect(messages[0].role).toBe("system");
    expect(messages[0].content).toContain("merge|keep|mixed|skip|question");
    expect(messages[0].content).toContain("exactly one JSON object");
    expect(messages[0].content).toContain("few-shot examples");
    expect(messages[0].content).toContain('"action":"question"');
    expect(messages[1].content).toContain("diagnosis-flag:cantaloupe");
    expect(messages[1].content).toContain("16db6804-dc3e-5465-93d2-e3956c3f63f5");
  });

  it("parses English and Hebrew-English questions as non-decision turns", () => {
    expect(
      parseInterpretDecision(
        '{"action":"question","question":"which chunks does the company one have?","note":"which chunks does the company one have?"}',
        cantaloupeCluster,
        "which chunks does the company one have?",
      ),
    ).toEqual({
      action: "question",
      question: "which chunks does the company one have?",
      note: "which chunks does the company one have?",
      source: "voice",
    });

    expect(
      parseInterpretDecision(
        '{"action":"question","question":"איזה chunks יש ל-company one?","note":"model paraphrase"}',
        cantaloupeCluster,
        "איזה chunks יש ל-company one?",
      ),
    ).toEqual({
      action: "question",
      question: "איזה chunks יש ל-company one?",
      note: "איזה chunks יש ל-company one?",
      source: "voice",
    });
  });

  it("instructs LiteRT-LM to skip ambiguous answers with verbatim notes", () => {
    const messages = buildInterpretMessages({
      transcript: "I am not sure, maybe this is one thing but maybe not",
      cluster: cantaloupeCluster,
    });

    expect(messages[0].content).toContain(
      "If the transcript is ambiguous or non-deterministic, choose skip",
    );
    expect(messages[0].content).toContain(
      '{"action":"skip","note":"I am not sure, maybe this is one thing but maybe not"}',
    );
    expect(messages[0].content).toContain(
      "Every action must carry note equal to the verbatim transcript",
    );
  });

  it("parses fenced LiteRT JSON into a valid voice decision", () => {
    const decision = parseInterpretDecision(
      "```json\n{\"action\":\"merge\",\"canonical_id\":\"16db6804-dc3e-5465-93d2-e3956c3f63f5\",\"note\":\"merge them all\"}\n```",
      cantaloupeCluster,
      "merge them all",
    );

    expect(decision).toEqual({
      action: "merge",
      canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
      note: "merge them all",
      source: "voice",
    });
    expect(buildConfirmation(decision, cantaloupeCluster)).toBe(
      "Merge all into Cantaloupe, company.",
    );
  });

  it("overrides model note with the exact verbatim transcript", () => {
    const decision = parseInterpretDecision(
      '{"action":"keep","note":"model paraphrase"}',
      cantaloupeCluster,
      "keep them separate, I mean literally separate",
    );

    expect(decision).toEqual({
      action: "keep",
      note: "keep them separate, I mean literally separate",
      source: "voice",
    });
  });

  it("rejects mixed decisions that omit cluster members", () => {
    expect(() =>
      parseInterpretDecision(
        '{"action":"mixed","members":{"16db6804-dc3e-5465-93d2-e3956c3f63f5":"merge"}}',
        cantaloupeCluster,
        "mixed, merge the company but I did not say the rest",
      ),
    ).toThrow("mixed interpretation requires every cluster member");
  });

  it("serves /api/interpret with a mocked LiteRT fetch response", async () => {
    let requestedBody: any;
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        batchPath: "/batch.json",
        decisionsPath: "/decisions.json",
        liteRtUrl: "http://127.0.0.1:9379/v1/chat/completions",
        liteRtModel: "gemma4-e4b,gpu",
      },
      fetchImpl: async (_url, init) => {
        requestedBody = JSON.parse(String(init?.body));
        return new Response(
          JSON.stringify({
            choices: [
              {
                message: {
                  content: JSON.stringify({
                    action: "merge",
                    canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
                    note: "merge them all, the company one is the real one",
                  }),
                },
              },
            ],
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/interpret", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          transcript: "merge them all, the company one is the real one",
          cluster: cantaloupeCluster,
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(requestedBody.model).toBe("gemma4-e4b,gpu");
    expect(requestedBody.messages[0].content).toContain("STRICT");
    expect(await response.json()).toMatchObject({
      decision: {
        action: "merge",
        canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
        source: "voice",
      },
      confirmation: "Merge all into Cantaloupe, company.",
    });
  });

  it("propagates client aborts into /api/interpret LiteRT fetches", async () => {
    const clientAbort = new AbortController();
    let upstreamSignal: AbortSignal | undefined;
    const app = createVoiceReviewApp({
      config: {
        requestTimeoutMs: 60000,
        liteRtUrl: "http://127.0.0.1:9379/v1/chat/completions",
      },
      fetchImpl: async (_url, init) => {
        upstreamSignal = init?.signal as AbortSignal | undefined;
        clientAbort.abort();
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (!upstreamSignal?.aborted) {
          throw new Error("client abort did not reach upstream LiteRT fetch");
        }
        throw new DOMException("request aborted", "AbortError");
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/interpret", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          transcript: "merge them all",
          cluster: cantaloupeCluster,
        }),
        signal: clientAbort.signal,
      }),
    );

    expect(response.status).toBe(499);
    expect(upstreamSignal?.aborted).toBe(true);
    expect(await response.json()).toEqual({ error: "request aborted" });
  });

  it("serves /api/interpret question actions without forcing a decision", async () => {
    const app = createVoiceReviewApp({
      fetchImpl: async () =>
        new Response(
          JSON.stringify({
            choices: [
              {
                message: {
                  content: JSON.stringify({
                    action: "question",
                    question: "what would happen if we merge them?",
                    note: "what would happen if we merge them?",
                  }),
                },
              },
            ],
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
    });

    const response = await app.fetch(
      new Request("http://localhost/api/interpret", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          transcript: "what would happen if we merge them?",
          cluster: cantaloupeCluster,
        }),
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      decision: {
        action: "question",
        question: "what would happen if we merge them?",
        source: "voice",
      },
      confirmation: null,
    });
  });

  it("builds evidence helper args with the fixture DB path and member ids isolated as argv", () => {
    const args = buildEvidenceArgs({
      pythonScript: "/repo/src/voicereview-web/kg_evidence.py",
      dbPath: "/tmp/fixture.db",
      members: cantaloupeCluster.members,
      perMember: 2,
      question: "what context exists around the hiring manager",
      deep: true,
    });

    expect(args).toEqual([
      "python3",
      "/repo/src/voicereview-web/kg_evidence.py",
      "--db=/tmp/fixture.db",
      `--members-json=${JSON.stringify(cantaloupeCluster.members)}`,
      "--per-member=2",
      "--question=what context exists around the hiring manager",
      "--deep",
    ]);
  });

  it("reads top snippets per member from a fixture KG DB through the python helper", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-evidence-test-"));
    const dbPath = join(root, "brainlayer.db");
    const db = new Database(dbPath);
    try {
      db.exec(`
        CREATE TABLE kg_entity_chunks (
          entity_id TEXT NOT NULL,
          chunk_id TEXT NOT NULL,
          relevance REAL DEFAULT 1.0,
          context TEXT
        );
        CREATE TABLE chunks (
          id TEXT PRIMARY KEY,
          content TEXT NOT NULL,
          summary TEXT,
          project TEXT,
          content_type TEXT,
          source TEXT,
          created_at TEXT,
          importance REAL DEFAULT 0,
          archived INTEGER DEFAULT 0,
          status TEXT DEFAULT 'active'
        );
      `);
      db.prepare(
        "INSERT INTO chunks (id, content, summary, project, content_type, source, created_at, importance) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ).run(
        "chunk-company",
        "Cantaloupe company evidence says the hiring manager liked the candidate story.",
        null,
        "coach",
        "assistant_text",
        "realtime_watcher",
        "2026-03-10T07:38:09.956Z",
        0.9,
      );
      db.prepare(
        "INSERT INTO chunks (id, content, summary, project, content_type, source, created_at, importance) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      ).run(
        "chunk-project",
        "Cantaloupe project evidence is about a migration prompt and project list.",
        "Cantaloupe project summary",
        "orchestrator",
        "user_message",
        "realtime_watcher",
        "2026-03-26T19:32:00.847Z",
        0.8,
      );
      db.prepare(
        "INSERT INTO kg_entity_chunks (entity_id, chunk_id, relevance, context) VALUES (?, ?, ?, ?)",
      ).run(cantaloupeCluster.members[0].id, "chunk-company", 0.95, "company context");
      db.prepare(
        "INSERT INTO kg_entity_chunks (entity_id, chunk_id, relevance, context) VALUES (?, ?, ?, ?)",
      ).run(cantaloupeCluster.members[1].id, "chunk-project", 0.9, "project context");
    } finally {
      db.close();
    }

    try {
      const proc = Bun.spawn(
        buildEvidenceArgs({
          pythonScript: join(import.meta.dir, "kg_evidence.py"),
          dbPath,
          members: cantaloupeCluster.members,
          perMember: 1,
        }),
        { stdout: "pipe", stderr: "pipe" },
      );
      const [stdout, stderr, exitCode] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
      ]);

      expect(stderr).toBe("");
      expect(exitCode).toBe(0);
      expect(JSON.parse(stdout)).toEqual({
        members: [
          {
            id: cantaloupeCluster.members[0].id,
            name: "Cantaloupe",
            type: "company",
            chunks: 13,
            snippets: [
              {
                chunk_id: "chunk-company",
                project: "coach",
                content_type: "assistant_text",
                source: "realtime_watcher",
                created_at: "2026-03-10T07:38:09.956Z",
                relevance: 0.95,
                context: "company context",
                text: "Cantaloupe company evidence says the hiring manager liked the candidate story.",
              },
            ],
          },
          {
            id: cantaloupeCluster.members[1].id,
            name: "Cantaloupe",
            type: "project",
            chunks: 4,
            snippets: [
              {
                chunk_id: "chunk-project",
                project: "orchestrator",
                content_type: "user_message",
                source: "realtime_watcher",
                created_at: "2026-03-26T19:32:00.847Z",
                relevance: 0.9,
                context: "project context",
                text: "Cantaloupe project summary",
              },
            ],
          },
        ],
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("builds grounded conversational LiteRT messages from cluster facts, evidence, and history", () => {
    const evidence: ConversationEvidence = {
      members: [
        {
          ...cantaloupeCluster.members[0],
          snippets: [
            {
              chunk_id: "chunk-company",
              project: "coach",
              content_type: "assistant_text",
              source: "realtime_watcher",
              created_at: "2026-03-10T07:38:09.956Z",
              relevance: 0.95,
              context: "company context",
              text: "Cantaloupe company evidence says the hiring manager liked the candidate story.",
            },
          ],
        },
      ],
    };

    const messages = buildConverseMessages({
      question: "which chunks does the company one have?",
      cluster: cantaloupeCluster,
      history: [
        {
          question: "what is the difference?",
          answer: "The company member has hiring evidence.",
        },
      ],
      evidence,
    });

    expect(messages[0].content).toContain("answer ONLY from the provided evidence");
    expect(messages[0].content).toContain("2-4 sentences");
    expect(messages[0].content).toContain("I don't see evidence about that");
    expect(messages[1].content).toContain("diagnosis-flag:cantaloupe");
    expect(messages[1].content).toContain("Cantaloupe (company, 13 chunks)");
    expect(messages[1].content).toContain("chunk-company");
    expect(messages[1].content).toContain("company context");
    expect(messages[1].content).toContain("what is the difference?");
    expect(messages[1].content).toContain("which chunks does the company one have?");
  });

  it("serves first-turn /api/converse with evidence timings and a grounded LiteRT answer", async () => {
    let requestedBody: any;
    const calls: CommandCall[] = [];
    const evidence: ConversationEvidence = {
      members: [
        {
          ...cantaloupeCluster.members[0],
          snippets: [
            {
              chunk_id: "chunk-company",
              project: "coach",
              content_type: "assistant_text",
              source: "realtime_watcher",
              created_at: "2026-03-10T07:38:09.956Z",
              relevance: 0.95,
              context: "company context",
              text: "Cantaloupe company evidence says the hiring manager liked the candidate story.",
            },
          ],
        },
      ],
    };
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        brainlayerDbPath: "/tmp/fixture.db",
        liteRtUrl: "http://127.0.0.1:9379/v1/chat/completions",
        liteRtModel: "gemma4-e4b,gpu",
      },
      runCommand: async (call) => {
        calls.push(call);
        return {
          exitCode: 0,
          stdout: JSON.stringify(evidence),
          stderr: "",
          durationMs: 7,
        };
      },
      fetchImpl: async (_url, init) => {
        requestedBody = JSON.parse(String(init?.body));
        return new Response(
          JSON.stringify({
            choices: [
              {
                message: {
                  content:
                    "The company member has one shown snippet about the hiring manager liking the candidate story.",
                },
              },
            ],
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/converse", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          question: "which chunks does the company one have?",
          cluster: cantaloupeCluster,
        }),
      }),
    );

    const body = await response.json();
    expect(response.status).toBe(200);
    expect(calls[0].args).toContain("--db=/tmp/fixture.db");
    expect(requestedBody.model).toBe("gemma4-e4b,gpu");
    expect(requestedBody.messages[1].content).toContain("chunk-company");
    expect(body).toMatchObject({
      answer:
        "The company member has one shown snippet about the hiring manager liking the candidate story.",
      evidence,
      evidence_depth: "shallow",
      timings: { evidence_ms: 7 },
    });
    expect(body.timings.llm_ms).toBeGreaterThanOrEqual(0);
  });

  it("propagates client aborts into /api/converse evidence and LiteRT work", async () => {
    const clientAbort = new AbortController();
    let evidenceSignal: AbortSignal | undefined;
    let upstreamSignal: AbortSignal | undefined;
    const evidence: ConversationEvidence = {
      members: [
        {
          ...cantaloupeCluster.members[0],
          snippets: [
            {
              chunk_id: "chunk-company",
              project: "coach",
              content_type: "summary",
              source: "brainlayer",
              created_at: "2026-03-10T07:38:09.956Z",
              relevance: 0.95,
              context: "company context",
              text: "Cantaloupe company evidence.",
            },
          ],
        },
      ],
    };
    const app = createVoiceReviewApp({
      config: {
        requestTimeoutMs: 60000,
        brainlayerDbPath: "/tmp/fixture.db",
        liteRtUrl: "http://127.0.0.1:9379/v1/chat/completions",
      },
      runCommand: async (call) => {
        evidenceSignal = call.signal;
        return commandResult(evidence);
      },
      fetchImpl: async (_url, init) => {
        upstreamSignal = init?.signal as AbortSignal | undefined;
        clientAbort.abort();
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (!upstreamSignal?.aborted) {
          throw new Error("client abort did not reach upstream LiteRT fetch");
        }
        throw new DOMException("request aborted", "AbortError");
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/converse", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          question: "which chunks does the company one have?",
          cluster: cantaloupeCluster,
        }),
        signal: clientAbort.signal,
      }),
    );

    expect(response.status).toBe(499);
    expect(evidenceSignal).toBeDefined();
    expect(upstreamSignal?.aborted).toBe(true);
    expect(evidenceSignal?.aborted).toBe(true);
  });

  it("runs deeper BrainLayer evidence search instead of dead-ending on thin snippets", async () => {
    const shallowEvidence: ConversationEvidence = {
      members: [
        {
          ...cantaloupeCluster.members[0],
          snippets: [
            {
              chunk_id: "thin-company",
              project: "coach",
              content_type: "summary",
              source: "brainlayer",
              created_at: "2026-03-10T07:38:09.956Z",
              relevance: 0.95,
              context: "thin context",
              text: "Cantaloupe company summary.",
            },
          ],
        },
      ],
    };
    const deepEvidence: ConversationEvidence = {
      members: [
        {
          ...cantaloupeCluster.members[0],
          snippets: [
            {
              chunk_id: "deep-company",
              project: "coach",
              content_type: "user_message",
              source: "brainlayer",
              created_at: "2026-03-11T07:38:09.956Z",
              relevance: 0.72,
              context: "full chunk context",
              text: "The full BrainLayer chunk says the Cantaloupe hiring manager liked the candidate story and wanted follow-up.",
            },
          ],
        },
      ],
    };
    const calls: CommandCall[] = [];
    const fetchBodies: any[] = [];
    const app = createVoiceReviewApp({
      config: {
        brainlayerWorktree: "/tmp/voice-review-wt",
        brainlayerDbPath: "/tmp/fixture.db",
        deepLiteRtModel: "gemma4-12b,gpu",
      },
      runCommand: async (call) => {
        calls.push(call);
        return commandResult(calls.length === 1 ? shallowEvidence : deepEvidence);
      },
      fetchImpl: async (_url, init) => {
        const requestBody = JSON.parse(String(init?.body));
        fetchBodies.push(requestBody);
        const content =
          fetchBodies.length === 1
            ? "I don't see evidence about that in the provided snippets."
            : "The deeper BrainLayer context says the hiring manager liked the candidate story and wanted follow-up.";
        return new Response(
          JSON.stringify({ choices: [{ message: { content } }] }),
          { status: 200, headers: { "content-type": "application/json" } },
        );
      },
    });

    const response = await app.fetch(
      new Request("http://localhost/api/converse", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          question: "what was the actual context around the hiring manager?",
          cluster: cantaloupeCluster,
        }),
      }),
    );

    const body = await response.json();
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(2);
    expect(calls[1].args).toContain("--deep");
    expect(calls[1].args).toContain(
      "--question=what was the actual context around the hiring manager?",
    );
    expect(fetchBodies).toHaveLength(2);
    expect(fetchBodies[0].model).toBe(DEFAULT_CONFIG.liteRtModel);
    expect(fetchBodies[1].model).toBe("gemma4-12b,gpu");
    expect(fetchBodies[1].messages[1].content).toContain("deep-company");
    expect(body.answer).toBe(
      "The deeper BrainLayer context says the hiring manager liked the candidate story and wanted follow-up.",
    );
    expect(body.preface).toBe("Let me look deeper.");
    expect(body.evidence_depth).toBe("deep");
    expect(body.deep_model).toBe("gemma4-12b,gpu");
    expect(body.evidence).toEqual(deepEvidence);
    expect(body.timings.evidence_ms).toBe(12);
    expect(body.timings.deep_evidence_ms).toBe(12);
  });

  it("serves TTS audio with edge-tts word-boundary metadata and configurable cadence", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-tts-test-"));
    const calls: CommandCall[] = [];
    try {
      const app = createVoiceReviewApp({
        config: {
          tempDir: root,
        },
        runCommand: async (call) => {
          calls.push(call);
          const mediaPath =
            call.args
              .find((arg) => arg.startsWith("--write-media="))
              ?.slice("--write-media=".length) || "";
          const metadataPath =
            call.args
              .find((arg) => arg.startsWith("--write-metadata="))
              ?.slice("--write-metadata=".length) || "";
          await writeFile(mediaPath, new Uint8Array([1, 2, 3]));
          await writeFile(
            metadataPath,
            [
              JSON.stringify({
                type: "WordBoundary",
                offset: 0,
                duration: 1000000,
                text: "Hello",
              }),
              JSON.stringify({
                type: "WordBoundary",
                offset: 1500000,
                duration: 1000000,
                text: "world",
              }),
            ].join("\n"),
          );
          return commandResult("");
        },
      });

      const response = await app.fetch(
        new Request("http://localhost/api/tts", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            text: "Hello world",
            voice: "en-US-GuyNeural",
            rate: "-12%",
          }),
        }),
      );

      expect(response.status).toBe(200);
      expect(calls[0].args.some((arg) => arg.endsWith("edge-tts-words.py"))).toBe(
        true,
      );
      expect(calls[0].args.some((arg) => arg.startsWith("--write-metadata="))).toBe(
        true,
      );
      expect(calls[0].args).toContain("--voice=en-US-GuyNeural");
      expect(calls[0].args).toContain("--rate=-12%");
      expect(calls[0].args).not.toContain("--rate");
      expect(calls[0].args).not.toContain("-12%");
      expect(
        JSON.parse(response.headers.get("x-word-boundaries") || "[]"),
      ).toEqual([
        { offset_ms: 0, duration_ms: 100, text: "Hello" },
        { offset_ms: 150, duration_ms: 100, text: "world" },
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("propagates client aborts into /api/tts subprocesses", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-tts-abort-"));
    const clientAbort = new AbortController();
    let commandSignal: AbortSignal | undefined;
    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
      },
      runCommand: async (call) => {
        commandSignal = call.signal;
        clientAbort.abort();
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (!commandSignal?.aborted) {
          throw new Error("client abort did not reach TTS subprocess");
        }
        throw new DOMException("request aborted", "AbortError");
      },
    });

    try {
      const response = await app.fetch(
        new Request("http://localhost/api/tts", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            text: "Hello world",
            voice: "en-US-GuyNeural",
            rate: "-8%",
          }),
          signal: clientAbort.signal,
        }),
      );

      expect(response.status).toBe(499);
      expect(commandSignal?.aborted).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("strips structural metadata and repeated prompt segments from spoken TTS text", async () => {
    const spoken = humanizeSpokenText(
      [
        "Review this cluster.",
        "Acme Corp (company, 42 chunks)",
        "as context with 0 chunks",
        "as evidence with 1 chunks",
        "Should these merge?",
        "",
        "Review this cluster.",
        "Acme Corp (company, 42 chunks)",
        "as context with 0 chunks",
        "as evidence with 1 chunks",
        "Should these merge?",
      ].join("\n"),
    );

    expect(spoken).toBe("Review this cluster. Acme Corp. Should these merge?");
    expect(spoken).not.toContain("company");
    expect(spoken).not.toContain("42 chunks");
    expect(spoken).not.toContain("0 chunks");
    expect(spoken).not.toContain("1 chunks");
    expect(spoken).not.toContain("as context");
    expect(spoken).not.toContain("as evidence");
  });

  it("strips live inline speak metadata and repeated prompt sentences from spoken TTS text", () => {
    const liveSpeak =
      `Cluster 'Q1 of 6 — invocable substrates', category etan-queue, 1 entries. All named DICTIONARY QUESTION (not a merge): TypeScript, Python, AI models like Qwen and Kokoro, frameworks like MLX — the test says build-WITH means Tool, but most people call these Technology. One ruling for all three families: Tools, or widen Technology? Capture Etan's answer verbatim as the note, then record skip.. DICTIONARY QUESTION (not a merge): TypeScript, Python, AI models like Qwen and Kokoro, frameworks like MLX — the test says build-WITH means Tool, but most people call these Technology. One ruling for all three families: Tools, or widen Technology? Capture Etan's answer verbatim as the note, then record skip. as question with 0 chunks. Merge, keep separate, mixed, or skip?`;

    const spoken = humanizeSpokenText(liveSpeak);

    expect(spoken).toBe(
      `Cluster 'Q1 of 6 — invocable substrates', category etan-queue, 1 entries. All named DICTIONARY QUESTION (not a merge): TypeScript, Python, AI models like Qwen and Kokoro, frameworks like MLX — the test says build-WITH means Tool, but most people call these Technology. One ruling for all three families: Tools, or widen Technology? Capture Etan's answer verbatim as the note, then record skip. Merge, keep separate, mixed, or skip?`,
    );
    expect(spoken).not.toContain("as question with 0 chunks");
    expect(spoken.match(/DICTIONARY QUESTION/g)).toHaveLength(1);
  });

  it("dedupes repeated long spoken segments without dropping repeated short words", () => {
    const spoken = humanizeSpokenText(
      [
        "Wait.",
        "Wait.",
        "This long prompt sentence should only be spoken one time in the review flow.",
        "This long prompt sentence should only be spoken one time in the review flow.",
        "yes.",
        "yes.",
      ].join(" "),
    );

    expect(spoken).toBe(
      "Wait. Wait. This long prompt sentence should only be spoken one time in the review flow. yes. yes.",
    );
  });

  it("normalizes legacy LiteRT action names to dashboard action names", () => {
    expect(
      parseInterpretDecision(
        '{"action":"merge_all","canonical_id":"16db6804-dc3e-5465-93d2-e3956c3f63f5"}',
        cantaloupeCluster,
        "merge them all",
      ),
    ).toMatchObject({ action: "merge" });

    expect(
      parseInterpretDecision(
        '{"action":"keep_all"}',
        cantaloupeCluster,
        "keep them separate",
      ),
    ).toMatchObject({ action: "keep" });
  });
});
