import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { dirname, join } from "path";

const repoRoot = new URL("../..", import.meta.url).pathname;
const predicatePath = join(
  repoRoot,
  "scripts",
  "check-daemon-verification-proof.sh",
);
const workflowPath = join(
  repoRoot,
  ".github",
  "workflows",
  "daemon-verification-gate.yml",
);

let tempRoot = "";
let signingKey = "";
let allowedSigners = "";

function run(
  command: string[],
  options: { cwd?: string; env?: Record<string, string> } = {},
) {
  return Bun.spawnSync(command, {
    cwd: options.cwd ?? tempRoot,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      LC_ALL: "C",
      ...options.env,
    },
  });
}

function text(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

function git(...args: string[]) {
  const result = run(["git", ...args]);
  if (result.exitCode !== 0) {
    throw new Error(
      `git ${args.join(" ")} failed:\n${text(result.stdout)}${text(result.stderr)}`,
    );
  }
  return text(result.stdout).trim();
}

function commitFile(path: string, body: string) {
  const absolute = join(tempRoot, path);
  mkdirSync(dirname(absolute), { recursive: true });
  writeFileSync(absolute, body);
  git("add", path);
  git("commit", "-m", `change ${path}`);
  return git("rev-parse", "HEAD");
}

function createRuntimeTag(options: {
  nameSha: string;
  targetSha: string;
  markerSha: string;
  signed: boolean;
}) {
  const tagName = `runtime-verified/${options.nameSha}`;
  const message = [
    `Verified-Runtime: ${options.markerSha}`,
    "timestamp: 2026-07-22T12:00:00Z",
    "tester: Proof Test",
    "verification_mode: corpus",
  ].join("\n");
  const args = options.signed
    ? [
        "-c",
        "gpg.format=ssh",
        "-c",
        `user.signingkey=${signingKey}`,
        "tag",
        "-s",
        "-m",
        message,
        tagName,
        options.targetSha,
      ]
    : ["tag", "-a", "-m", message, tagName, options.targetSha];
  git(...args);
}

function runPredicate(baseSha: string, headSha: string) {
  return run([
    "bash",
    predicatePath,
    baseSha,
    headSha,
    allowedSigners,
  ]);
}

beforeEach(() => {
  tempRoot = mkdtempSync(join(tmpdir(), "daemon-proof-test-"));
  git("init", "-b", "main");
  git("config", "user.name", "Proof Test");
  git("config", "user.email", "proof@example.com");
  writeFileSync(join(tempRoot, "README.md"), "base\n");
  git("add", "README.md");
  git("commit", "-m", "base");

  signingKey = join(tempRoot, "runtime-signing-key");
  const keygen = run([
    "ssh-keygen",
    "-q",
    "-t",
    "ed25519",
    "-N",
    "",
    "-C",
    "daemon-proof-test",
    "-f",
    signingKey,
  ]);
  if (keygen.exitCode !== 0) {
    throw new Error(`ssh-keygen failed: ${text(keygen.stderr)}`);
  }
  allowedSigners = join(tempRoot, "allowed_signers");
  const publicKey = readFileSync(`${signingKey}.pub`, "utf8").trim();
  writeFileSync(allowedSigners, `* ${publicKey}\n`);
});

afterEach(() => {
  if (tempRoot) rmSync(tempRoot, { recursive: true, force: true });
});

describe("daemon verification proof predicate", () => {
  test("skips when no daemon, socket, MCP, or VoiceBar path changed", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("docs/example.md", "docs only\n");

    const result = runPredicate(base, head);

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain("runtime gate not required");
  });

  test("skips non-daemon changes before requiring signer configuration", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("docs/example.md", "docs only\n");
    const missingSigners = join(tempRoot, "missing-allowed-signers");

    const result = run([
      "bash",
      predicatePath,
      base,
      head,
      missingSigners,
    ]);

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain("runtime gate not required");
    expect(text(result.stderr)).not.toContain("allowed signers");
  });

  test("fails closed for daemon changes when signer configuration is missing", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("src/daemon.ts", "sensitive\n");
    const missingSigners = join(tempRoot, "missing-allowed-signers");

    const result = run([
      "bash",
      predicatePath,
      base,
      head,
      missingSigners,
    ]);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stderr)).toContain("allowed signers");
  });

  test.each([
    "src/mcp-daemon.ts",
    "src/recording-state.ts",
    "src/voicesdk/protocol.ts",
    "src/soundlayer/bridge.ts",
    "flow-bar/Sources/VoiceBar/SocketServer.swift",
  ])("requires proof for the shared sensitive-path law: %s", (path) => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile(path, "sensitive\n");

    const result = runPredicate(base, head);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stderr)).toContain(
      `missing signed runtime verification tag for ${head}`,
    );
  });

  test("requires proof when a sensitive path is renamed outside the path law", () => {
    const base = commitFile("src/daemon.ts", "sensitive\n");
    mkdirSync(join(tempRoot, "docs"), { recursive: true });
    git("mv", "src/daemon.ts", "docs/daemon-reference.ts");
    git("commit", "-m", "rename daemon source outside sensitive paths");
    const head = git("rev-parse", "HEAD");

    const result = runPredicate(base, head);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stdout)).toContain("src/daemon.ts");
    expect(text(result.stderr)).toContain(
      `missing signed runtime verification tag for ${head}`,
    );
  });

  test("rejects an unsigned exact-head tag", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("src/mcp-daemon.ts", "sensitive\n");
    createRuntimeTag({
      nameSha: head,
      targetSha: head,
      markerSha: head,
      signed: false,
    });

    const result = runPredicate(base, head);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stderr)).toContain("signature verification failed");
  });

  test("rejects a signed tag whose target is not the head", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("src/mcp-daemon.ts", "sensitive\n");
    createRuntimeTag({
      nameSha: head,
      targetSha: base,
      markerSha: head,
      signed: true,
    });

    const result = runPredicate(base, head);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stderr)).toContain("does not target head sha");
  });

  test("rejects a signed exact-head tag with a stale marker", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("src/mcp-daemon.ts", "sensitive\n");
    createRuntimeTag({
      nameSha: head,
      targetSha: head,
      markerSha: base,
      signed: true,
    });

    const result = runPredicate(base, head);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stderr)).toContain("exact head marker");
  });

  test("does not replay a valid signed tag from an earlier head", () => {
    const base = git("rev-parse", "HEAD");
    const firstHead = commitFile("src/mcp-daemon.ts", "first\n");
    createRuntimeTag({
      nameSha: firstHead,
      targetSha: firstHead,
      markerSha: firstHead,
      signed: true,
    });
    const currentHead = commitFile("src/mcp-daemon.ts", "second\n");

    const result = runPredicate(base, currentHead);

    expect(result.exitCode).not.toBe(0);
    expect(text(result.stderr)).toContain(
      `missing signed runtime verification tag for ${currentHead}`,
    );
  });

  test("accepts an allowlisted signed tag bound to the exact head", () => {
    const base = git("rev-parse", "HEAD");
    const head = commitFile("src/mcp-daemon.ts", "sensitive\n");
    createRuntimeTag({
      nameSha: head,
      targetSha: head,
      markerSha: head,
      signed: true,
    });

    const result = runPredicate(base, head);

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain(
      `signed runtime verification accepted for ${head}`,
    );
  });
});

