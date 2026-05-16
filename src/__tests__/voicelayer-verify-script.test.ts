import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

const repoRoot = new URL("../..", import.meta.url).pathname;
const scriptPath = join(repoRoot, "scripts", "voicelayer-verify.sh");

let tempRoot = "";

function run(command: string[], options: { env?: Record<string, string>; cwd?: string; input?: string } = {}) {
  const env = {
    ...process.env,
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    ...options.env,
  };
  delete env.GIT_DIR;
  delete env.GIT_WORK_TREE;
  delete env.GIT_INDEX_FILE;
  delete env.GIT_PREFIX;

  return Bun.spawnSync(command, {
    cwd: options.cwd ?? tempRoot,
    stdin: options.input ? new TextEncoder().encode(options.input) : undefined,
    stdout: "pipe",
    stderr: "pipe",
    env,
  });
}

function text(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

function initFakeRepo() {
  mkdirSync(join(tempRoot, "flow-bar"), { recursive: true });
  writeFileSync(
    join(tempRoot, "flow-bar", "build-app.sh"),
    "#!/usr/bin/env bash\nset -euo pipefail\necho build-app-called >> ../build.log\n",
    { mode: 0o755 },
  );
  run(["git", "init"]);
  run(["git", "config", "user.email", "test@example.com"]);
  run(["git", "config", "user.name", "Test User"]);
  writeFileSync(join(tempRoot, "README.md"), "fake\n");
  run(["git", "add", "."]);
  run(["git", "commit", "-m", "initial"]);
}

beforeEach(() => {
  tempRoot = mkdtempSync(join(tmpdir(), "voicelayer-verify-test-"));
  initFakeRepo();
});

afterEach(() => {
  if (tempRoot) rmSync(tempRoot, { recursive: true, force: true });
});

describe("voicelayer-verify.sh", () => {
  test("creates a runtime artifact for daemon-touching changes after confirmation", async () => {
    run(["git", "checkout", "-b", "feature/gate"]);
    const changed = join(tempRoot, "changed.txt");
    writeFileSync(changed, "src/mcp-socket-owner.ts\n");

    const result = run(["bash", scriptPath], {
      env: {
        VOICELAYER_VERIFY_REPO_ROOT: tempRoot,
        VOICELAYER_VERIFY_CHANGED_FILES_FILE: changed,
        VOICELAYER_VERIFY_SKIP_RELAUNCH: "1",
        VOICELAYER_VERIFY_TESTER: "Unit Test",
      },
      input: "Y\n",
    });

    expect(result.exitCode).toBe(0);
    expect(existsSync(join(tempRoot, "build.log"))).toBe(true);
    const artifacts = readdirSync(join(tempRoot, ".verified"));
    expect(artifacts).toHaveLength(1);
    expect(artifacts[0]).toContain("feature-gate");
    const body = await Bun.file(join(tempRoot, ".verified", artifacts[0])).text();
    expect(body).toContain("Verified-Runtime:");
    expect(body).toContain("tester: Unit Test");
    expect(body).toContain("src/mcp-socket-owner.ts");
  });

  test("does not create an artifact when manual confirmation is rejected", () => {
    const changed = join(tempRoot, "changed.txt");
    writeFileSync(changed, "src/socket-handlers.ts\n");

    const result = run(["bash", scriptPath], {
      env: {
        VOICELAYER_VERIFY_REPO_ROOT: tempRoot,
        VOICELAYER_VERIFY_CHANGED_FILES_FILE: changed,
        VOICELAYER_VERIFY_SKIP_RELAUNCH: "1",
      },
      input: "n\n",
    });

    expect(result.exitCode).not.toBe(0);
    expect(existsSync(join(tempRoot, ".verified"))).toBe(false);
  });

  test("skips verification when changed files do not touch daemon surfaces", () => {
    const changed = join(tempRoot, "changed.txt");
    writeFileSync(changed, "README.md\nscripts/speak.sh\n");

    const result = run(["bash", scriptPath], {
      env: {
        VOICELAYER_VERIFY_REPO_ROOT: tempRoot,
        VOICELAYER_VERIFY_CHANGED_FILES_FILE: changed,
      },
    });

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain("no daemon verification required");
    expect(existsSync(join(tempRoot, ".verified"))).toBe(false);
  });
});
