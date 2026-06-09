import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const updateScript = join(repoRoot, "scripts", "voicelayer-update.sh");
const cliScript = join(repoRoot, "src", "cli", "voicelayer.sh");

function run(command: string[], env: Record<string, string> = {}) {
  return Bun.spawnSync(command, {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      ...env,
    },
  });
}

function text(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

describe("voicelayer-update.sh", () => {
  test("dry-run prints the full M1 update plan without executing live steps", () => {
    const result = run(["bash", updateScript, "--dry-run"]);
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain("DRY RUN: yes");
    expect(stdout).toContain("git pull --ff-only");
    expect(stdout).toContain("bun install");
    expect(stdout).toContain("bash flow-bar/build-app.sh");
    expect(stdout).toContain("bash launchd/install.sh");
    expect(stdout).toContain("Qwen3 model");
    expect(stdout).toContain("~/.voicelayer/voices/");
    expect(stdout).toContain("~/.voicelayer/voices.json");
    expect(stdout).toContain("~/.voicelayer/pronunciation.yaml");
    expect(stdout).toContain("~/.voicelayer/daemon.secret");
    expect(stdout).toContain("~/.local/state/voicelayer/stt-vocabulary.json");
    expect(stdout).toContain("DATA SOURCE: pending Etan decision");
  });

  test("requires a data source for non-dry-run updates", () => {
    const result = run(["bash", updateScript], {
      VOICELAYER_UPDATE_SKIP_HOST_GUARD: "1",
    });

    expect(result.exitCode).toBe(2);
    expect(text(result.stderr)).toContain("--data-source is required");
  });

  test("accepts either direct or brain-drive data source mode in dry-run", () => {
    const direct = run([
      "bash",
      updateScript,
      "--dry-run",
      "--data-mode",
      "direct",
      "--data-source",
      "etan-main.local:/Users/etanheyman",
    ]);
    const brainDrive = run([
      "bash",
      updateScript,
      "--dry-run",
      "--data-mode",
      "brain-drive",
      "--data-source",
      "/Volumes/BrainDrive/VoiceLayerBackup/etanheyman",
    ]);

    expect(direct.exitCode).toBe(0);
    expect(text(direct.stdout)).toContain("DATA MODE: direct");
    expect(text(direct.stdout)).toContain(
      "etan-main.local:/Users/etanheyman/.voicelayer/voices/",
    );
    expect(brainDrive.exitCode).toBe(0);
    expect(text(brainDrive.stdout)).toContain("DATA MODE: brain-drive");
    expect(text(brainDrive.stdout)).toContain(
      "/Volumes/BrainDrive/VoiceLayerBackup/etanheyman/.voicelayer/voices/",
    );
  });

  test("CLI dispatches `voicelayer update` to the update script", () => {
    const result = run(["bash", cliScript, "update", "--dry-run"]);

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain("VoiceLayer M1 update plan");
  });

  test("script uses the shell hardening baseline", () => {
    const body = readFileSync(updateScript, "utf8");

    expect(body).toContain("#!/usr/bin/env bash");
    expect(body).toContain("set -euo pipefail");
    expect(body).not.toContain("eval ");
    expect(body).not.toContain("bash -c");
  });
});
