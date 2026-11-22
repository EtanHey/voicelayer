import { test, expect, afterEach } from "bun:test";
import * as W from "../whisper-server";
const { __resetWhisperServerStateForTests: reset, __setWhisperServerTestHooksForTests: hooks, ensureServer, stopServer, stopServerAndWait, unloadOwnedServer, shutdownWhisperServer } = W as any;
const prevIdle = process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
afterEach(() => { reset(null); hooks({}); if (prevIdle === undefined) delete process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS; else process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = prevIdle; });
function fixture(opts: { neverHealthy?: boolean } = {}) {
  let healthy = false; const signals: string[] = [];
  hooks({
    findServerBinary: () => "/fixture/whisper-server", findModel: () => "/fixture/model.bin",
    isServerHealthy: async () => healthy, isPidAlive: () => healthy, processStartTimeMs: () => Date.now() - 1000,
    findPortListenerPids: () => healthy ? [55120] : [], postUnloadListeners: () => [], findExternalWhisperServerPids: () => [],
    reserveVoiceMaintenance: () => () => {}, startupTimeoutMs: 300, sleep: (ms: number) => Bun.sleep(Math.min(ms, 20)),
    spawn: () => { if (!opts.neverHealthy) healthy = true; let ex!: (c: number) => void; const exited = new Promise<number>(r => { ex = r; });
      return { pid: 55120, exited, exitCode: null, kill: (s?: string) => { signals.push(s ?? "SIGTERM"); healthy = false; ex(137); } }; },
  });
  return signals;
}
const rows: Record<string, string> = {};
afterEach(() => {});
test("normal stop", async () => { const s = fixture(); await ensureServer(18901); stopServer(); await Bun.sleep(5); rows.normal = JSON.stringify(s); expect(s).toEqual(["SIGKILL"]); });
test("stopServerAndWait", async () => { const s = fixture(); await ensureServer(18902); await stopServerAndWait(); rows.wait = JSON.stringify(s); expect(s).toEqual(["SIGKILL"]); });
test("exit handler", async () => { const s = fixture(); await ensureServer(18903); const ls = process.listeners("exit"); for (const l of ls) { try { (l as any)(0); } catch {} } rows.exit = JSON.stringify(s); expect(s).toEqual(["SIGKILL"]); });
test("SIGTERM handler", async () => { const s = fixture(); await ensureServer(18904); for (const l of process.listeners("SIGTERM")) { try { (l as any)("SIGTERM"); } catch {} } rows.sigterm = JSON.stringify(s); expect(s).toEqual(["SIGKILL"]); });
test("socket unload", async () => { const s = fixture(); await ensureServer(18905); const r = await unloadOwnedServer(() => false); rows.socket = JSON.stringify([s, r]); expect(s).toEqual(["SIGKILL"]); });
test("idle unload", async () => { process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = "0.02"; const s = fixture(); await ensureServer(18906); for (let i = 0; i < 200 && s.length === 0; i++) await Bun.sleep(10); await Bun.sleep(50); rows.idle = JSON.stringify(s); expect(s).toEqual(["SIGKILL"]); });
test("failed launch", async () => { const s = fixture({ neverHealthy: true }); let err = ""; try { await ensureServer(18907); } catch (e) { err = String(e); } rows.failed = JSON.stringify([s, err.slice(0, 80)]); expect(s.length).toBeGreaterThan(0); expect(s.every(x => x === "SIGKILL")).toBe(true); });
test("startup shutdown (last: aborts module owner)", async () => { const s = fixture({ neverHealthy: true }); const p = ensureServer(18908).catch((e: any) => String(e)); await Bun.sleep(40); let err = ""; try { await shutdownWhisperServer(); } catch (e) { err = String(e); } await p; rows.startup = JSON.stringify([s, err]); expect(s.length).toBeGreaterThan(0); expect(s.every(x => x === "SIGKILL")).toBe(true); });
test("print", () => { console.error("MATRIX", JSON.stringify(rows, null, 1)); });
