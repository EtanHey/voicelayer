/**
 * Tests for standalone daemon (daemon.ts) — VoiceLayer without MCP.
 *
 * Verifies:
 * - Daemon uses separate PID file from MCP (coexistence)
 * - Process lock accepts configurable PID file path
 * - Daemon has zero MCP SDK imports
 * - CLI integration (voicelayer serve)
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import {
  existsSync,
  readFileSync,
  unlinkSync,
  mkdtempSync,
  mkdirSync,
  symlinkSync,
  writeFileSync,
  rmSync,
} from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { spawnSync } from "child_process";
import {
  acquireProcessLock,
  releaseProcessLock,
  MCP_PID_FILE,
} from "../process-lock";
import { DAEMON_PID_FILE } from "../paths";
import { createShutdownHandler, getServeSocketPath } from "../daemon";

// --- Helpers ---

function cleanFile(path: string) {
  if (existsSync(path)) {
    try {
      unlinkSync(path);
    } catch {}
  }
}

// --- Tests ---

describe("daemon PID coexistence", () => {
  beforeEach(() => {
    cleanFile(DAEMON_PID_FILE);
    cleanFile(MCP_PID_FILE);
  });

  afterEach(() => {
    releaseProcessLock(DAEMON_PID_FILE);
    releaseProcessLock(MCP_PID_FILE);
    cleanFile(DAEMON_PID_FILE);
    cleanFile(MCP_PID_FILE);
  });

  it("DAEMON_PID_FILE is different from MCP_PID_FILE", () => {
    expect(DAEMON_PID_FILE).not.toBe(MCP_PID_FILE);
    expect(DAEMON_PID_FILE).toContain("voicelayer-daemon");
    expect(MCP_PID_FILE).toContain("voicelayer-mcp");
  });

  it("acquires daemon lock at custom PID path", () => {
    const result = acquireProcessLock(DAEMON_PID_FILE);
    expect(result.acquired).toBe(true);
    expect(existsSync(DAEMON_PID_FILE)).toBe(true);

    const data = JSON.parse(readFileSync(DAEMON_PID_FILE, "utf-8"));
    expect(data.pid).toBe(process.pid);
  });

  it("daemon and MCP locks are independent", () => {
    const daemonResult = acquireProcessLock(DAEMON_PID_FILE);
    const mcpResult = acquireProcessLock(MCP_PID_FILE);

    expect(daemonResult.acquired).toBe(true);
    expect(mcpResult.acquired).toBe(true);

    // Both PID files exist simultaneously
    expect(existsSync(DAEMON_PID_FILE)).toBe(true);
    expect(existsSync(MCP_PID_FILE)).toBe(true);

    // Both have our PID
    const daemonData = JSON.parse(readFileSync(DAEMON_PID_FILE, "utf-8"));
    const mcpData = JSON.parse(readFileSync(MCP_PID_FILE, "utf-8"));
    expect(daemonData.pid).toBe(process.pid);
    expect(mcpData.pid).toBe(process.pid);
  });

  it("releases daemon lock without affecting MCP lock", () => {
    acquireProcessLock(DAEMON_PID_FILE);
    acquireProcessLock(MCP_PID_FILE);

    releaseProcessLock(DAEMON_PID_FILE);

    expect(existsSync(DAEMON_PID_FILE)).toBe(false);
    expect(existsSync(MCP_PID_FILE)).toBe(true); // MCP lock untouched
  });

  it("releases MCP lock without affecting daemon lock", () => {
    acquireProcessLock(DAEMON_PID_FILE);
    acquireProcessLock(MCP_PID_FILE);

    releaseProcessLock(MCP_PID_FILE);

    expect(existsSync(MCP_PID_FILE)).toBe(false);
    expect(existsSync(DAEMON_PID_FILE)).toBe(true); // Daemon lock untouched
  });

  it("default lock path is MCP (backward compat)", () => {
    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
    expect(existsSync(MCP_PID_FILE)).toBe(true);

    releaseProcessLock();
    expect(existsSync(MCP_PID_FILE)).toBe(false);
  });
});

describe("daemon has no MCP imports", () => {
  it("daemon.ts has no MCP import statements", async () => {
    const daemonSrc = await Bun.file("src/daemon.ts").text();
    // Extract only import lines (not comments)
    const importLines = daemonSrc
      .split("\n")
      .filter((line) => line.trimStart().startsWith("import "));

    const joined = importLines.join("\n");
    expect(joined).not.toContain("@modelcontextprotocol");
    expect(joined).not.toContain("mcp-daemon");
    expect(joined).not.toContain("createMcpDaemon");
    expect(joined).not.toContain("./mcp-server");
    expect(joined).not.toContain("./mcp-handler");
    expect(joined).not.toContain("./mcp-tools");
  });
});

describe("daemon shutdown", () => {
  it("releases the PID lock and disconnects exactly once on repeated shutdown signals", () => {
    const calls: string[] = [];
    const shutdown = createShutdownHandler({
      disconnect: () => calls.push("disconnect"),
      releaseLock: () => calls.push("releaseLock"),
      exit: (code) => calls.push(`exit:${code}`),
    });

    shutdown();
    shutdown();

    expect(calls).toEqual(["disconnect", "releaseLock", "exit:0"]);
  });
});

describe("daemon socket path", () => {
  it("defaults to VoiceBar's well-known socket", () => {
    const saved = process.env.QA_VOICE_SOCKET_PATH;
    delete process.env.QA_VOICE_SOCKET_PATH;
    try {
      expect(getServeSocketPath()).toBeUndefined();
    } finally {
      if (saved) process.env.QA_VOICE_SOCKET_PATH = saved;
    }
  });

  it("allows overriding the socket path for isolated verification", () => {
    const saved = process.env.QA_VOICE_SOCKET_PATH;
    process.env.QA_VOICE_SOCKET_PATH = "/tmp/voicelayer-test.sock";
    try {
      expect(getServeSocketPath()).toBe("/tmp/voicelayer-test.sock");
    } finally {
      if (saved) process.env.QA_VOICE_SOCKET_PATH = saved;
      else delete process.env.QA_VOICE_SOCKET_PATH;
    }
  });
});

describe("CLI integration", () => {
  it("voicelayer.sh includes serve command", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).toContain("serve)");
    expect(cliSrc).toContain("daemon.ts");
  });

  it("voicelayer.sh launches the canonical app and builds only through build-app", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).not.toMatch(/SCRIPT_DIR=.*\n\nFLOW_BAR_DIR=.*\n\ncase/s);
    expect(cliSrc).toContain("build-app)");
    expect(cliSrc).toContain('bash "$PACKAGE_ROOT/flow-bar/build-app.sh"');
    expect(cliSrc).toContain('open "/Applications/VoiceBar.app"');
    expect(cliSrc).not.toContain('exec ".build/release/VoiceBar"');
  });

  it("voicelayer.sh help includes serve command", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).toContain("serve");
    // Help text should mention standalone
    expect(cliSrc).toMatch(/serve.*[Ss]tandalone|serve.*daemon|serve.*without/);
  });

  it("voicelayer.sh exposes packaged hotkey installer", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).toContain("hotkey)");
    expect(cliSrc).toContain("install-voicebar-f5-hidutil.sh");
    expect(cliSrc).toContain("voicelayer hotkey install");
  });

  it("voicelayer.sh exposes the STT vocabulary command group", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).toContain("vocab)");
    expect(cliSrc).toContain("vocab.ts");
    expect(cliSrc).toContain("voicelayer vocab add --wrong");
  });

  it("package includes VoiceBar and hidutil assets for global install", async () => {
    const packageJson = await Bun.file("package.json").json();
    expect(packageJson.files).toContain("src/**/*.py");
    expect(packageJson.files).toContain("flow-bar/Package.swift");
    expect(packageJson.files).toContain("flow-bar/build-app.sh");
    expect(packageJson.files).toContain("flow-bar/Sources/");
    expect(packageJson.files).toContain("flow-bar/Tests/");
    expect(packageJson.files).toContain("launchd/");
    expect(packageJson.files).toContain("scripts/");
    expect(packageJson.files).toContain("!scripts/__pycache__/**");
  });

  it("hidutil helper emits BOTH F5->F18 and Dictation->F18, preserving unrelated mappings", () => {
    // VoiceBar must remap BOTH the physical F5 and the Dictation consumer key to
    // F18 so a bare F5 press survives reboots instead of falling through to
    // macOS Dictation. Any prior VoiceBar F5 -> F18 entry is replaced (not
    // duplicated), and mappings on OTHER keys (e.g. CapsLock -> Esc) survive.
    const result = spawnSync("bash", ["scripts/apply-voicebar-f5-hidutil.sh"], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        VOICELAYER_HIDUTIL_DRY_RUN: "1",
        VOICELAYER_HIDUTIL_JS_RUNTIME: "node",
        VOICELAYER_HIDUTIL_CURRENT_MAPPING: JSON.stringify([
          {
            // Unrelated user mapping (e.g. CapsLock -> Esc) — preserved.
            HIDKeyboardModifierMappingSrc: 123,
            HIDKeyboardModifierMappingDst: 456,
          },
          {
            // Stale VoiceBar F5 -> F18 (Src=F5, Dst=F18) — replaced, not duped.
            HIDKeyboardModifierMappingSrc: 30064771134,
            HIDKeyboardModifierMappingDst: 30064771181,
          },
        ]),
      },
      encoding: "utf8",
      timeout: 10_000,
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    expect(merged.UserKeyMapping).toEqual([
      {
        HIDKeyboardModifierMappingSrc: 123,
        HIDKeyboardModifierMappingDst: 456,
      },
      {
        // F5 -> F18 restored (the reboot-survival fix).
        HIDKeyboardModifierMappingSrc: 30064771134,
        HIDKeyboardModifierMappingDst: 30064771181,
      },
      {
        HIDKeyboardModifierMappingSrc: 51539607759,
        HIDKeyboardModifierMappingDst: 30064771181,
      },
    ]);
    // No duplicate Src entries.
    const srcs = merged.UserKeyMapping.map(
      (e: { HIDKeyboardModifierMappingSrc: number }) =>
        e.HIDKeyboardModifierMappingSrc,
    );
    expect(new Set(srcs).size).toBe(srcs.length);
  }, 15_000);

  it("hidutil helper output has both Src keys -> F18 and ZERO null entries", () => {
    // Core reboot-survival contract (brief 2026-07-01): the merged payload must
    // contain BOTH F5 (30064771134) and Dictation (51539607759) mapped to F18
    // (30064771181), and no entry may have a null Src or Dst — the old JXA merge
    // regressed to `{Src: null, Dst: null}` which set UserKeyMapping to (null).
    const F5_SRC = 30064771134;
    const DICTATION_SRC = 51539607759;
    const F18_DST = 30064771181;
    const result = spawnSync("bash", ["scripts/apply-voicebar-f5-hidutil.sh"], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        VOICELAYER_HIDUTIL_DRY_RUN: "1",
        VOICELAYER_HIDUTIL_JS_RUNTIME: "node",
        VOICELAYER_HIDUTIL_CURRENT_MAPPING: JSON.stringify([]),
      },
      encoding: "utf8",
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    const entries: Array<{
      HIDKeyboardModifierMappingSrc: number;
      HIDKeyboardModifierMappingDst: number;
    }> = merged.UserKeyMapping;
    // Zero null Src/Dst anywhere.
    for (const e of entries) {
      expect(e.HIDKeyboardModifierMappingSrc).not.toBeNull();
      expect(e.HIDKeyboardModifierMappingDst).not.toBeNull();
      expect(typeof e.HIDKeyboardModifierMappingSrc).toBe("number");
      expect(typeof e.HIDKeyboardModifierMappingDst).toBe("number");
    }
    // Both source keys map to F18.
    expect(entries).toContainEqual({
      HIDKeyboardModifierMappingSrc: F5_SRC,
      HIDKeyboardModifierMappingDst: F18_DST,
    });
    expect(entries).toContainEqual({
      HIDKeyboardModifierMappingSrc: DICTATION_SRC,
      HIDKeyboardModifierMappingDst: F18_DST,
    });
  }, 15_000);

  // Regression: on a machine with NO existing mapping — i.e. EVERY FRESH BOOT —
  // `hidutil property --get UserKeyMapping` prints the literal string `(null)`,
  // which is neither plist nor JSON. That reached the JSON parser and the merge
  // died with "JSON Parse error: Unexpected token '('", so the F5 -> F18 relay
  // was never applied. The LaunchAgent still exited 0, making it silent: F5
  // worked all day and broke on every restart.
  it("hidutil helper applies the relay from a fresh boot, where hidutil prints (null)", () => {
    const F5_SRC = 30064771134;
    const DICTATION_SRC = 51539607759;
    const F18_DST = 30064771181;

    for (const emptyish of ["(null)", "", "   ", "not json at all"]) {
      const result = spawnSync(
        "bash",
        ["scripts/apply-voicebar-f5-hidutil.sh"],
        {
          cwd: process.cwd(),
          env: {
            ...process.env,
            VOICELAYER_HIDUTIL_DRY_RUN: "1",
            VOICELAYER_HIDUTIL_JS_RUNTIME: "node",
            VOICELAYER_HIDUTIL_CURRENT_MAPPING: emptyish,
          },
          encoding: "utf8",
        },
      );

      expect(result.status).toBe(0);
      const entries = JSON.parse(result.stdout).UserKeyMapping;
      expect(entries).toContainEqual({
        HIDKeyboardModifierMappingSrc: F5_SRC,
        HIDKeyboardModifierMappingDst: F18_DST,
      });
      expect(entries).toContainEqual({
        HIDKeyboardModifierMappingSrc: DICTATION_SRC,
        HIDKeyboardModifierMappingDst: F18_DST,
      });
    }
  }, 20_000);

  it("hidutil helper reclaims F5 for VoiceBar while non-F5 keys survive", () => {
    // VoiceBar owns the physical F5 key: any prior F5 -> anything (e.g. a stray
    // F5 -> CapsLock) is reclaimed as F5 -> F18 with no duplicate F5 Src, so a
    // bare F5 always reaches VoiceBar after login. A mapping on a DIFFERENT key
    // (CapsLock -> Esc) is untouched.
    const result = spawnSync("bash", ["scripts/apply-voicebar-f5-hidutil.sh"], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        VOICELAYER_HIDUTIL_DRY_RUN: "1",
        VOICELAYER_HIDUTIL_JS_RUNTIME: "node",
        VOICELAYER_HIDUTIL_CURRENT_MAPPING: JSON.stringify([
          {
            // Stray F5 -> CapsLock (0x700000039 = 30064771129) — reclaimed.
            HIDKeyboardModifierMappingSrc: 30064771134,
            HIDKeyboardModifierMappingDst: 30064771129,
          },
          {
            // Unrelated CapsLock -> Esc — survives (Src is not F5/Dictation).
            HIDKeyboardModifierMappingSrc: 30064771129,
            HIDKeyboardModifierMappingDst: 30064771113,
          },
        ]),
      },
      encoding: "utf8",
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    expect(merged.UserKeyMapping).toEqual([
      {
        // Unrelated CapsLock -> Esc survives.
        HIDKeyboardModifierMappingSrc: 30064771129,
        HIDKeyboardModifierMappingDst: 30064771113,
      },
      {
        // F5 reclaimed for VoiceBar (single F5 Src entry).
        HIDKeyboardModifierMappingSrc: 30064771134,
        HIDKeyboardModifierMappingDst: 30064771181,
      },
      {
        HIDKeyboardModifierMappingSrc: 51539607759,
        HIDKeyboardModifierMappingDst: 30064771181,
      },
    ]);
  });

  it("hidutil helper normalizes string-valued preserved entries to numbers", () => {
    // `hidutil property --get UserKeyMapping | plutil -convert json` can emit
    // existing HID values as strings on some macOS versions. The final
    // `hidutil property --set` expects numeric Src/Dst, so the helper must
    // coerce preserved entries through Number() before stringifying — otherwise
    // machines with pre-existing remaps get a mixed string/number payload and
    // the merge either fails or silently drops the preserved mappings. This
    // includes user-owned F5 remaps that aren't to F18 (they survive the
    // pair-shape filter), so we verify coercion on both preserved rows.
    const result = spawnSync("bash", ["scripts/apply-voicebar-f5-hidutil.sh"], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        VOICELAYER_HIDUTIL_DRY_RUN: "1",
        VOICELAYER_HIDUTIL_JS_RUNTIME: "node",
        VOICELAYER_HIDUTIL_CURRENT_MAPPING: JSON.stringify([
          {
            // Unrelated string-valued mapping — survives and must be coerced.
            HIDKeyboardModifierMappingSrc: "12345",
            HIDKeyboardModifierMappingDst: "67890",
          },
          {
            // String F5 src — reclaimed by VoiceBar as F5 -> F18 (not preserved).
            HIDKeyboardModifierMappingSrc: "30064771134",
            HIDKeyboardModifierMappingDst: "999",
          },
        ]),
      },
      encoding: "utf8",
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    // 3 entries: unrelated preserved (coerced) + F5 -> F18 + Dictation -> F18.
    expect(merged.UserKeyMapping).toHaveLength(3);
    // Preserved unrelated entry: string fixture must come out as numbers.
    expect(merged.UserKeyMapping[0]).toEqual({
      HIDKeyboardModifierMappingSrc: 12345,
      HIDKeyboardModifierMappingDst: 67890,
    });
    expect(typeof merged.UserKeyMapping[0].HIDKeyboardModifierMappingSrc).toBe(
      "number",
    );
    expect(typeof merged.UserKeyMapping[0].HIDKeyboardModifierMappingDst).toBe(
      "number",
    );
    // F5 reclaimed as F5 -> F18 (numeric), replacing the stale F5 -> 999.
    expect(merged.UserKeyMapping[1]).toEqual({
      HIDKeyboardModifierMappingSrc: 30064771134,
      HIDKeyboardModifierMappingDst: 30064771181,
    });
    expect(typeof merged.UserKeyMapping[1].HIDKeyboardModifierMappingSrc).toBe(
      "number",
    );
    // VoiceBar Dictation entry — always numeric.
    expect(merged.UserKeyMapping[2]).toEqual({
      HIDKeyboardModifierMappingSrc: 51539607759,
      HIDKeyboardModifierMappingDst: 30064771181,
    });
  });

  it("voicelayer.sh resolves PACKAGE_ROOT through bin-symlinks (global install)", () => {
    // Reproduces `bun add -g`/`npm i -g` layout where the bin in $PATH is a
    // symlink in the package manager's bin dir pointing at src/cli/voicelayer.sh
    // inside the installed package. Without symlink resolution, ${BASH_SOURCE[0]}
    // is the symlink and PACKAGE_ROOT becomes the bin dir's grandparent — not
    // the package — so `voicelayer hotkey install` fails to find scripts/...
    const repoRoot = resolve(process.cwd());
    const realScript = join(repoRoot, "src/cli/voicelayer.sh");
    expect(existsSync(realScript)).toBe(true);

    const tmp = mkdtempSync(join(tmpdir(), "voicelayer-symlink-"));
    const symPath = join(tmp, "voicelayer");
    symlinkSync(realScript, symPath);

    try {
      const result = spawnSync("bash", [symPath], {
        env: {
          ...process.env,
          VOICELAYER_DEBUG_PACKAGE_ROOT: "1",
        },
        encoding: "utf8",
      });

      expect(result.status).toBe(0);
      expect(result.stdout.trim()).toBe(repoRoot);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("voicelayer daemon prefers the VoiceLayer venv Python", () => {
    const tmp = mkdtempSync(join(tmpdir(), "voicelayer-tts-python-"));
    const fakeHome = join(tmp, "home");
    const venvBin = join(fakeHome, ".voicelayer", "venv", "bin");
    mkdirSync(venvBin, { recursive: true });
    writeFileSync(join(venvBin, "python"), "#!/usr/bin/env bash\nexit 0\n");
    spawnSync("chmod", ["755", join(venvBin, "python")]);

    try {
      const result = spawnSync("bash", ["src/cli/voicelayer.sh", "daemon"], {
        env: {
          ...process.env,
          HOME: fakeHome,
          VOICELAYER_DEBUG_TTS_PYTHON: "1",
        },
        encoding: "utf8",
      });

      expect(result.status).toBe(0);
      expect(result.stdout.trim()).toBe(join(venvBin, "python"));
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("voicelayer daemon falls back to bare python3 when the venv is missing", () => {
    const tmp = mkdtempSync(join(tmpdir(), "voicelayer-tts-python-"));
    const fakeHome = join(tmp, "home");
    mkdirSync(fakeHome, { recursive: true });

    try {
      const result = spawnSync("bash", ["src/cli/voicelayer.sh", "daemon"], {
        env: {
          ...process.env,
          HOME: fakeHome,
          VOICELAYER_DEBUG_TTS_PYTHON: "1",
        },
        encoding: "utf8",
      });

      expect(result.status).toBe(0);
      expect(result.stdout.trim()).toBe("python3");
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  it("voicelayer daemon respects VOICELAYER_TTS_PYTHON override", () => {
    const tmp = mkdtempSync(join(tmpdir(), "voicelayer-tts-python-"));
    const fakeHome = join(tmp, "home");
    const customBin = join(tmp, "custom");
    const customPython = join(customBin, "python");
    mkdirSync(fakeHome, { recursive: true });
    mkdirSync(customBin, { recursive: true });
    writeFileSync(customPython, "#!/usr/bin/env bash\nexit 0\n");
    spawnSync("chmod", ["755", customPython]);

    try {
      const result = spawnSync("bash", ["src/cli/voicelayer.sh", "daemon"], {
        env: {
          ...process.env,
          HOME: fakeHome,
          VOICELAYER_TTS_PYTHON: customPython,
          VOICELAYER_DEBUG_TTS_PYTHON: "1",
        },
        encoding: "utf8",
      });

      expect(result.status).toBe(0);
      expect(result.stdout.trim()).toBe(customPython);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });
});
