import * as W from "../../whisper-server";
const { __setWhisperServerTestHooksForTests: hooks, ensureServer, shutdownWhisperServer } = W as any;
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

const row = process.argv[2];
const signals = fixture({ neverHealthy: row === "startup" });
if (row === "startup") {
  const pending = ensureServer(18908).catch(() => {});
  await Bun.sleep(40);
  await shutdownWhisperServer();
  await pending;
} else {
  await ensureServer(row === "exit" ? 18903 : 18904);
  for (const listener of process.listeners(row === "exit" ? "exit" : "SIGTERM")) {
    (listener as any)(row === "exit" ? 0 : "SIGTERM");
  }
}
console.log(JSON.stringify(signals));
