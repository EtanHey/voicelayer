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
  symlinkSync,
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

  it("voicelayer.sh resolves flow-bar only inside the bar command", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).not.toMatch(/SCRIPT_DIR=.*\n\nFLOW_BAR_DIR=.*\n\ncase/s);
    expect(cliSrc).toMatch(
      /bar\)\n[\s\S]*FLOW_BAR_DIR=.*\n[\s\S]*swift build/s,
    );
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

  it("package includes VoiceBar and hidutil assets for global install", async () => {
    const packageJson = await Bun.file("package.json").json();
    expect(packageJson.files).toContain("src/**/*.py");
    expect(packageJson.files).toContain("flow-bar/Package.swift");
    expect(packageJson.files).toContain("flow-bar/Sources/");
    expect(packageJson.files).toContain("flow-bar/Tests/");
    expect(packageJson.files).toContain("launchd/");
    expect(packageJson.files).toContain("scripts/");
    expect(packageJson.files).toContain("!scripts/__pycache__/**");
  });

  it("hidutil helper strips only the stale VoiceBar F5->F18 shape and pushes Dictation", () => {
    // Filter must be pair-based, not source-only: a user may have remapped
    // physical F5 to something unrelated (CapsLock, etc.) and we must
    // preserve that. Only the EXACT stale VoiceBar shape (F5 -> F18) gets
    // removed. Dictation -> F18 is always pushed because VoiceBar's HID-layer
    // promotion of the consumer key is required for VoiceBar to work.
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
            // Stale VoiceBar F5 -> F18 (Src=F5, Dst=F18) — must be removed.
            HIDKeyboardModifierMappingSrc: 30064771134,
            HIDKeyboardModifierMappingDst: 30064771181,
          },
        ]),
      },
      encoding: "utf8",
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    expect(merged.UserKeyMapping).toEqual([
      {
        HIDKeyboardModifierMappingSrc: 123,
        HIDKeyboardModifierMappingDst: 456,
      },
      {
        HIDKeyboardModifierMappingSrc: 51539607759,
        HIDKeyboardModifierMappingDst: 30064771181,
      },
    ]);
  });

  it("hidutil helper preserves user-owned F5 remaps that aren't to F18", () => {
    // Regression guard for Codex P2 on 84608d7: a source-only filter strips
    // *all* user F5 mappings whenever the LaunchAgent runs, even unrelated
    // remaps like F5 -> CapsLock. Only the exact VoiceBar shape (F5 -> F18)
    // is owned by us; anything else must survive.
    const result = spawnSync("bash", ["scripts/apply-voicebar-f5-hidutil.sh"], {
      cwd: process.cwd(),
      env: {
        ...process.env,
        VOICELAYER_HIDUTIL_DRY_RUN: "1",
        VOICELAYER_HIDUTIL_JS_RUNTIME: "node",
        VOICELAYER_HIDUTIL_CURRENT_MAPPING: JSON.stringify([
          {
            // User-owned F5 -> CapsLock (0x700000039 = 30064771129).
            HIDKeyboardModifierMappingSrc: 30064771134,
            HIDKeyboardModifierMappingDst: 30064771129,
          },
        ]),
      },
      encoding: "utf8",
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    expect(merged.UserKeyMapping).toEqual([
      {
        // User's F5 -> CapsLock survives because Dst != F18.
        HIDKeyboardModifierMappingSrc: 30064771134,
        HIDKeyboardModifierMappingDst: 30064771129,
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
            HIDKeyboardModifierMappingSrc: "12345",
            HIDKeyboardModifierMappingDst: "67890",
          },
          {
            // String F5 src with Dst != F18 — survives the pair-shape filter
            // (user-owned mapping). Must be coerced to numbers.
            HIDKeyboardModifierMappingSrc: "30064771134",
            HIDKeyboardModifierMappingDst: "999",
          },
        ]),
      },
      encoding: "utf8",
    });

    expect(result.status).toBe(0);
    const merged = JSON.parse(result.stdout);
    // 3 entries: both preserved (coerced) + Dictation -> F18.
    expect(merged.UserKeyMapping).toHaveLength(3);
    // First preserved entry: string fixture must come out as numbers.
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
    // Second preserved entry: user-owned F5 -> 999, also coerced.
    expect(merged.UserKeyMapping[1]).toEqual({
      HIDKeyboardModifierMappingSrc: 30064771134,
      HIDKeyboardModifierMappingDst: 999,
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
});
