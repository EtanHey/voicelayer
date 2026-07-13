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
  runSwiftRuntimeInteractionLeg,
  selectCorpusSpecimens,
  signalDetachedProcessGroup,
  terminateVerifyDaemon,
  waitForDetachedProcessGroupExit,
  waitForInteractionRunner,
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
        polished: true,
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
        polished: true,
        polishStatus: "applied",
      }),
    ).toThrow("empty polished output");
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "degenerate",
        reference,
        actual: "1.",
        polished: true,
        polishStatus: "applied",
      }),
    ).toThrow("degenerate polished output");
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "punctuation",
        reference,
        actual: "the runtime verifier checks the isolated daemon socket",
        polished: true,
        polishStatus: "applied",
      }),
    ).toThrow("punctuation floor");
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "mismatch",
        reference,
        actual: "Completely different words appeared in this sentence.",
        polished: true,
        polishStatus: "applied",
      }),
    ).toThrow("reference overlap");
  });

  test("rejects replay output padded with unrelated hallucinated vocabulary", () => {
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "hallucinated-tail",
        reference: "the runtime verifier checks the isolated daemon socket safely",
        actual:
          "The runtime verifier checks unrelated purple elephants while calendars " +
          "negotiate loudly beneath fictional oceans and impossible mountains forever.",
        polished: true,
        polishStatus: "applied",
      }),
    ).toThrow("vocabulary similarity");
  });

  test("requires evidence that polish was applied", () => {
    const base = {
      specimenId: "polish-evidence",
      reference: "the corpus verifier exercised the polish layer",
      actual: "The corpus verifier exercised the polish layer.",
      polished: true,
    };

    expect(() =>
      assertCorpusReplayResult({
        ...base,
        polishStatus: "rejected",
        polishReason: "polish response removed code punctuation",
      }),
    ).toThrow("polish path did not complete");
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

  test("refuses a cleaned fallback that was not actually polished", () => {
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "fallback",
        reference: "the corpus verifier exercised the polish layer",
        actual: "The corpus verifier exercised the polish layer.",
        polished: false,
        polishStatus: "rejected",
        polishReason: "polish response removed protected punctuation",
      }),
    ).toThrow("polished=true");
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
    const privateTmpVoiceBarPath = () =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: "/private/tmp/voicelayer.sock",
        mcpSocketPath: join(workDir, "mcp.sock"),
        workDir,
      });
    if (process.platform === "darwin") {
      expect(privateTmpVoiceBarPath).toThrow("live VoiceBar socket");
    } else {
      expect(privateTmpVoiceBarPath).toThrow("inside the verify work directory");
    }
    expect(() =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: "/tmp/voicelayer-mcp.sock",
        workDir,
      }),
    ).toThrow("live MCP socket");
    const privateTmpMcpPath = () =>
      assertIsolatedVerifyPaths({
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: "/private/tmp/voicelayer-mcp.sock",
        workDir,
      });
    if (process.platform === "darwin") {
      expect(privateTmpMcpPath).toThrow("live MCP socket");
    } else {
      expect(privateTmpMcpPath).toThrow("inside the verify work directory");
    }
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

  test("clears the daemon grace timer after prompt exit", async () => {
    const originalSetTimeout = globalThis.setTimeout;
    const originalClearTimeout = globalThis.clearTimeout;
    let cleared = false;
    globalThis.setTimeout = ((callback: () => void, timeoutMs: number) => {
      expect(timeoutMs).toBe(10_000);
      return 4242;
    }) as typeof setTimeout;
    globalThis.clearTimeout = ((timer: ReturnType<typeof setTimeout>) => {
      expect(timer).toBe(4242);
      cleared = true;
    }) as typeof clearTimeout;
    try {
      await terminateVerifyDaemon({
        exited: Promise.resolve(0),
        kill() {},
      });
    } finally {
      globalThis.setTimeout = originalSetTimeout;
      globalThis.clearTimeout = originalClearTimeout;
    }

    expect(cleared).toBe(true);
  });

  test("signals the detached daemon process group so recorder children are terminated", () => {
    const groupSignals: Array<[number, string]> = [];
    const directSignals: string[] = [];
    signalDetachedProcessGroup(
      {
        pid: 4242,
        kill(signal) {
          directSignals.push(signal);
        },
      },
      "SIGTERM",
      (pid, signal) => {
        groupSignals.push([pid, signal]);
        return true;
      },
    );

    expect(groupSignals).toEqual([[-4242, "SIGTERM"]]);
    expect(directSignals).toEqual([]);
  });

  test("bounds the wait for a detached process group to disappear", async () => {
    let checks = 0;
    await expect(
      waitForDetachedProcessGroupExit(
        {
          pid: 4242,
          exited: Promise.resolve(137),
          kill() {},
        },
        10,
        () => {
          checks++;
          return checks < 4;
        },
      ),
    ).rejects.toThrow("process group 4242 still present after 10ms");
  });

  test("times out and terminates a hung Swift interaction runner", async () => {
    const signals: string[] = [];
    let resolveExit!: (code: number) => void;
    const exited = new Promise<number>((resolve) => {
      resolveExit = resolve;
    });

    await expect(
      waitForInteractionRunner(
        {
          exited,
          kill(signal) {
            signals.push(signal);
            resolveExit(143);
          },
        },
        1,
      ),
    ).rejects.toThrow("timed out");
    expect(signals).toEqual(["SIGTERM"]);
  });

  test("terminates the interaction process group when its exit watcher rejects", async () => {
    const signals: string[] = [];
    const watcherError = new Error("process group remained alive");
    let releaseGracePeriod!: () => void;
    const gracePeriod = new Promise<void>((resolve) => {
      releaseGracePeriod = resolve;
    });

    const result = waitForInteractionRunner(
      {
        exited: Promise.reject(watcherError),
        kill(signal) {
          signals.push(signal);
        },
      },
      1_000,
      () => gracePeriod,
    );
    await Bun.sleep(0);
    expect(signals).toEqual(["SIGTERM"]);

    releaseGracePeriod();
    await expect(result).rejects.toBe(watcherError);
    expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
  });

  test("interaction timeout terminates the runner's full process group", async () => {
    const root = makeTempRoot();
    const workDir = join(root, "verify-work");
    const runner = join(root, "interaction-runner.ts");
    const childPidPath = join(root, "interaction-child.pid");
    mkdirSync(workDir, { recursive: true });
    writeFileSync(
      runner,
      [
        "#!/usr/bin/env bun",
        'import { writeFileSync } from "fs";',
        'const child = Bun.spawn(["/bin/sh", "-c", \'trap "" TERM; exec /bin/sleep 300\'], {',
        '  stdin: "ignore",',
        '  stdout: "ignore",',
        '  stderr: "ignore",',
        "});",
        'writeFileSync(process.env.VERIFY_CHILD_PID!, String(child.pid));',
        "await child.exited;",
        "",
      ].join("\n"),
      { mode: 0o755 },
    );
    const previousRunner = process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER;
    const previousTimeout = process.env.VOICELAYER_VERIFY_INTERACTION_TIMEOUT_MS;
    const previousGrace =
      process.env.VOICELAYER_VERIFY_INTERACTION_TERMINATION_GRACE_MS;
    const previousChildPidPath = process.env.VERIFY_CHILD_PID;
    process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER = runner;
    process.env.VOICELAYER_VERIFY_INTERACTION_TIMEOUT_MS = "1000";
    process.env.VOICELAYER_VERIFY_INTERACTION_TERMINATION_GRACE_MS = "100";
    process.env.VERIFY_CHILD_PID = childPidPath;
    let childPid = 0;
    let childSurvived = false;
    try {
      await expect(
        runSwiftRuntimeInteractionLeg({
          repoRoot: root,
          workDir,
          voiceBarSocketPath: join(workDir, "voicebar.sock"),
          audioFixture: join(workDir, "audio.wav"),
        }),
      ).rejects.toThrow("runtime interaction leg timed out after 1000ms");
      childPid = Number((await Bun.file(childPidPath).text()).trim());
      const deadline = Date.now() + 1000;
      do {
        try {
          process.kill(childPid, 0);
          childSurvived = true;
        } catch {
          childSurvived = false;
        }
        if (childSurvived) await Bun.sleep(25);
      } while (childSurvived && Date.now() < deadline);
    } finally {
      if (childSurvived && childPid > 1) {
        try {
          process.kill(childPid, "SIGKILL");
        } catch {}
      }
      if (previousRunner === undefined) {
        delete process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER;
      } else {
        process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER = previousRunner;
      }
      if (previousTimeout === undefined) {
        delete process.env.VOICELAYER_VERIFY_INTERACTION_TIMEOUT_MS;
      } else {
        process.env.VOICELAYER_VERIFY_INTERACTION_TIMEOUT_MS = previousTimeout;
      }
      if (previousGrace === undefined) {
        delete process.env.VOICELAYER_VERIFY_INTERACTION_TERMINATION_GRACE_MS;
      } else {
        process.env.VOICELAYER_VERIFY_INTERACTION_TERMINATION_GRACE_MS = previousGrace;
      }
      if (previousChildPidPath === undefined) {
        delete process.env.VERIFY_CHILD_PID;
      } else {
        process.env.VERIFY_CHILD_PID = previousChildPidPath;
      }
    }

    expect(childPid).toBeGreaterThan(1);
    expect(childSurvived).toBe(false);
  });

  test("production Swift handoff propagates the isolated runtime environment", async () => {
    const root = makeTempRoot();
    const workDir = join(root, "verify-work");
    const runner = join(root, "interaction-runner.sh");
    const receipt = join(root, "interaction-env.txt");
    mkdirSync(workDir, { recursive: true });
    writeFileSync(
      runner,
      [
        "#!/bin/sh",
        "set -eu",
        ': "${CORPUS_RUNNER_ACTIVE:?}"',
        ': "${VOICELAYER_VERIFY_WORK_DIR:?}"',
        ': "${VOICELAYER_VERIFY_VOICEBAR_SOCKET_PATH:?}"',
        ': "${VOICELAYER_VERIFY_AUDIO_FIXTURE:?}"',
        'printf "%s\\n%s\\n%s\\n" "$VOICELAYER_VERIFY_WORK_DIR" "$VOICELAYER_VERIFY_VOICEBAR_SOCKET_PATH" "$VOICELAYER_VERIFY_AUDIO_FIXTURE" > "$VERIFY_RECEIPT"',
        "",
      ].join("\n"),
      { mode: 0o755 },
    );
    const previousRunner = process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER;
    const previousReceipt = process.env.VERIFY_RECEIPT;
    process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER = runner;
    process.env.VERIFY_RECEIPT = receipt;
    try {
      await runSwiftRuntimeInteractionLeg({
        repoRoot: root,
        workDir,
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        audioFixture: join(workDir, "audio.wav"),
      });
    } finally {
      if (previousRunner === undefined) {
        delete process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER;
      } else {
        process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER = previousRunner;
      }
      if (previousReceipt === undefined) delete process.env.VERIFY_RECEIPT;
      else process.env.VERIFY_RECEIPT = previousReceipt;
    }

    expect(await Bun.file(receipt).text()).toBe(
      `${workDir}\n${join(workDir, "voicebar.sock")}\n${join(workDir, "audio.wav")}\n`,
    );
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
