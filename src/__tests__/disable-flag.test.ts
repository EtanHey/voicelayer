import { DISABLE_POLL_INTERVAL_MS } from "../daemon-disable-poll";
import { withChildFixtureEnv } from "./setup/child-env";
import { testSocket, testTmp } from "./setup/test-tmp";
import { afterEach, beforeEach, expect, it } from "bun:test";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { existsSync, mkdirSync, rmSync, unlinkSync, writeFileSync } from "fs";

// Real subprocesses: standalone p95 <= 51 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;
const STARTUP_BUDGET_MS = 10_000;
const SHUTDOWN_BUDGET_MS = 5_000;
// One full poll plus a scheduling poll and graceful shutdown, separate from startup.
const FLAG_EXIT_BUDGET_MS = 2 * DISABLE_POLL_INTERVAL_MS + SHUTDOWN_BUDGET_MS;
const FLAG_TEST_BUDGET_MS = STARTUP_BUDGET_MS + FLAG_EXIT_BUDGET_MS + SHUTDOWN_BUDGET_MS;

const TEST_DIR = testTmp("disable");
const TEST_MCP_SOCKET_PATH = testSocket("df.sock");
const TEST_MCP_PID_PATH = `${TEST_DIR}/voicelayer-mcp.pid`;
const TEST_DISABLE_FLAG_PATH = `${TEST_DIR}/voice-disabled.flag`;

function cleanup(): void {
  try {
    unlinkSync(TEST_MCP_SOCKET_PATH);
  } catch {}
  try {
    unlinkSync(TEST_DISABLE_FLAG_PATH);
  } catch {}
  try {
    unlinkSync(TEST_MCP_PID_PATH);
  } catch {}
  try {
    rmSync(TEST_DIR, { recursive: true, force: true });
  } catch {}
}

async function waitForFile(path: string, timeoutMs: number): Promise<boolean> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (existsSync(path)) return true;
    await Bun.sleep(50);
  }
  return existsSync(path);
}

function spawnDaemon(extraEnv: Record<string, string | undefined> = {}) {
  mkdirSync(TEST_DIR, { recursive: true });

  const env = {
    ...process.env,
    VOICELAYER_MCP_SOCKET_PATH: TEST_MCP_SOCKET_PATH,
    QA_VOICE_MCP_PID_PATH: TEST_MCP_PID_PATH,
  };
  return withChildFixtureEnv(env, () => Bun.spawn(["bun", "run", "src/mcp-server-daemon.ts"], {
    cwd: process.cwd(),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      // AIDEV-NOTE: R-014 — the child inherits this process's env, and the test
      // preload sets the CANONICAL VOICELAYER_* names, which win over the legacy
      // QA_VOICE_* aliases in src/paths.ts. Set both, or the daemon listens on
      // the preload's socket instead of this suite's and the waits time out.
      // VOICELAYER_SOCKET_PATH is deliberately left inherited: it keeps the
      // child off the resident VoiceBar at /tmp/voicelayer.sock.
      VOICELAYER_MCP_SOCKET_PATH: TEST_MCP_SOCKET_PATH,
      QA_VOICE_MCP_SOCKET_PATH: TEST_MCP_SOCKET_PATH,
      QA_VOICE_MCP_PID_PATH: TEST_MCP_PID_PATH,
      QA_VOICE_DISABLE_FLAG_PATH: TEST_DISABLE_FLAG_PATH,
      // These tests exercise the disable flag, not the sole-owner guard; opt
      // out of orphan enforcement so they don't depend on an incidental live
      // parent PID.
      VOICELAYER_ALLOW_ORPHAN_DAEMON: "1",
      ...extraEnv,
    },
  }));
}

describe("DISABLE_VOICELAYER env", () => {
  beforeEach(() => {
    cleanup();
  });

  afterEach(() => {
    cleanup();
  });

  it("daemon main() exits 0 when env set", async () => {
    const daemon = spawnDaemon({
      DISABLE_VOICELAYER: "1",
    });

    const exitCode = await Promise.race([
      daemon.exited,
      Bun.sleep(2000).then(() => null),
    ]);

    if (exitCode === null) {
      daemon.kill();
      await daemon.exited;
    }

    expect(exitCode).toBe(0);
    expect(existsSync(TEST_MCP_SOCKET_PATH)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  it("isVoicelayerDisabled returns true for env or flag file", async () => {
    const pathsModule = (await import("../paths")) as {
      isVoicelayerDisabled?: (options?: {
        env?: NodeJS.ProcessEnv;
        flagFilePath?: string;
      }) => boolean;
    };

    expect(
      pathsModule.isVoicelayerDisabled?.({
        env: { DISABLE_VOICELAYER: "1" } as NodeJS.ProcessEnv,
        flagFilePath: TEST_DISABLE_FLAG_PATH,
      }),
    ).toBe(true);

    mkdirSync(TEST_DIR, { recursive: true });
    writeFileSync(TEST_DISABLE_FLAG_PATH, "disabled");

    expect(
      pathsModule.isVoicelayerDisabled?.({
        env: {} as NodeJS.ProcessEnv,
        flagFilePath: TEST_DISABLE_FLAG_PATH,
      }),
    ).toBe(true);

    expect(
      pathsModule.isVoicelayerDisabled?.({
        env: {} as NodeJS.ProcessEnv,
        flagFilePath: `${TEST_DISABLE_FLAG_PATH}.missing`,
      }),
    ).toBe(false);
  });

  it(
    "running daemon self-terminates when flag file appears",
    { timeout: FLAG_TEST_BUDGET_MS },
    async () => {
      const daemon = spawnDaemon();

      const output = new Response(daemon.stdout).text();
      const errors = new Response(daemon.stderr).text();
      try {
        expect(await Promise.all([
          waitForFile(TEST_MCP_SOCKET_PATH, STARTUP_BUDGET_MS),
          waitForFile(TEST_MCP_PID_PATH, STARTUP_BUDGET_MS),
        ])).toEqual([true, true]);
        writeFileSync(TEST_DISABLE_FLAG_PATH, "disabled");
        const exitCode = await Promise.race([
          daemon.exited,
          Bun.sleep(FLAG_EXIT_BUDGET_MS).then(() => null),
        ]);
        expect(exitCode).toBe(0);
        expect(existsSync(TEST_MCP_SOCKET_PATH)).toBe(false);
        expect(existsSync(TEST_MCP_PID_PATH)).toBe(false);
      } finally {
        if (daemon.exitCode === null) daemon.kill();
        await daemon.exited;
        await Promise.all([output, errors]);
      }
    },
  );
});
