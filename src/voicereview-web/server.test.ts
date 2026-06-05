import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import {
  appendSessionRule,
  buildClusterAwareWhisperPrompt,
  buildConverseMessages,
  buildConfirmation,
  buildDriverArgs,
  buildEvidenceArgs,
  buildInterpretMessages,
  buildJudgeReflectBack,
  buildWhisperArgs,
  buildWhisperPrompt,
  createVoiceReviewApp,
  decorateStatsWithSkippedCounts,
  decisionLockPath,
  DEFAULT_CONFIG,
  extractSessionRule,
  loadJudgeVerdicts,
  legacyDecisionsToKgFlagV1,
  parseInterpretDecision,
  type ConversationEvidence,
  type CommandCall,
  type CommandResult,
  type JudgeVerdict,
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

const cantaloupeVerdict: JudgeVerdict = {
  stem: "cantaloupe",
  proposed_type: "Project",
  identity:
    "Cantaloupe AI — employment/client project at defunct Cantaloupe Technologies Corp (AI hiring platform Etan worked on); not a person.",
  merge_disposition: "merge",
  canonical_suggestion: "Cantaloupe",
  confidence: "high",
  evidence_cited: [
    "Etan correction: project by dead/renamed company, NOT a person",
  ],
  reasoning:
    "Etan's explicit correction and worked_at edges anchor this to his employment deliverable.",
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
        judgeVerdictsPath: join(tmpdir(), "missing-worker*.json"),
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
      session_context: {
        decisions_loaded: false,
        judge_verdicts: 0,
        judge_reports: 0,
      },
    });
    expect(calls).toHaveLength(1);
    expect(calls[0].args).toContain("--category");
    expect(calls[0].env.PYTHONPATH).toBe("/tmp/voice-review-wt/src");
    expect(calls[0].cwd).toBe("/tmp/voice-review-wt");
  });

  it("loads judge verdicts from configurable worker globs", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-verdicts-test-"));
    try {
      await writeFile(join(root, "worker1.json"), JSON.stringify([cantaloupeVerdict]));
      await writeFile(
        join(root, "worker2.json"),
        JSON.stringify([
          {
            stem: "Agent C",
            proposed_type: "D2",
            identity: "Ephemeral parallel-audit worker label.",
            merge_disposition: "merge",
            canonical_suggestion: "Agent C",
            confidence: "high",
            evidence_cited: [],
            reasoning: "Session-scoped worker slot.",
          },
        ]),
      );

      const verdicts = await loadJudgeVerdicts(join(root, "worker*.json"));

      expect(verdicts).toHaveLength(2);
      expect(verdicts.map((verdict) => verdict.stem).sort()).toEqual([
        "Agent C",
        "cantaloupe",
      ]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("builds a judge reflect-back line from a verdict", () => {
    expect(buildJudgeReflectBack(cantaloupeVerdict)).toBe(
      "The judge concluded: Cantaloupe AI - employment/client project at defunct Cantaloupe Technologies Corp (AI hiring platform Etan worked on); not a person; disposition merge with high confidence - confirm, or correct me.",
    );
  });

  it("serves /api/next with judge reflect-back speech when the cluster has a verdict", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-next-verdict-test-"));
    try {
      await writeFile(join(root, "worker1.json"), JSON.stringify([cantaloupeVerdict]));
      const app = createVoiceReviewApp({
        config: {
          brainlayerWorktree: "/tmp/voice-review-wt",
          batchPath: "/batch.json",
          decisionsPath: join(root, "decisions.json"),
          judgeVerdictsPath: join(root, "worker*.json"),
        },
        runCommand: async () =>
          commandResult({ cluster: cantaloupeCluster, speak: "Cold cluster intro" }),
      });

      const response = await app.fetch(
        new Request("http://localhost/api/next?category=diagnosis-flag"),
      );
      const body = await response.json();

      expect(response.status).toBe(200);
      expect(body.speak).toBe(
        "The judge concluded: Cantaloupe AI - employment/client project at defunct Cantaloupe Technologies Corp (AI hiring platform Etan worked on); not a person; disposition merge with high confidence - confirm, or correct me.",
      );
      expect(body.judge_verdict).toMatchObject({
        stem: "cantaloupe",
        merge_disposition: "merge",
        confidence: "high",
      });
      expect(body.session_context.judge_verdicts).toBe(1);
      expect(body.session_context.decisions_loaded).toBe(false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
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

    expect(html).toContain("function syncControlState()");
    expect(html).toContain("mic.disabled = busy && !ttsPlaying");
    expect(html).toContain("category.disabled = busy || recording");
    expect(html).toContain("const recordingCluster = current");
    expect(html).toContain("processRecording(new Blob(chunks");
    expect(html).toContain("recordingCluster");
    expect(html).toContain('"member_names",');
    expect(html).toContain("cluster: cluster");
    expect(html).toContain("cluster_id: cluster.cluster_id");
    expect(html).toContain("const decided = Math.max(0, total - undecided)");
    expect(html).toContain("const skipped = Number(bucket.skipped || 0)");
    expect(html).toContain("decided + \" decided · \" + skipped + \" skipped\"");
    expect(html).toContain("Tap Retry");
    expect(html).toContain("finally {\n        setBusy(false);");
    expect(html).toContain("addEventListener(\"ended\"");
    expect(html).toContain("conversationHistory");
    expect(html).toContain('interpreted.decision.action === "question"');
    expect(html).toContain('await api("/api/converse"');
    expect(html).toContain("const answer = normalizeConversationAnswer(converse.answer);");
    expect(html).toContain("appendQuestionTurn");
    expect(html).toContain("function normalizeConversationAnswer(answer)");
    expect(html).toContain("return value || \"I don't see evidence about that\";");
    expect(html).toContain("await playText(answer);");
    expect(html).not.toContain("await playText(converse.answer);");
    expect(html).toContain("await startRecordingForCluster(cluster, { autoListen: true });");
    expect(html).toContain('!(recorder && recorder.state === "recording")');
    expect(html).toContain("evidence_ms");
  });

  it("serves page logic that barge-in stops TTS before recording", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain("let ttsPlaying = false;");
    expect(html).toContain("let activePlayback = null;");
    expect(html).toContain("function stopTtsPlayback()");
    expect(html).toContain("audio.pause();");
    expect(html).toContain("audio.removeAttribute(\"src\");");
    expect(html).toContain("audio.load();");
    expect(html).toContain("setTtsPlaying(false);");
    expect(html).toContain("if (ttsPlaying) {");
    expect(html).toContain("stopTtsPlayback();");
    expect(html).toContain("setBusy(false);");
    expect(html).toContain("await startRecording();");
  });

  it("serves page logic that suppresses recording during confirmation TTS after a decision is saved", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain("async function playText(text, options = {})");
    expect(html).toContain("allowBargeInRecording: options.allowBargeInRecording !== false");
    expect(html).toContain("const allowRecording = activePlayback?.allowBargeInRecording !== false;");
    expect(html).toContain("if (!allowRecording) {");
    expect(html).toContain("Decision saved. Loading next cluster...");
    expect(html).toContain("await playText(interpreted.confirmation, { allowBargeInRecording: false });");

    const decideIndex = html.indexOf('await api("/api/decide"');
    const confirmationIndex = html.indexOf(
      "await playText(interpreted.confirmation, { allowBargeInRecording: false });",
    );
    const loadNextIndex = html.indexOf("await loadNext(true);", confirmationIndex);
    const guardIndex = html.indexOf("if (!allowRecording) {");
    const staleStartIndex = html.indexOf("await startRecording();", guardIndex);
    const suppressedReturnIndex = html.indexOf("return;", guardIndex);

    expect(decideIndex).toBeGreaterThan(-1);
    expect(confirmationIndex).toBeGreaterThan(decideIndex);
    expect(loadNextIndex).toBeGreaterThan(confirmationIndex);
    expect(guardIndex).toBeGreaterThan(-1);
    expect(suppressedReturnIndex).toBeLessThan(staleStartIndex);
  });

  it("serves page logic that caps conversational auto-listen and keeps the mic state obvious", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    expect(html).toContain("const AUTO_LISTEN_MS = 15000;");
    expect(html).toContain(".mic.auto-listening");
    expect(html).toContain("@keyframes autoListenPulse");
    expect(html).toContain("Listening — ask more or say your decision.");
    expect(html).toContain('mic.textContent = "Listening";');
    expect(html).toContain("setTimeout(() => {");
    expect(html).toContain("recordingContext.timedOut = true;");
    expect(html).toContain("Didn't catch that — tap to talk.");
    expect(html).toContain("await startRecordingForCluster(cluster, { autoListen: true });");
    expect(html).toContain("Answering: \" + compactText(question)");
    expect(html).toContain("say merge / keep / mixed / skip to decide");
    expect(html).toContain("qa-evidence-label");
  });

  it("serves page logic that saves the decision before speaking confirmation", async () => {
    const app = createVoiceReviewApp();
    const response = await app.fetch(new Request("http://localhost/"));
    const html = await response.text();

    const saveIndex = html.indexOf("setStatus(\"Recording decision...\");");
    const confirmationIndex = html.indexOf(
      "await playText(interpreted.confirmation, { allowBargeInRecording: false });",
    );
    expect(saveIndex).toBeGreaterThan(-1);
    expect(confirmationIndex).toBeGreaterThan(-1);
    expect(saveIndex).toBeLessThan(confirmationIndex);
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
          headers: { "content-type": "audio/webm" },
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

  it("builds a bounded whisper prompt from vocabulary prompt terms", () => {
    const prompt = buildWhisperPrompt(
      ["BrainLayer", "Cantaloupe AI", "VoiceLayer", "one two three four five"],
      5,
    );

    expect(prompt).toBe("BrainLayer Cantaloupe AI VoiceLayer");
    expect(prompt.split(/\s+/)).toHaveLength(4);
  });

  it("builds a cluster-aware whisper prompt with member names ahead of generic terms under budget", () => {
    const prompt = buildClusterAwareWhisperPrompt({
      clusterMemberNames: ["Caneloop Candidate", "Cantaloupe AI"],
      vocabularyTerms: ["BrainLayer", "VoiceLayer", "one two three"],
      maxTokens: 5,
    });

    expect(prompt).toBe("Caneloop Candidate Cantaloupe AI BrainLayer");
  });

  it("passes current cluster member names to whisper before generic vocabulary", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-transcribe-prompt-test-"));
    const calls: CommandCall[] = [];
    const app = createVoiceReviewApp({
      config: {
        tempDir: root,
        sttVocabularyPath: join(root, "vocab.json"),
        ffmpegPath: "/test/bin/ffmpeg",
        whisperCliPath: "/test/bin/whisper-cli",
      },
      runCommand: async (call) => {
        calls.push(call);
        return {
          exitCode: 0,
          stdout: call.args[0].includes("whisper-cli") ? "Cantaloupe AI\n" : "",
          stderr: "",
          durationMs: 12,
        };
      },
    });

    try {
      await writeFile(
        join(root, "vocab.json"),
        JSON.stringify({ prompt_terms: ["BrainLayer", "VoiceLayer"] }),
      );
      const form = new FormData();
      form.append("audio", new Blob(["not real audio"], { type: "audio/webm" }), "clip.webm");
      form.append("cluster_id", cantaloupeCluster.cluster_id);
      form.append(
        "member_names",
        JSON.stringify(["Caneloop Candidate", "Cantaloupe AI"]),
      );

      const response = await app.fetch(
        new Request("http://localhost/api/transcribe", {
          method: "POST",
          body: form,
        }),
      );

      expect(response.status).toBe(200);
      const whisperCall = calls.find((call) => call.args[0].includes("whisper-cli"));
      expect(whisperCall).toBeDefined();
      const prompt =
        whisperCall!.args[whisperCall!.args.indexOf("--prompt") + 1];
      expect(prompt.startsWith("Caneloop Candidate Cantaloupe AI BrainLayer")).toBe(
        true,
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
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
    });

    expect(args).toEqual([
      "python3",
      "/repo/src/voicereview-web/kg_evidence.py",
      "--db",
      "/tmp/fixture.db",
      "--members-json",
      JSON.stringify(cantaloupeCluster.members),
      "--per-member",
      "2",
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
    expect(messages[0].content).toContain("Reflect your updated understanding in one short sentence");
    expect(messages[0].content).toContain("Ask 1-3 targeted questions max");
    expect(messages[0].content).toContain("confirm or correct");
    expect(messages[1].content).toContain("diagnosis-flag:cantaloupe");
    expect(messages[1].content).toContain("Cantaloupe (company, 13 chunks)");
    expect(messages[1].content).toContain("chunk-company");
    expect(messages[1].content).toContain("company context");
    expect(messages[1].content).toContain("what is the difference?");
    expect(messages[1].content).toContain("which chunks does the company one have?");
  });

  it("extracts general entity-review rules without treating plain decisions as rules", () => {
    expect(
      extractSessionRule(
        "Anything ending in -Codex is an agent, so merge these.",
        cantaloupeCluster,
      ),
    ).toEqual({
      kind: "rule",
      statement: "Anything ending in -Codex is an agent.",
      examples: ["-Codex"],
    });

    expect(extractSessionRule("merge these into the company one", cantaloupeCluster)).toBe(
      null,
    );
  });

  it("extracts vocabulary correction rules and appends them to the session rules log", async () => {
    const root = await mkdtemp(join(tmpdir(), "voicereview-rules-test-"));
    const logPath = join(root, "kg-review-rules-2026-06-05.jsonl");
    try {
      const rule = extractSessionRule("Not Caneloop, Cantaloupe.", cantaloupeCluster);
      expect(rule).toEqual({
        kind: "rule",
        statement: "Vocabulary correction: Caneloop means Cantaloupe.",
        examples: ["Caneloop", "Cantaloupe"],
        vocabulary_correction: {
          misheard: "Caneloop",
          intended: "Cantaloupe",
        },
      });

      await appendSessionRule(rule!, logPath, {
        endpoint: "interpret",
        cluster: cantaloupeCluster,
        sourceText: "Not Caneloop, Cantaloupe.",
      });

      const lines = (await readFile(logPath, "utf8")).trim().split("\n");
      expect(lines).toHaveLength(1);
      expect(JSON.parse(lines[0])).toMatchObject({
        kind: "rule",
        statement: "Vocabulary correction: Caneloop means Cantaloupe.",
        examples: ["Caneloop", "Cantaloupe"],
        source_endpoint: "interpret",
        cluster_id: cantaloupeCluster.cluster_id,
        vocabulary_status: "d1_vocab_store_unavailable",
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
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
                    "The company member has one shown snippet about the hiring manager liking the candidate story. I don't see more evidence than that in the provided snippets.",
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
    expect(calls[0].args).toContain("--db");
    expect(calls[0].args).toContain("/tmp/fixture.db");
    expect(requestedBody.model).toBe("gemma4-e4b,gpu");
    expect(requestedBody.messages[1].content).toContain("chunk-company");
    expect(body).toMatchObject({
      answer:
        "The company member has one shown snippet about the hiring manager liking the candidate story. I don't see more evidence than that in the provided snippets.",
      evidence,
      timings: { evidence_ms: 7 },
    });
    expect(body.timings.llm_ms).toBeGreaterThanOrEqual(0);
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
