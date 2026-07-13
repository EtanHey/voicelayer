import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  assertCorpusReplayResult,
  assertIsolatedVerifyPaths,
  selectCorpusSpecimens,
  terminateVerifyDaemon,
  runDaemonInteractionLeg,
} from "../corpus-replay-verify";

const tempRoots: string[] = [];

function makeTempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "voicelayer-corpus-verify-test-"));
  tempRoots.push(root);
  return root;
}

function writeSpecimen(
  root: string,
  day: string,
  id: string,
  transcript: string,
  durationMs = 2_000,
) {
  const directory = join(root, day, id);
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "audio.wav"), "RIFF-test-audio");
  writeFileSync(
    join(directory, "metadata.json"),
    JSON.stringify({ id, duration_ms: durationMs, sample_rate: 16_000 }),
  );
  writeFileSync(join(directory, "voicelayer-transcript.txt"), transcript);
}

afterEach(() => {
  while (tempRoots.length > 0) {
    rmSync(tempRoots.pop()!, { recursive: true, force: true });
  }
});

describe("corpus replay verification", () => {
  test("accepts a polished transcript with punctuation and meaningful reference overlap", () => {
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "sample-1",
        reference: "why did it do that i am confused",
        actual: "Why did it do that? I am confused.",
        polishStatus: "applied",
      }),
    ).not.toThrow();
  });

  test("rejects empty, degenerate, unpunctuated, and unrelated replay output", () => {
    const reference = "the runtime verifier checks the isolated daemon socket";

    expect(() =>
      assertCorpusReplayResult({
        specimenId: "empty",
        reference,
        actual: "",
        polishStatus: "applied",
      }),
    ).toThrow("empty polished output");
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "degenerate",
        reference,
        actual: "1.",
        polishStatus: "applied",
      }),
    ).toThrow("degenerate polished output");
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "punctuation",
        reference,
        actual: "the runtime verifier checks the isolated daemon socket",
        polishStatus: "applied",
      }),
    ).toThrow("punctuation floor");
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "mismatch",
        reference,
        actual: "Completely different words appeared in this sentence.",
        polishStatus: "applied",
      }),
    ).toThrow("reference overlap");
  });

  test("requires evidence that polish ran while allowing safety-rejected rewrites", () => {
    const base = {
      specimenId: "polish-evidence",
      reference: "the corpus verifier exercised the polish layer",
      actual: "The corpus verifier exercised the polish layer.",
    };

    expect(() =>
      assertCorpusReplayResult({
        ...base,
        polishStatus: "rejected",
        polishReason: "polish response removed code punctuation",
      }),
    ).not.toThrow();
    expect(() =>
      assertCorpusReplayResult({
        ...base,
        polishStatus: "rejected",
        polishReason: "empty polish response",
      }),
    ).toThrow("empty polish candidate");
    expect(() => assertCorpusReplayResult({ ...base, polishStatus: "failed" })).toThrow(
      "polish path did not complete",
    );
    expect(() => assertCorpusReplayResult({ ...base, polishStatus: "unavailable" })).toThrow(
      "polish path did not complete",
    );
    expect(() => assertCorpusReplayResult({ ...base, polishStatus: "" })).toThrow(
      "polish path did not complete",
    );
  });

  test("selects the newest deterministic valid specimens and skips unusable recordings", () => {
    const root = makeTempRoot();
    writeSpecimen(root, "2026-07-11", "2026-07-11T09-00-00Z-old", "Old enough transcript.");
    writeSpecimen(root, "2026-07-12", "2026-07-12T09-00-00Z-short", "No.", 200);
    writeSpecimen(
      root,
      "2026-07-12",
      "2026-07-12T10-00-00Z-middle",
      "This is the middle transcript.",
    );
    writeSpecimen(
      root,
      "2026-07-13",
      "2026-07-13T11-00-00Z-new",
      "This is the newest transcript.",
    );

    const selected = selectCorpusSpecimens(root, 2);

    expect(selected.map((item) => item.id)).toEqual([
      "2026-07-13T11-00-00Z-new",
      "2026-07-12T10-00-00Z-middle",
    ]);
  });

  test("requires a fully isolated socket pair and refuses either live default", () => {
    const workDir = makeTempRoot();
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: join(workDir, "mcp.sock"),
        workDir,
      }),
    ).not.toThrow();

    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: "/tmp/voicelayer.sock",
        mcpSocketPath: join(workDir, "mcp.sock"),
        workDir,
      }),
    ).toThrow("live VoiceBar socket");
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: "/private/tmp/voicelayer.sock",
        mcpSocketPath: join(workDir, "mcp.sock"),
        workDir,
      }),
    ).toThrow("live VoiceBar socket");
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: "/tmp/voicelayer-mcp.sock",
        workDir,
      }),
    ).toThrow("live MCP socket");
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: "/private/tmp/voicelayer-mcp.sock",
        workDir,
      }),
    ).toThrow("live MCP socket");
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "shared.sock"),
        mcpSocketPath: join(workDir, "shared.sock"),
        workDir,
      }),
    ).toThrow("must be distinct");
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: join(workDir, "..", "escaped.sock"),
        workDir,
      }),
    ).toThrow("inside the verify work directory");
  });

  test("escalates isolated daemon teardown to SIGKILL after the grace period", async () => {
    const signals: string[] = [];
    let resolveExit!: (code: number) => void;
    const exited = new Promise<number>((resolve) => {
      resolveExit = resolve;
    });

    await terminateVerifyDaemon(
      {
        exited,
        kill(signal) {
          signals.push(signal);
          if (signal === "SIGKILL") resolveExit(137);
        },
      },
      async () => {},
    );

    expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
  });

  test("drives record/cancel and record/stop transitions on the daemon NDJSON stream", async () => {
    const events: Record<string, unknown>[] = [];
    const commands: Record<string, unknown>[] = [];
    await runDaemonInteractionLeg({
      events,
      send(command) {
        commands.push(command);
        const id = command.id;
        events.push({ type: "ack", id, outcome: "accept" });
        if (command.cmd === "record") {
          events.push({ type: "state", state: "recording", source: "recording" });
        } else {
          events.push({ type: "state", state: "idle", source: "recording" });
        }
      },
    });

    expect(commands.map((command) => command.cmd)).toEqual([
      "record",
      "cancel",
      "record",
      "stop",
    ]);
    expect(commands.filter((command) => command.cmd === "record")).toEqual([
      expect.objectContaining({ press_to_talk: true }),
      expect.objectContaining({ press_to_talk: true }),
    ]);
  });
});