describe("daemon verification workflow contract", () => {
  test("uses the tracked signed-proof predicate and never trusts PR body text", () => {
    const workflow = readFileSync(workflowPath, "utf8");

    expect(workflow).toContain("scripts/check-daemon-verification-proof.sh");
    expect(workflow).toContain('"$BASE_SHA" "$HEAD_SHA"');
    expect(workflow).toContain("runtime-verified/$HEAD_SHA");
    expect(workflow).toContain(
      'git show "$BASE_SHA:scripts/check-daemon-verification-proof.sh"',
    );
    expect(workflow).toContain(
      'elif [ "$BASE_SHA" = "d292366078594e900f9e3f4201297a104e650e47" ]; then',
    );
    expect(workflow).not.toContain(
      "5396e4cfb87b9e0d715af9fc9dd39cb2d1ae5284",
    );
    expect(workflow).toContain(
      "BOOTSTRAP_PREDICATE_SHA256: ${{ vars.VOICELAYER_DAEMON_PROOF_PREDICATE_SHA256 }}",
    );
    expect(workflow).toContain("sha256sum -c -");
    expect(workflow).not.toContain(
      "a3e32626e2a9b7202ddb0bdb1671ff3d4e6f46ff",
    );
    expect(workflow).not.toContain(
      "bash scripts/check-daemon-verification-proof.sh",
    );
    expect(workflow).not.toContain('if [ -z "$RUNTIME_SIGNER" ]');
    expect(workflow).not.toContain("PR_BODY");
    expect(workflow).not.toContain('grep -Fqx "$marker"');
  });
});
