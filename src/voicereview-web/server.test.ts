import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "bun:test";
import {
  buildConfirmation,
  buildDriverArgs,
  buildInterpretMessages,
  buildWhisperArgs,
  buildWhisperPrompt,
  createVoiceReviewApp,
  decorateStatsWithSkippedCounts,
  decisionLockPath,
  DEFAULT_CONFIG,
  legacyDecisionsToKgFlagV1,
  parseInterpretDecision,
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
      "--batch",
      "/batch.json",
      "--decisions",
      "/decisions.json",
      "--category",
      "diagnosis-flag; rm -rf /",
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
    expect(calls[0].args).toContain("--category");
    expect(calls[0].env.PYTHONPATH).toBe("/tmp/voice-review-wt/src");
    expect(calls[0].cwd).toBe("/tmp/voice-review-wt");
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
    expect(calls[0].args).toContain("--batch");
    expect(calls[0].args).toContain("/batch.json");
    const decisionJson = calls[0].args[calls[0].args.indexOf("--decision-json") + 1];
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

  it("serves page logic that freezes recording context and unlocks load failures", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain("category.disabled = value || recording");
    expect(html).toContain("const recordingCluster = current");
    expect(html).toContain("processRecording(new Blob(chunks");
    expect(html).toContain("recordingCluster");
    expect(html).toContain("cluster: cluster");
    expect(html).toContain("cluster_id: cluster.cluster_id");
    expect(html).toContain("const decided = Math.max(0, total - undecided)");
    expect(html).toContain("const skipped = Number(bucket.skipped || 0)");
    expect(html).toContain("decided + \" decided · \" + skipped + \" skipped\"");
    expect(html).toContain("Tap Retry");
    expect(html).toContain("finally {\n        setBusy(false);");
    expect(html).toContain("addEventListener(\"ended\"");
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
    expect(messages[0].content).toContain("merge|keep|mixed|skip");
    expect(messages[0].content).toContain("exactly one JSON object");
    expect(messages[0].content).toContain("few-shot examples");
    expect(messages[1].content).toContain("diagnosis-flag:cantaloupe");
    expect(messages[1].content).toContain("16db6804-dc3e-5465-93d2-e3956c3f63f5");
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
