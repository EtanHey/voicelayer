import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const repoRoot = new URL("../..", import.meta.url).pathname;
const scriptPath = join(repoRoot, "scripts", "auto-f5-verify.sh");

function runFunction(body: string, env: Record<string, string> = {}) {
  return Bun.spawnSync(
    [
      "bash",
      "-c",
      `set -euo pipefail; VOICELAYER_AUTO_F5_SOURCE_ONLY=1 source "$1"; ${body}`,
      "bash",
      scriptPath,
    ],
    {
      stdout: "pipe",
      stderr: "pipe",
      env: {
        ...process.env,
        ...env,
      },
    },
  );
}

function text(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

describe("auto-f5-verify.sh pure helpers", () => {
  test("uses the HID-level Swift sender by default", () => {
    const result = runFunction('printf "%s\\n" "$F5_SENDER"');

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout).trim()).toBe("swift");
  });

  test("passes the configured verification tester through to voicelayer-verify", () => {
    const workDir = mkdtempSync(join(tmpdir(), "auto-f5-test-"));
    try {
      const fakeVerifyScript = join(workDir, "voicelayer-verify.sh");
      writeFileSync(
        fakeVerifyScript,
        [
          "#!/usr/bin/env bash",
          "set -euo pipefail",
          "printf 'tester=%s\\n' \"${VOICELAYER_VERIFY_TESTER:-}\"",
          "IFS= read -r answer || true",
          "printf 'answer=%s\\n' \"$answer\"",
          "",
        ].join("\n"),
        { mode: 0o755 },
      );

      const result = runFunction(
        [
          "start_verify_process",
          "printf 'Y\\n' >&3",
          "close_verify_stdin",
          'wait "$VERIFY_PID"',
          'cat "$LOG_FILE"',
        ].join("; "),
        {
          VOICELAYER_AUTO_F5_WORK_DIR: workDir,
          VOICELAYER_AUTO_F5_VERIFY_SCRIPT: fakeVerifyScript,
          VOICELAYER_VERIFY_TESTER: "auto-F5-etan-consented-live",
        },
      );

      expect(result.exitCode).toBe(0);
      const output = text(result.stdout);
      expect(output).toContain("tester=auto-F5-etan-consented-live");
      expect(output).toContain("answer=Y");
    } finally {
      rmSync(workDir, { recursive: true, force: true });
    }
  });

  test("matches expected whisper variants of verification test", () => {
    const result = runFunction('sink_contains_verification "$SINK_TEXT"', {
      SINK_TEXT: "Verification test.\n",
    });

    expect(result.exitCode).toBe(0);
  });

  test("rejects sink text without verification test in order", () => {
    const result = runFunction('sink_contains_verification "$SINK_TEXT"', {
      SINK_TEXT: "The verifier ran a different smoke phrase.",
    });

    expect(result.exitCode).toBe(1);
  });

  test("converts HID idle nanoseconds into whole seconds", () => {
    const result = runFunction("hid_idle_ns_to_seconds 120999999999");

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout).trim()).toBe("120");
  });

  test("requires the configured user idle threshold", () => {
    const idleEnough = runFunction("user_idle_ns_meets_threshold 120000000000 120");
    const tooRecent = runFunction("user_idle_ns_meets_threshold 119999999999 120");

    expect(idleEnough.exitCode).toBe(0);
    expect(tooRecent.exitCode).toBe(1);
  });

  test("formats auto-F5 provenance so artifacts cannot be mistaken for Etan runs", () => {
    const result = runFunction('format_auto_provenance "abc123" "/tmp/verification.wav"');

    expect(result.exitCode).toBe(0);
    const output = text(result.stdout);
    expect(output).toContain("Tester: auto-F5 (programmatic, no human)");
    expect(output).toContain("Loop-Audio-SHA256: abc123");
    expect(output).toContain("Loop-Audio-File: /tmp/verification.wav");
  });

  test("extracts the runtime artifact path from voicelayer-verify output", () => {
    const result = runFunction('artifact_path_from_verify_log "$VERIFY_LOG"', {
      VERIFY_LOG:
        "[voicelayer-verify] wrote runtime artifact: /tmp/repo/.verified/verified-runtime-feat-auto.txt\nVerified-Runtime: abc\n",
    });

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout).trim()).toBe(
      "/tmp/repo/.verified/verified-runtime-feat-auto.txt",
    );
  });
});
