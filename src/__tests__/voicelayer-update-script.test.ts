import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  copyFileSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
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
      VOICELAYER_UPDATE_TEST_BREW_CASK_INSTALLED: "0",
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
    expect(stdout).toContain("INSTALL TYPE:");
    expect(stdout).toContain("PACKAGE UPDATE:");
    expect(stdout).toContain("bash flow-bar/build-app.sh");
    expect(stdout).toContain(
      "build-app.sh relaunches VoiceBar unless --no-relaunch is set",
    );
    expect(stdout).not.toContain("bash launchd/install.sh");
    expect(stdout).not.toContain("restart VoiceLayer daemon");
    expect(stdout).not.toContain("open /Applications/VoiceBar.app");
    expect(stdout).toContain("Qwen3 model");
    expect(stdout).toContain("Personal data sync: skipped");
  });

  test("update requires the stable Developer ID signing identity for resident rebuilds", () => {
    const result = run(["bash", updateScript, "--dry-run"]);
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain("VOICEBAR_CODESIGN_IDENTITY=");
    expect(stdout).toContain(
      "Developer\\ ID\\ Application:\\ Etan\\ Heyman\\ \\(PPN23G925Y\\)",
    );
    expect(stdout).not.toContain("Apple Development");
  });

  test("dry-run passes VoiceBar stop and relaunch opt-outs to build-app", () => {
    const result = run([
      "bash",
      updateScript,
      "--dry-run",
      "--no-stop",
      "--no-relaunch",
    ]);
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain(
      "bash flow-bar/build-app.sh --no-stop --no-relaunch",
    );
    expect(stdout).toContain(
      "build-app.sh relaunches VoiceBar unless --no-relaunch is set",
    );
  });

  test("brew-cask-managed VoiceBar upgrades in place instead of forcing a reinstall", () => {
    const result = run(["bash", updateScript, "--dry-run"], {
      VOICELAYER_UPDATE_TEST_BREW_CASK_INSTALLED: "1",
    });
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain(
      "VOICEBAR APP UPDATE: brew upgrade --cask etanhey/layers/voicebar",
    );
    expect(stdout).toContain(
      "+ brew upgrade --cask etanhey/layers/voicebar",
    );
    expect(stdout).not.toContain("brew reinstall --cask");
    expect(stdout).not.toContain("bash flow-bar/build-app.sh");
  });

  test("non-dry-run cask path skips build-app when commands are dry-run-stubbed", () => {
    const result = run(["bash", updateScript], {
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
      VOICELAYER_UPDATE_TEST_BREW_CASK_INSTALLED: "1",
    });
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain(
      "+ brew upgrade --cask etanhey/layers/voicebar",
    );
    expect(stdout).not.toContain("+ env VOICEBAR_CODESIGN_IDENTITY=");
    expect(stdout).not.toContain(`bash ${repoRoot}/flow-bar/build-app.sh`);
  });

  test("cask path reinstalls only when the upgraded resident app is still damaged", () => {
    const result = run(["bash", updateScript], {
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
      VOICELAYER_UPDATE_TEST_BREW_CASK_INSTALLED: "1",
      VOICELAYER_UPDATE_TEST_CASK_REPAIR_NEEDED: "1",
    });
    const stdout = text(result.stdout);
    const upgrade = stdout.indexOf(
      "+ brew upgrade --cask etanhey/layers/voicebar",
    );
    const reinstall = stdout.indexOf(
      "+ brew reinstall --cask etanhey/layers/voicebar",
    );

    expect(result.exitCode).toBe(0);
    expect(upgrade).toBeGreaterThanOrEqual(0);
    expect(reinstall).toBeGreaterThan(upgrade);
    expect(stdout).toContain(
      "Resident VoiceBar failed canonical signature checks",
    );
  });

  test("an already-current cask skips upgrade without bypassing repair checks", () => {
    const tempRoot = mkdtempSync(join(tmpdir(), "voicelayer-cask-current-"));
    const binDir = join(tempRoot, "bin");
    const brewLog = join(tempRoot, "brew.log");
    const brewStub = join(binDir, "brew");
    mkdirSync(binDir, { recursive: true });
    writeFileSync(
      brewStub,
      [
        "#!/usr/bin/env bash",
        'printf "%s\\n" "$*" >> "$VOICEBAR_TEST_BREW_LOG"',
        '[[ "$1" == "outdated" ]] && exit 0',
        '[[ "$1" == "upgrade" ]] && exit 7',
        "exit 0",
        "",
      ].join("\n"),
    );
    chmodSync(brewStub, 0o755);

    const result = run(
      [
        "bash",
        "-c",
        [
          'source "$1"',
          "voicebar_app_update_mode() { printf 'cask-upgrade\\n'; }",
          "voicebar_cask_repair_needed() { return 1; }",
          "update_voicebar_app",
        ].join("; "),
        "_",
        updateScript,
      ],
      {
        PATH: `${binDir}:${process.env.PATH ?? ""}`,
        VOICEBAR_TEST_BREW_LOG: brewLog,
      },
    );

    expect(result.exitCode).toBe(0);
    const calls = readFileSync(brewLog, "utf8");
    expect(calls).toContain("outdated --cask --quiet");
    expect(calls).not.toContain("upgrade --cask");
  });

  test("standard updates restore and verify the complete canonical hotkey path after the app update", () => {
    const result = run(["bash", updateScript], {
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
    });
    const stdout = text(result.stdout);
    const appUpdate = stdout.indexOf(
      `bash ${repoRoot}/flow-bar/build-app.sh`,
    );
    const dedupe = stdout.indexOf(
      `bash ${repoRoot}/scripts/voicelayer-dedupe-voicebar.sh --apply --no-relaunch`,
    );
    const remap = stdout.indexOf(
      `bash ${repoRoot}/scripts/install-voicebar-f5-hidutil.sh`,
    );
    const autostart = stdout.indexOf(
      `bash ${repoRoot}/scripts/install-voicebar-autostart.sh --reload`,
    );
    const verify = stdout.indexOf(
      `bash ${repoRoot}/scripts/verify-voicebar-hotkey-health.sh`,
    );

    expect(result.exitCode).toBe(0);
    expect(appUpdate).toBeGreaterThanOrEqual(0);
    expect(dedupe).toBeGreaterThan(appUpdate);
    expect(remap).toBeGreaterThan(dedupe);
    expect(autostart).toBeGreaterThan(remap);
    expect(verify).toBeGreaterThan(autostart);
    expect(stdout).not.toContain("launchctl kickstart -k gui/");
    expect(stdout).not.toContain("hotkey postflight skipped");
  });

  test("explicit no-relaunch updates still run static hotkey checks without restarting VoiceBar", () => {
    const result = run(
      ["bash", updateScript, "--no-stop", "--no-relaunch"],
      { VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1" },
    );
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain(
      `bash ${repoRoot}/scripts/voicelayer-dedupe-voicebar.sh --apply --no-stop --no-relaunch`,
    );
    expect(stdout).toContain(
      `bash ${repoRoot}/scripts/verify-voicebar-hotkey-health.sh --allow-stopped`,
    );
    expect(stdout).toContain(
      `bash ${repoRoot}/scripts/install-voicebar-autostart.sh --preserve-load-state`,
    );
    expect(stdout).not.toContain(
      `bash ${repoRoot}/scripts/install-voicebar-autostart.sh --reload`,
    );
    expect(stdout).not.toContain("launchctl kickstart -k gui/");
  });

  test("no-relaunch without no-stop still stops and dedupes the old VoiceBar process", () => {
    const result = run(
      ["bash", updateScript, "--no-relaunch"],
      { VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1" },
    );
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain(
      `bash ${repoRoot}/scripts/voicelayer-dedupe-voicebar.sh --apply --no-relaunch`,
    );
    expect(stdout).not.toContain(
      `bash ${repoRoot}/scripts/voicelayer-dedupe-voicebar.sh --apply --no-stop`,
    );
    expect(stdout).toContain(
      `bash ${repoRoot}/scripts/verify-voicebar-hotkey-health.sh --allow-stopped`,
    );
    expect(stdout).toContain(
      `bash ${repoRoot}/scripts/install-voicebar-autostart.sh --no-start`,
    );
    expect(stdout).not.toContain("launchctl kickstart -k gui/");
  });

  test("non-dry-run updates can skip personal data sync", () => {
    const result = run(["bash", updateScript], {
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
    });

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain("VoiceLayer update complete.");
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

  test("CLI exposes `voicelayer doctor` as the dry-run VoiceBar dedupe tool", () => {
    const body = readFileSync(cliScript, "utf8");
    const dedupeScript = readFileSync(
      join(repoRoot, "scripts", "voicelayer-dedupe-voicebar.sh"),
      "utf8",
    );

    expect(body).toContain("doctor)");
    expect(body).toContain(
      'exec bash "$PACKAGE_ROOT/scripts/voicelayer-dedupe-voicebar.sh" "$@"',
    );
    expect(body).toContain("  doctor");
    expect(dedupeScript).toContain("SAFE BY DEFAULT");
    expect(dedupeScript).toContain("pass --apply");
    expect(dedupeScript).toContain("BACKUP_DIR=");
    expect(dedupeScript).not.toContain('rm -rf "$b"');
    expect(dedupeScript).toContain("install-voicebar-autostart.sh");
    expect(dedupeScript).not.toContain('bash "$SCRIPT_DIR/../launchd/install.sh"');
    expect(dedupeScript).toContain(
      'bash "$AUTOSTART_INSTALLER" --reload',
    );
    expect(dedupeScript).toContain(
      'bash "$AUTOSTART_INSTALLER" --no-start',
    );
    expect(dedupeScript).toContain(
      'bash "$AUTOSTART_INSTALLER" --preserve-load-state',
    );
    expect(dedupeScript).not.toContain(
      'launchctl kickstart -k "gui/$(id -u)/$LABEL"',
    );
  });

  test("global Bun install path uses the actual global update command", () => {
    const tempRoot = mkdtempSync(join(tmpdir(), "voicelayer-update-global-"));
    const scriptsDir = join(tempRoot, "scripts");
    const binDir = join(tempRoot, "bin");
    mkdirSync(scriptsDir, { recursive: true });
    mkdirSync(binDir, { recursive: true });
    copyFileSync(updateScript, join(scriptsDir, "voicelayer-update.sh"));
    writeFileSync(join(binDir, "bun"), "#!/usr/bin/env bash\nexit 0\n");
    Bun.spawnSync(["chmod", "755", join(binDir, "bun")]);

    const result = run(["bash", join(scriptsDir, "voicelayer-update.sh")], {
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
    });
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain("PACKAGE UPDATE: bun update -g voicelayer-mcp");
    expect(stdout).toContain("+ bun update -g voicelayer-mcp");
    expect(stdout).not.toContain("bun pm update");
  });

  test("package copy nested inside another git repo still uses global update path", () => {
    const outerRepo = mkdtempSync(join(tmpdir(), "voicelayer-update-nested-"));
    const packageRoot = join(outerRepo, "node_modules", "voicelayer-mcp");
    const scriptsDir = join(packageRoot, "scripts");
    const binDir = join(outerRepo, "bin");
    mkdirSync(scriptsDir, { recursive: true });
    mkdirSync(binDir, { recursive: true });
    copyFileSync(updateScript, join(scriptsDir, "voicelayer-update.sh"));
    writeFileSync(join(binDir, "bun"), "#!/usr/bin/env bash\nexit 0\n");
    Bun.spawnSync(["chmod", "755", join(binDir, "bun")]);
    Bun.spawnSync(["git", "init", outerRepo], {
      stdout: "ignore",
      stderr: "ignore",
    });

    const result = run(["bash", join(scriptsDir, "voicelayer-update.sh")], {
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
    });
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain("INSTALL TYPE: global-package");
    expect(stdout).toContain("+ bun update -g voicelayer-mcp");
    expect(stdout).not.toContain("git -C");
    expect(stdout).not.toContain(`bun install --cwd ${packageRoot}`);
  });

  test("git checkout dependency install runs from the package root", () => {
    const result = run(["bash", updateScript], {
      VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1",
    });
    const stdout = text(result.stdout);

    expect(result.exitCode).toBe(0);
    expect(stdout).toContain(`+ bun install --cwd ${repoRoot}`);
    expect(stdout).not.toContain("+ bun install\n");
  });

  test("CLI exposes build-app and launches the canonical VoiceBar app bundle", () => {
    const body = readFileSync(cliScript, "utf8");

    expect(body).toContain("build-app)");
    expect(body).toContain('bash "$PACKAGE_ROOT/flow-bar/build-app.sh"');
    expect(body).toContain('open "/Applications/VoiceBar.app"');
    expect(body).not.toContain('exec ".build/release/VoiceBar"');
  });

  test("script uses the shell hardening baseline", () => {
    const body = readFileSync(updateScript, "utf8");

    expect(body).toContain("#!/usr/bin/env bash");
    expect(body).toContain("set -euo pipefail");
    expect(body).not.toContain("eval ");
    expect(body).not.toContain("bash -c");
  });

  test("live hotkey verification has a bounded startup retry window", () => {
    const body = readFileSync(updateScript, "utf8");

    expect(body).toContain("VOICEBAR_HEALTH_MAX_ATTEMPTS=10");
    expect(body).toContain("VOICEBAR_HEALTH_RETRY_DELAY_SECONDS=1");
    expect(body).toContain("verify_voicebar_hotkey_health() {");
    expect(body).toContain(
      'while [[ "$attempt" -le "$VOICEBAR_HEALTH_MAX_ATTEMPTS" ]]',
    );
    expect(body).toContain(
      'run_cmd sleep "$VOICEBAR_HEALTH_RETRY_DELAY_SECONDS"',
    );
    expect(body).toContain(
      'verify_voicebar_hotkey_health "${health_args[@]+"${health_args[@]}"}"',
    );
  });

  test("live hotkey verification retries until the health probe is ready", () => {
    const tempRoot = mkdtempSync(join(tmpdir(), "voicelayer-health-retry-"));
    const scriptsDir = join(tempRoot, "scripts");
    const healthStub = join(scriptsDir, "verify-voicebar-hotkey-health.sh");
    const attemptFile = join(tempRoot, "attempts");
    mkdirSync(scriptsDir, { recursive: true });
    writeFileSync(
      healthStub,
      [
        "#!/usr/bin/env bash",
        'attempt=0',
        '[[ -f "$VOICEBAR_HEALTH_TEST_ATTEMPTS" ]] && read -r attempt < "$VOICEBAR_HEALTH_TEST_ATTEMPTS"',
        'attempt=$((attempt + 1))',
        'printf "%s\\n" "$attempt" > "$VOICEBAR_HEALTH_TEST_ATTEMPTS"',
        '[[ "$attempt" -ge 3 ]]',
        "",
      ].join("\n"),
    );
    chmodSync(healthStub, 0o755);

    const result = run(
      [
        "bash",
        "-c",
        [
          'source "$1"',
          'PACKAGE_ROOT="$2"',
          "VOICEBAR_HEALTH_MAX_ATTEMPTS=3",
          "VOICEBAR_HEALTH_RETRY_DELAY_SECONDS=0",
          "verify_voicebar_hotkey_health --allow-stopped",
        ].join("; "),
        "_",
        updateScript,
        tempRoot,
      ],
      { VOICEBAR_HEALTH_TEST_ATTEMPTS: attemptFile },
    );

    expect(result.exitCode).toBe(0);
    expect(readFileSync(attemptFile, "utf8").trim()).toBe("3");
    expect(text(result.stdout).match(/verify-voicebar-hotkey-health\.sh/g)).toHaveLength(3);
  });

  test("hotkey verification fails after exhausting its bounded retries", () => {
    const tempRoot = mkdtempSync(join(tmpdir(), "voicelayer-health-exhaust-"));
    const scriptsDir = join(tempRoot, "scripts");
    const healthStub = join(scriptsDir, "verify-voicebar-hotkey-health.sh");
    const attemptFile = join(tempRoot, "attempts");
    mkdirSync(scriptsDir, { recursive: true });
    writeFileSync(
      healthStub,
      [
        "#!/usr/bin/env bash",
        'attempt=0',
        '[[ -f "$VOICEBAR_HEALTH_TEST_ATTEMPTS" ]] && read -r attempt < "$VOICEBAR_HEALTH_TEST_ATTEMPTS"',
        'attempt=$((attempt + 1))',
        'printf "%s\\n" "$attempt" > "$VOICEBAR_HEALTH_TEST_ATTEMPTS"',
        "exit 1",
        "",
      ].join("\n"),
    );
    chmodSync(healthStub, 0o755);

    const result = run(
      [
        "bash",
        "-c",
        [
          'source "$1"',
          'PACKAGE_ROOT="$2"',
          "VOICEBAR_HEALTH_MAX_ATTEMPTS=3",
          "VOICEBAR_HEALTH_RETRY_DELAY_SECONDS=0",
          "verify_voicebar_hotkey_health --allow-stopped",
        ].join("; "),
        "_",
        updateScript,
        tempRoot,
      ],
      { VOICEBAR_HEALTH_TEST_ATTEMPTS: attemptFile },
    );

    expect(result.exitCode).not.toBe(0);
    expect(readFileSync(attemptFile, "utf8").trim()).toBe("3");
    expect(text(result.stderr)).toContain(
      "VoiceBar hotkey health did not become ready after 3 attempts",
    );
  });

  test("the installed VoiceBar path stays canonical despite environment overrides", () => {
    const result = run(
      [
        "bash",
        "-c",
        'source "$1"; printf "%s\\n" "$VOICEBAR_CANONICAL_APP"',
        "_",
        updateScript,
      ],
      { VOICELAYER_UPDATE_VOICEBAR_APP: "/tmp/Unexpected.app" },
    );

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout).trim()).toBe("/Applications/VoiceBar.app");
  });

  test("main completes model and data work before returning a hotkey repair failure", () => {
    const result = run([
      "bash",
      "-c",
      [
        'source "$1"',
        "parse_args() { :; }",
        "validate_args() { :; }",
        "print_plan() { :; }",
        "detect_install_type() { printf 'global-package\\n'; }",
        "voicebar_app_update_mode() { printf 'local-build\\n'; }",
        "ensure_command() { :; }",
        "update_package() { printf 'package\\n'; }",
        "update_voicebar_app() { printf 'app\\n'; }",
        "install_qwen3_model() { printf 'model\\n'; }",
        "sync_personal_data() { printf 'data\\n'; }",
        "repair_and_verify_voicebar_hotkey_path() { printf 'repair\\n'; return 1; }",
        "main",
      ].join("; "),
      "_",
      updateScript,
    ]);
    const stdout = text(result.stdout);

    expect(result.exitCode).not.toBe(0);
    expect(stdout).toContain("model");
    expect(stdout).toContain("data");
    expect(stdout.indexOf("model")).toBeLessThan(stdout.indexOf("repair"));
    expect(stdout.indexOf("data")).toBeLessThan(stdout.indexOf("repair"));
    expect(stdout).not.toContain("VoiceLayer update complete.");
  });

  test("pins mlx-audio to the 0.4 release line for Qwen3", () => {
    const body = readFileSync(updateScript, "utf8");

    expect(body).toContain('MLX_AUDIO_VERSION_SPEC="${VOICELAYER_UPDATE_MLX_AUDIO_VERSION_SPEC:-mlx-audio>=0.4,<0.5}"');
    expect(body).toContain('"$MLX_AUDIO_VERSION_SPEC" huggingface_hub');
    expect(body).not.toContain("pip install mlx-audio huggingface_hub");
  });
});
