import { test, expect, spyOn } from "bun:test";
import { __resetWhisperServerStateForTests, __setWhisperServerTestHooksForTests, ensureServer, transcribeViaServer, stopServer, stopServerAndWait } from "../whisper-server";

function setup() {
  let healthy = false; const signals: string[] = []; let exits!: (c: number) => void; let autoExit = true;
  const inference = Promise.withResolvers<Response>();
  const fetchMock = spyOn(globalThis, "fetch").mockImplementation(() => inference.promise);
  __setWhisperServerTestHooksForTests({
    findServerBinary: () => "/fixture/whisper-server", findModel: () => "/fixture/model.bin",
    isServerHealthy: async () => healthy, isPidAlive: () => healthy,
    processStartTimeMs: () => Date.now() - 1000,
    findPortListenerPids: () => healthy ? [55112] : [], postUnloadListeners: () => healthy ? [55112] : [],
    reserveVoiceMaintenance: () => () => {},
    spawn: () => { healthy = true; return { pid: 55112, kill: (s?: string) => { signals.push(s ?? "SIGTERM"); healthy = false; if (autoExit) exits(0); }, exited: new Promise<number>(r => { exits = r; }) }; },
  } as any);
  return { signals, inference, holdExit: () => { autoExit = false; }, exit: () => exits(0), cleanup: () => { fetchMock.mockRestore(); __resetWhisperServerStateForTests(null); __setWhisperServerTestHooksForTests({}); } };
}

test("process-exit stop synchronously SIGKILLs during an active transcription", async () => {
  const s = setup();
  try {
    await ensureServer(18890);
    const pending = transcribeViaServer(new Uint8Array(44), 18890);
    await Bun.sleep(20);
    stopServer(true); // what process.on("exit") runs; nothing async runs after this on real exit
    console.error("P1 signals after exit-handler stopServer:", JSON.stringify(s.signals));
    expect(s.signals).toEqual(["SIGKILL"]);
    s.inference.resolve(Response.json({ text: "hi" }));
    await pending;
    console.error("P1 signals after drain:", JSON.stringify(s.signals));
  } finally { s.cleanup(); }
});

test("P2 stopServerAndWait waits for the active request, then SIGKILLs only after it returns", async () => {
  const s = setup();
  try {
    await ensureServer(18891);
    const pending = transcribeViaServer(new Uint8Array(44), 18891);
    await Bun.sleep(20);
    let done = false; const stop = stopServerAndWait().then(() => { done = true; });
    await Bun.sleep(200);
    console.error("P2 after 200ms: done", done, "signals", JSON.stringify(s.signals));
    expect(done).toBe(false); expect(s.signals).toEqual([]);
    s.inference.resolve(Response.json({ text: "kept" }));
    expect(await pending).toBe("kept");
    await stop;
    console.error("P2 after drain: signals", JSON.stringify(s.signals));
    expect(s.signals).toEqual(["SIGKILL"]);
  } finally { s.cleanup(); }
});

test("deferred stop plus waiter waits for confirmed child exit", async () => {
  const s = setup();
  try {
    await ensureServer(18892);
    const pending = transcribeViaServer(new Uint8Array(44), 18892);
    await Bun.sleep(20);
    s.holdExit();
    stopServer(); // e.g. SIGTERM handler in this module (deferred)
    let done = false;
    const stop = stopServerAndWait().then(() => { done = true; });
    s.inference.resolve(Response.json({ text: "x" }));
    await pending;
    await Bun.sleep(20);
    expect(done).toBe(false);
    expect(s.signals).toEqual(["SIGKILL"]);
    s.exit();
    await stop;
    console.error("P3 signals", JSON.stringify(s.signals));
  } finally { s.cleanup(); }
});
