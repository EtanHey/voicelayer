import { afterEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  assertCorpusReplayResult,
  assertIsolatedVerifyPaths,
  buildCorpusDaemonEnvironment,
  readCorpusManifest,
  repoRootFromModuleUrl,
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

function linuxProcessStatIsRunning(stat: string): boolean {
  const commandEnd = stat.lastIndexOf(")");
  if (commandEnd < 0) return true;
  const state = stat.slice(commandEnd + 2).split(/\s/u, 1)[0];
  return state !== "Z" && state !== "X" && state !== "x";
}

function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  if (process.platform !== "linux") return true;
  try {
    return linuxProcessStatIsRunning(readFileSync(`/proc/${pid}/stat`, "utf8"));
  } catch {
    return false;
  }
}

function writeSpecimen(
  root: string,
  day: string,
  id: string,
  transcript: string,
  durationMs = 2_000,
  source: "voicebar" | "voice_ask" = "voicebar",
) {
  const directory = join(root, day, id);
  mkdirSync(directory, { recursive: true });
  writeFileSync(join(directory, "audio.wav"), "RIFF-test-audio");
  writeFileSync(
    join(directory, "metadata.json"),
    JSON.stringify({ id, duration_ms: durationMs, sample_rate: 16_000, source }),
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

  test("accepts handled polish outcomes and rejects broken pipeline statuses", () => {
    const base = {
      specimenId: "polish-evidence",
      reference: "the corpus verifier exercised the polish layer",
      actual: "The corpus verifier exercised the polish layer.",
      polished: false,
    };

    for (const polishStatus of ["rejected", "shadowed", "skipped"]) {
      expect(() =>
        assertCorpusReplayResult({
          ...base,
          polishStatus,
          polishReason: "protected-token guard preserved the fallback",
        }),
      ).not.toThrow();
    }
    expect(() =>
      assertCorpusReplayResult({ ...base, polishStatus: "applied" }),
    ).toThrow("polished=true");
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

  test("accepts a non-degenerate cleaned fallback rejected by a safety guard", () => {
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "fallback",
        reference: "the corpus verifier exercised the polish layer",
        actual: "The corpus verifier exercised the polish layer.",
        polished: false,
        polishStatus: "rejected",
        polishReason: "polish response removed protected punctuation",
      }),
    ).not.toThrow();
  });

  test("rejects a long unpunctuated fallback rejected by a safety guard", () => {
    const reference =
      "so i was thinking about the whole voice layer pipeline and how the polish " +
      "step is supposed to add punctuation but sometimes it just does not and then " +
      "you end up with this giant wall of text that has no periods no commas nothing " +
      "and it is really hard to read especially when the dictation is long like this " +
      "one where i just keep talking and talking without ever stopping to breathe or " +
      "add any kind of structure to what i am saying which is exactly the failure mode";

    expect(() =>
      assertCorpusReplayResult({
        specimenId: "punct-flicker-long-narrative",
        reference,
        actual: reference,
        polished: false,
        polishStatus: "rejected",
        polishReason: "polish response self-correction introduced new content",
      }),
    ).toThrow("punctuation floor");
  });

  test("rejects an unrelated fallback even when the polish outcome was handled", () => {
    expect(() =>
      assertCorpusReplayResult({
        specimenId: "unrelated-fallback",
        reference: "the corpus verifier exercised the polish layer",
        actual: "Completely unrelated words from another recording.",
        polished: false,
        polishStatus: "rejected",
        polishReason: "protected-token guard preserved the fallback",
      }),
    ).toThrow("reference overlap");
  });

  test("rejects empty or degenerate output for every handled polish outcome", () => {
    for (const actual of ["", "1.", "1)"]) {
      expect(() =>
        assertCorpusReplayResult({
          specimenId: "broken-output",
          reference: "the corpus verifier exercised the polish layer",
          actual,
          polished: false,
          polishStatus: "rejected",
        }),
      ).toThrow(/empty|degenerate/);
    }
  });

  test("selects a pinned corpus manifest in declared order and skips moving newest entries", () => {
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
    writeSpecimen(
      root,
      "2026-07-14",
      "2026-07-14T11-00-00Z-later",
      "This later recording must not change the pinned selection.",
    );

    const selected = selectCorpusSpecimens(root, 2, [
      "2026-07-12T10-00-00Z-middle",
      "2026-07-13T11-00-00Z-new",
    ]);

    expect(selected.map((item) => item.id)).toEqual([
      "2026-07-12T10-00-00Z-middle",
      "2026-07-13T11-00-00Z-new",
    ]);
    expect(() =>
      selectCorpusSpecimens(root, 2, [
        "2026-07-12T10-00-00Z-middle",
        "missing-pinned-recording",
      ]),
    ).toThrow("missing-pinned-recording");
  });

  test("excludes paired voice_ask rounds from the VoiceBar corpus", () => {
    const root = makeTempRoot();
    writeSpecimen(
      root,
      "2026-07-13",
      "voicebar-round",
      "This VoiceBar recording remains eligible.",
    );
    writeSpecimen(
      root,
      "2026-07-14",
      "voice-ask-round",
      "This newer voice ask reply must not enter the corpus.",
      2_000,
      "voice_ask",
    );

    expect(selectCorpusSpecimens(root, 1).map((item) => item.id)).toEqual([
      "voicebar-round",
    ]);
  });

  test("reads a documented corpus manifest and rejects duplicate ids", () => {
    const root = makeTempRoot();
    const manifest = join(root, "corpus-manifest.txt");
    writeFileSync(manifest, "# frozen set\nfirst-id\n\nsecond-id\n");
    expect(readCorpusManifest(manifest)).toEqual(["first-id", "second-id"]);

    writeFileSync(manifest, "duplicate-id\nduplicate-id\n");
    expect(() => readCorpusManifest(manifest)).toThrow("duplicate specimen ids");
  });

  test("rejects duplicate recording metadata ids instead of selecting by scan order", () => {
    const root = makeTempRoot();
    writeSpecimen(root, "2026-07-12", "duplicate-id", "First duplicate transcript.");
    writeSpecimen(root, "2026-07-13", "other-directory", "Second duplicate transcript.");
    writeFileSync(
      join(root, "2026-07-13", "other-directory", "metadata.json"),
      JSON.stringify({
        id: "duplicate-id",
        duration_ms: 2_000,
        sample_rate: 16_000,
        source: "voicebar",
      }),
    );

    expect(() => selectCorpusSpecimens(root, 1, ["duplicate-id"])).toThrow(
      "duplicate specimen ids",
    );
  });

  test("decodes percent-escaped characters in the default repository path", () => {
    expect(
      repoRootFromModuleUrl("file:///tmp/Voice%20Layer/src/corpus-replay-verify.ts"),
    ).toBe("/tmp/Voice Layer");
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

  test("isolates corpus daemon journal and polish writes inside the verify work directory", () => {
    const workDir = makeTempRoot();
    const environment = buildCorpusDaemonEnvironment({
      workDir,
      voiceBarSocketPath: join(workDir, "voicebar.sock"),
      mcpSocketPath: join(workDir, "mcp.sock"),
      stagedRoot: join(workDir, "recordings"),
      audioFixture: join(workDir, "audio.wav"),
      recorderBinDirectory: join(workDir, "bin"),
      baseEnvironment: {
        HOME: "/real/user/home",
        PATH: "/usr/bin:/bin",
        VOICELAYER_CONTROL_LAYER_BASE: "/real/user/journal",
        QA_VOICE_STT_POLISH_LOG_PATH: "/real/user/polish-shadow.jsonl",
      },
    });

    expect(environment.HOME).toBe("/real/user/home");
    expect(environment.VOICELAYER_CONTROL_LAYER_BASE).toBe(
      join(workDir, "control-layer"),
    );
    expect(environment.QA_VOICE_STT_POLISH_LOG_PATH).toBe(
      join(workDir, "polish-shadow.jsonl"),
    );
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

  test("reaps a TERM-ignoring child when the detached interaction leader exits first", async () => {
    const root = makeTempRoot();
    const runner = join(root, "leader-exits-first.sh");
    const childPidPath = join(root, "leader-child.pid");
    writeFileSync(
      runner,
      [
        "#!/bin/sh",
        "set -eu",
        "nohup /bin/sh -c 'trap \"\" TERM HUP; exec /bin/sleep 300' >/dev/null 2>&1 &",
        'printf "%s" "$!" > "$VERIFY_CHILD_PID"',
        "exit 0",
        "",
      ].join("\n"),
      { mode: 0o755 },
    );
    const leader = Bun.spawn([runner], {
      detached: true,
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
      env: { ...process.env, VERIFY_CHILD_PID: childPidPath },
    });
    const interactionRunner = {
      exited: waitForDetachedProcessGroupExit(leader, 100),
      kill(signal: "SIGTERM" | "SIGKILL") {
        signalDetachedProcessGroup(leader, signal);
      },
    };
    let childPid = 0;
    let childRunning = false;
    try {
      const receiptDeadline = Date.now() + 1_000;
      while (!(await Bun.file(childPidPath).exists()) && Date.now() < receiptDeadline) {
        await Bun.sleep(10);
      }
      childPid = Number((await Bun.file(childPidPath).text()).trim());
      await expect(
        waitForInteractionRunner(interactionRunner, 5_000, () => Bun.sleep(100)),
      ).rejects.toThrow("process group");
      const exitDeadline = Date.now() + 1_000;
      do {
        childRunning = isProcessRunning(childPid);
        if (childRunning) await Bun.sleep(25);
      } while (childRunning && Date.now() < exitDeadline);
    } finally {
      if (childRunning && childPid > 1) {
        try {
          process.kill(childPid, "SIGKILL");
        } catch {}
      }
    }

    expect(childPid).toBeGreaterThan(1);
    expect(childRunning).toBe(false);
  });

  test("treats an unreaped Linux zombie as not running", () => {
    expect(linuxProcessStatIsRunning("4242 (sleep) Z 1 4242 4242 0")).toBe(false);
    expect(linuxProcessStatIsRunning("4242 (sleep) S 1 4242 4242 0")).toBe(true);
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
    let childRunning = false;
    const startedAt = Date.now();
    try {
      await expect(
        runSwiftRuntimeInteractionLeg({
          repoRoot: root,
          workDir,
          voiceBarSocketPath: join(workDir, "voicebar.sock"),
          mcpSocketPath: join(workDir, "mcp.sock"),
          daemonPid: process.pid,
          audioFixture: join(workDir, "audio.wav"),
        }),
      ).rejects.toThrow("runtime interaction leg timed out after 1000ms");
      childPid = Number((await Bun.file(childPidPath).text()).trim());
      const deadline = Date.now() + 1000;
      do {
        childRunning = isProcessRunning(childPid);
        if (childRunning) await Bun.sleep(25);
      } while (childRunning && Date.now() < deadline);
    } finally {
      if (childRunning && childPid > 1) {
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
    expect(childRunning).toBe(false);
    expect(Date.now() - startedAt).toBeLessThan(2_500);
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
        ': "${VOICELAYER_VERIFY_MCP_SOCKET_PATH:?}"',
        ': "${VOICELAYER_VERIFY_DAEMON_PID:?}"',
        ': "${VOICELAYER_VERIFY_AUDIO_FIXTURE:?}"',
        'printf "%s\\n%s\\n%s\\n%s\\n%s\\n" "$VOICELAYER_VERIFY_WORK_DIR" "$VOICELAYER_VERIFY_VOICEBAR_SOCKET_PATH" "$VOICELAYER_VERIFY_MCP_SOCKET_PATH" "$VOICELAYER_VERIFY_DAEMON_PID" "$VOICELAYER_VERIFY_AUDIO_FIXTURE" > "$VERIFY_RECEIPT"',
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
        mcpSocketPath: join(workDir, "mcp.sock"),
        daemonPid: 4242,
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
      `${workDir}\n${join(workDir, "voicebar.sock")}\n${join(workDir, "mcp.sock")}\n4242\n${join(workDir, "audio.wav")}\n`,
    );
  });

  test("does not manufacture terminal proofs when the default runtime runner omits the scenarios", async () => {
    const root = makeTempRoot();
    const workDir = join(root, "verify-work");
    const binDir = join(root, "bin");
    const swiftShim = join(binDir, "swift");
    const normalProof = join(workDir, "f5-finish-paste-terminal.proof");
    const veryLongProof = join(
      workDir,
      "f5-finish-paste-terminal-very-long.proof",
    );
    mkdirSync(workDir, { recursive: true });
    mkdirSync(binDir, { recursive: true });
    writeFileSync(swiftShim, "#!/bin/sh\nexit 0\n", { mode: 0o755 });

    const previous = {
      runner: process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER,
      path: process.env.PATH,
      normalProof: process.env.VOICELAYER_VERIFY_F5_TERMINAL_PROOF_PATH,
      veryLongProof:
        process.env.VOICELAYER_VERIFY_F5_TERMINAL_VERY_LONG_PROOF_PATH,
    };
    delete process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER;
    process.env.PATH = `${binDir}:${previous.path ?? "/usr/bin:/bin"}`;
    process.env.VOICELAYER_VERIFY_F5_TERMINAL_PROOF_PATH = normalProof;
    process.env.VOICELAYER_VERIFY_F5_TERMINAL_VERY_LONG_PROOF_PATH = veryLongProof;

    try {
      await runSwiftRuntimeInteractionLeg({
        repoRoot: root,
        workDir,
        voiceBarSocketPath: join(workDir, "voicebar.sock"),
        mcpSocketPath: join(workDir, "mcp.sock"),
        daemonPid: process.pid,
        audioFixture: join(workDir, "audio.wav"),
      });
    } finally {
      if (previous.runner === undefined) {
        delete process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER;
      } else {
        process.env.VOICELAYER_VERIFY_INTERACTION_RUNNER = previous.runner;
      }
      if (previous.path === undefined) delete process.env.PATH;
      else process.env.PATH = previous.path;
      if (previous.normalProof === undefined) {
        delete process.env.VOICELAYER_VERIFY_F5_TERMINAL_PROOF_PATH;
      } else {
        process.env.VOICELAYER_VERIFY_F5_TERMINAL_PROOF_PATH = previous.normalProof;
      }
      if (previous.veryLongProof === undefined) {
        delete process.env.VOICELAYER_VERIFY_F5_TERMINAL_VERY_LONG_PROOF_PATH;
      } else {
        process.env.VOICELAYER_VERIFY_F5_TERMINAL_VERY_LONG_PROOF_PATH =
          previous.veryLongProof;
      }
    }

    expect(await Bun.file(normalProof).exists()).toBe(false);
    expect(await Bun.file(veryLongProof).exists()).toBe(false);
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
