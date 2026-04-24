import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  existsSync,
  mkdirSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "fs";

const TEST_DIR = `/tmp/voicelayer-disable-flag-${process.pid}`;
const TEST_MCP_SOCKET_PATH = `${TEST_DIR}/voicelayer-mcp.sock`;
const TEST_DISABLE_FLAG_PATH = `${TEST_DIR}/voice-disabled.flag`;

function cleanup(): void {
  try {
    unlinkSync(TEST_MCP_SOCKET_PATH);
  } catch {}
  try {
    unlinkSync(TEST_DISABLE_FLAG_PATH);
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

  return Bun.spawn(["bun", "run", "src/mcp-server-daemon.ts"], {
    cwd: process.cwd(),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      QA_VOICE_MCP_SOCKET_PATH: TEST_MCP_SOCKET_PATH,
      QA_VOICE_DISABLE_FLAG_PATH: TEST_DISABLE_FLAG_PATH,
      ...extraEnv,
    },
  });
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
  });

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

  it("running daemon self-terminates when flag file appears", async () => {
    const daemon = spawnDaemon();

    expect(await waitForFile(TEST_MCP_SOCKET_PATH, 2000)).toBe(true);

    writeFileSync(TEST_DISABLE_FLAG_PATH, "disabled");

    const exitCode = await Promise.race([
      daemon.exited,
      Bun.sleep(6000).then(() => null),
    ]);

    if (exitCode === null) {
      daemon.kill();
      await daemon.exited;
    }

    expect(exitCode).toBe(0);
  });
});
