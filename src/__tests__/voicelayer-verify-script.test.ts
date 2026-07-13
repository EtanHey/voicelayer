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

function writeFakeExecutable(name: string, body: string) {
  const binDir = join(tempRoot, "fake-bin");
  mkdirSync(binDir, { recursive: true });
  writeFileSync(join(binDir, name), body, { mode: 0o755 });
  return binDir;
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

  test("requires runtime verification for recording state gate changes", async () => {
    const changed = join(tempRoot, "changed.txt");
    writeFileSync(changed, "src/recording-state.ts\n");

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
    const artifacts = readdirSync(join(tempRoot, ".verified"));
    expect(artifacts).toHaveLength(1);
    const body = await Bun.file(join(tempRoot, ".verified", artifacts[0])).text();
    expect(body).toContain("Verified-Runtime:");
    expect(body).toContain("src/recording-state.ts");
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

  test("runs corpus and interaction verification without human input on isolated sockets", async () => {
    run(["git", "checkout", "-b", "feature/corpus-gate"]);
    const changed = join(tempRoot, "changed.txt");
    const corpusRoot = join(tempRoot, "corpus");
    const runnerLog = join(tempRoot, "runner.log");
    const corpusRunner = join(tempRoot, "corpus-runner.sh");
    const interactionRunner = join(tempRoot, "interaction-runner.sh");
    mkdirSync(corpusRoot, { recursive: true });
    writeFileSync(changed, "src/mcp-server-daemon.ts\n");
    writeFileSync(
      corpusRunner,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'test "$VOICELAYER_SOCKET_PATH" != "/tmp/voicelayer.sock"',
        'test "$VOICELAYER_MCP_SOCKET_PATH" != "/tmp/voicelayer-mcp.sock"',
        'test "$VOICELAYER_SOCKET_PATH" = "$QA_VOICE_SOCKET_PATH"',
        'test "$VOICELAYER_MCP_SOCKET_PATH" = "$QA_VOICE_MCP_SOCKET_PATH"',
        'printf "corpus:%s:%s:%s\\n" "$1" "$2" "$VOICELAYER_SOCKET_PATH" >> "$RUNNER_LOG"',
        "",
      ].join("\n"),
      { mode: 0o755 },
    );
    writeFileSync(
      interactionRunner,
      [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        'printf "interaction:%s\\n" "$VOICELAYER_SOCKET_PATH" >> "$RUNNER_LOG"',
        "",
      ].join("\n"),
      { mode: 0o755 },
    );

    const result = run(["bash", scriptPath, "--corpus", "2"], {
      env: {
        RUNNER_LOG: runnerLog,
        VOICELAYER_VERIFY_REPO_ROOT: tempRoot,
        VOICELAYER_VERIFY_CHANGED_FILES_FILE: changed,
        VOICELAYER_VERIFY_CORPUS_ROOT: corpusRoot,
        VOICELAYER_VERIFY_CORPUS_RUNNER: corpusRunner,
        VOICELAYER_VERIFY_INTERACTION_RUNNER: interactionRunner,
        VOICELAYER_VERIFY_TESTER: "Corpus Unit Test",
      },
    });

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).not.toContain("Press F5");
    expect(existsSync(join(tempRoot, "build.log"))).toBe(false);
    const runnerOutput = await Bun.file(runnerLog).text();
    expect(runnerOutput).toContain(`corpus:2:${corpusRoot}:`);
    expect(runnerOutput).toContain("interaction:");

    const artifacts = readdirSync(join(tempRoot, ".verified"));
    expect(artifacts).toHaveLength(1);
    const body = await Bun.file(join(tempRoot, ".verified", artifacts[0])).text();
    expect(body).toContain("Verified-Runtime:");
    expect(body).toContain("tester: Corpus Unit Test");
    expect(body).toContain("verification_mode: corpus");
    expect(body).toContain("corpus_count: 2");
  });

  test("removes a stale corpus artifact before a failed verification attempt", () => {
    run(["git", "checkout", "-b", "feature/corpus-stale"]);
    const changed = join(tempRoot, "changed.txt");
    const failingRunner = join(tempRoot, "failing-runner.sh");
    writeFileSync(changed, "src/mcp-server-daemon.ts\n");
    writeFileSync(failingRunner, "#!/usr/bin/env bash\nexit 1\n", { mode: 0o755 });
    const shortSha = text(run(["git", "rev-parse", "--short", "HEAD"]).stdout).trim();
    const artifact = join(
      tempRoot,
      ".verified",
      `verified-runtime-feature-corpus-stale-${shortSha}.txt`,
    );
    mkdirSync(join(tempRoot, ".verified"), { recursive: true });
    writeFileSync(artifact, "Verified-Runtime: stale\n");

    const result = run(["bash", scriptPath, "--corpus", "2"], {
      env: {
        VOICELAYER_VERIFY_REPO_ROOT: tempRoot,
        VOICELAYER_VERIFY_CHANGED_FILES_FILE: changed,
        VOICELAYER_VERIFY_CORPUS_RUNNER: failingRunner,
      },
    });

    expect(result.exitCode).not.toBe(0);
    expect(existsSync(artifact)).toBe(false);
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

  test("treats a launchd VoiceBar respawn as a successful relaunch", async () => {
    const changed = join(tempRoot, "changed.txt");
    const stateFile = join(tempRoot, "pgrep-state");
    const openCalls = join(tempRoot, "open-calls");
    const oldPid = "424242";
    const bashEnv = join(tempRoot, "fake-bash-env");
    writeFileSync(changed, "src/socket-handlers.ts\n");
    writeFileSync(stateFile, "before\n");
    writeFileSync(
      bashEnv,
      `kill() {
  if [ "$1" = "-0" ] && [ "$2" = "${oldPid}" ]; then
    [ "$(cat "${stateFile}")" = "before" ]
    return $?
  fi
  command kill "$@"
}
`,
    );

    const fakeBin = writeFakeExecutable(
      "pgrep",
      `#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "-x" ] && [ "$2" = "VoiceBar" ]; then
  if [ "$(cat "${stateFile}")" = "before" ]; then
    printf '${oldPid}\\n'
  else
    printf '222\\n'
  fi
  exit 0
fi
if [ "$1" = "-f" ]; then
  exit 1
fi
exit 1
`,
    );
    writeFakeExecutable(
      "pkill",
      `#!/usr/bin/env bash
set -euo pipefail
printf 'after\\n' > "${stateFile}"
`,
    );
    writeFakeExecutable(
      "launchctl",
      `#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "list" ] && [ "$2" = "com.voicelayer.voicebar" ]; then
  exit 0
fi
exit 1
`,
    );
    writeFakeExecutable(
      "open",
      `#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${openCalls}"
exit 0
`,
    );
    writeFakeExecutable("lsof", "#!/usr/bin/env bash\nexit 1\n");

    const result = run(["bash", scriptPath], {
      env: {
        BASH_ENV: bashEnv,
        PATH: `${fakeBin}:${process.env.PATH}`,
        VOICELAYER_VERIFY_REPO_ROOT: tempRoot,
        VOICELAYER_VERIFY_CHANGED_FILES_FILE: changed,
        VOICELAYER_VERIFY_SKIP_BUILD: "1",
        VOICELAYER_VERIFY_TESTER: "Unit Test",
      },
      input: "Y\nY\n",
    });

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain("launchd relaunched VoiceBar");
    expect(existsSync(openCalls)).toBe(false);
    const artifacts = readdirSync(join(tempRoot, ".verified"));
    expect(artifacts).toHaveLength(1);
    const body = await Bun.file(join(tempRoot, ".verified", artifacts[0])).text();
    expect(body).toContain("Verified-Runtime:");
  });
});
