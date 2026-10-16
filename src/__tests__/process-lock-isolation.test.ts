import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";

// One bounded child probe per case, plus parent-side fixture/setup time.
const PID_PROBE_TIMEOUT_MS = 15_000;
const PID_TEST_TIMEOUT_MS = PID_PROBE_TIMEOUT_MS + 5_000;

describe("TEST3 PID lock isolation", () => {
  it("redirects the default and blocks the old constant before reads, writes or signals", () => {
    const dir = mkdtempSync(join(TEST_TMP, "pid-guard-"));
    try {
      // Substitute ONLY the production constant in a copy. On RED the old
      // import really writes this sandbox file, never the live /tmp PID file.
      const sandbox = join(dir, "sandbox-live.pid");
      const sentinel = JSON.stringify({ pid: 1, startedAt: "synthetic sentinel" });
      writeFileSync(sandbox, sentinel);
      const source = readFileSync(join(import.meta.dir, "..", "process-lock.ts"), "utf8")
        .replace('"/tmp/voicelayer-mcp.pid"', JSON.stringify(sandbox))
        .replace('"./paths"', JSON.stringify(join(import.meta.dir, "..", "paths.ts")));
      const modulePath = join(dir, "process-lock.ts");
      writeFileSync(modulePath, source);
      const script = `
        import { readFileSync, existsSync, symlinkSync } from "fs";
        import { join } from "path";
        const lock = await import(${JSON.stringify(modulePath)});
        const expected = join(process.env.VOICELAYER_TEST_RUN_ROOT, "voicelayer-mcp.pid");
        const configured = lock.getMcpPidFilePath();
        let signals = 0;
        process.kill = () => { signals++; throw new Error("sandbox signal sentinel"); };
        const blocked = (fn) => { try { fn(); return false; } catch (e) { return /test.*PID lock/i.test(e.message); } };
        const acquireBlocked = blocked(() => lock.acquireProcessLock(lock.MCP_PID_FILE));
        const releaseBlocked = blocked(() => lock.releaseProcessLock(lock.MCP_PID_FILE));
        const traversalBlocked = blocked(() => lock.acquireProcessLock(join(process.env.VOICELAYER_TEST_RUN_ROOT, "..", "escape.pid")));
        const link = join(process.env.VOICELAYER_TEST_RUN_ROOT, "escape");
        symlinkSync(${JSON.stringify(dir)}, link);
        const symlinkBlocked = blocked(() => lock.acquireProcessLock(join(link, "linked.pid")));
        let ownPid = null;
        if (configured === expected) {
          lock.acquireProcessLock();
          ownPid = JSON.parse(readFileSync(expected, "utf8")).pid;
          lock.releaseProcessLock();
        }
        console.log(JSON.stringify({ configured, expected, acquireBlocked, releaseBlocked,
          traversalBlocked, symlinkBlocked, signals, ownPid, pid: process.pid,
          auxiliaryPaths: ["QA_VOICE_STT_VOCABULARY_PATH", "QA_VOICE_STT_COMMANDS_DIR", "VOICELAYER_WHISPER_OWNERSHIP_DIR",
            "QA_VOICE_STT_POLISH_LOG_PATH", "QA_VOICE_STT_POLISH_SOCKET", "QA_VOICE_WISPR_DB_PATH"]
            .map(key => process.env[key]),
          sandboxUnchanged: readFileSync(lock.MCP_PID_FILE, "utf8") === ${JSON.stringify(sentinel)},
          released: !existsSync(expected) }));
      `;
      const env = { ...process.env };
      for (const key of ["QA_VOICE_STT_VOCABULARY_PATH", "QA_VOICE_STT_COMMANDS_DIR", "VOICELAYER_WHISPER_OWNERSHIP_DIR",
        "QA_VOICE_STT_POLISH_LOG_PATH", "QA_VOICE_STT_POLISH_SOCKET", "QA_VOICE_WISPR_DB_PATH"]) {
        delete env[key];
      }
      // Even a hostile/inherited override must not escape the child's run.
      env.QA_VOICE_MCP_PID_PATH = sandbox;
      const result = Bun.spawnSync([
        process.execPath, "--preload", join(import.meta.dir, "setup", "preload.ts"), "-e", script,
      ], { env, stdout: "pipe", stderr: "pipe", timeout: PID_PROBE_TIMEOUT_MS });
      expect(result.exitCode).toBe(0);
      const report = JSON.parse(new TextDecoder().decode(result.stdout).trim());
      expect(report.configured).toBe(report.expected);
      expect(report.acquireBlocked).toBe(true);
      expect(report.releaseBlocked).toBe(true);
      expect(report.traversalBlocked).toBe(true);
      expect(report.symlinkBlocked).toBe(true);
      expect(report.signals).toBe(0);
      expect(report.sandboxUnchanged).toBe(true);
      expect(report.ownPid).toBe(report.pid);
      expect(report.released).toBe(true);
      for (const path of report.auxiliaryPaths) {
        expect(path).toStartWith(report.expected.slice(0, -"voicelayer-mcp.pid".length));
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, PID_TEST_TIMEOUT_MS);

  it("fails closed in test mode without a preload root; keeps product defaults", () => {
    const sandbox = join(TEST_TMP, "missing-preload.pid");
    const script = `
      delete process.env.VOICELAYER_TEST_RUN_ROOT;
      process.env.NODE_ENV = "test";
      const lock = await import(${JSON.stringify(join(import.meta.dir, "..", "process-lock.ts"))});
      let blocked = false;
      try { lock.acquireProcessLock(${JSON.stringify(sandbox)}); }
      catch (e) { blocked = /test.*PID lock/i.test(e.message); }
      console.log(JSON.stringify({ blocked, productDefault: lock.getMcpPidFilePath({}) }));
    `;
    const result = Bun.spawnSync([
      process.execPath, "--preload", join(import.meta.dir, "setup", "preload.ts"), "-e", script,
    ], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: PID_PROBE_TIMEOUT_MS });
    expect(result.exitCode).toBe(0);
    expect(JSON.parse(new TextDecoder().decode(result.stdout).trim())).toEqual({
      blocked: true, productDefault: "/tmp/voicelayer-mcp.pid",
    });
  }, PID_TEST_TIMEOUT_MS);
});
