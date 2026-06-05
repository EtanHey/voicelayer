import { describe, expect, it } from "bun:test";
import {
  buildConfirmation,
  buildDriverArgs,
  buildInterpretMessages,
  buildWhisperArgs,
  buildWhisperPrompt,
  createVoiceReviewApp,
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
          decision: { action: "merge_all", source: "voice" },
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
            action: "merge_all",
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
      action: "merge_all",
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
    expect(messages[0].content).toContain("merge_all|keep_all|mixed|skip");
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
      "```json\n{\"action\":\"merge_all\",\"canonical_id\":\"16db6804-dc3e-5465-93d2-e3956c3f63f5\",\"note\":\"merge them all\"}\n```",
      cantaloupeCluster,
      "merge them all",
    );

    expect(decision).toEqual({
      action: "merge_all",
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
      '{"action":"keep_all","note":"model paraphrase"}',
      cantaloupeCluster,
      "keep them separate, I mean literally separate",
    );

    expect(decision).toEqual({
      action: "keep_all",
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
                    action: "merge_all",
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
        action: "merge_all",
        canonical_id: "16db6804-dc3e-5465-93d2-e3956c3f63f5",
        source: "voice",
      },
      confirmation: "Merge all into Cantaloupe, company.",
    });
  });
});
