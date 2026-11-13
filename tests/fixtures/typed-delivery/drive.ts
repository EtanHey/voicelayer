// bun tests/fixtures/typed-delivery/drive.ts <fixture dir> <plan binary> <out.json> [--real|--bridge <post binary> <chrome pid>]
// --bridge: the post binary runs ListAwareTyping (the fix) with the real AX reader on the browser pid;
// every batch it posts comes back here and is replayed over CDP before the harness is acknowledged.
// --real: instead of CDP key events, the post binary (VoiceBar's SynthesizedKeyEvents, postToPid) types
// the transcript into the agent browser's pid with real CGEvents. CDP only focuses editors and reads them.
// Replays VoiceBar's keystroke plan (from the plan binary, built from SynthesizedTyping.swift) into each
// fixture editor over CDP on the agent browser (Chrome Beta, 127.0.0.1:9333) and records the editor's
// resulting text, exactly, against the transcript. Text runs go in as a key-down + IME-style commit
// (Chromium's path for a multi-character Unicode key event); a newline is Shift+Return.
import { resolve } from "node:path";
const [fixtureDir, planBin, outPath] = Bun.argv.slice(2);
const realIdx = Bun.argv.indexOf("--real");
const real = realIdx > 0 ? { bin: Bun.argv[realIdx + 1], pid: Bun.argv[realIdx + 2] } : null;
const bridgeIdx = Bun.argv.indexOf("--bridge");
const bridge = bridgeIdx > 0 ? { bin: Bun.argv[bridgeIdx + 1], pid: Bun.argv[bridgeIdx + 2] } : null;
const bridgeLogs: string[] = [];
async function runBridge(text: string) {
  const fifo = resolve(fixtureDir, `ack-${process.pid}.fifo`);
  Bun.spawnSync(["rm", "-f", fifo], { env: process.env });
  Bun.spawnSync(["mkfifo", fifo], { env: process.env });
  const child = Bun.spawn([bridge!.bin, "--bridge", bridge!.pid], {
    stdin: new TextEncoder().encode(text), stdout: "pipe", stderr: "pipe", env: { ...process.env, T7_ACK_FIFO: fifo },
  });
  const reader = child.stdout.getReader();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += new TextDecoder().decode(value);
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl); buf = buf.slice(nl + 1);
      await replay(JSON.parse(line));
      const { openSync, writeSync, closeSync } = await import("node:fs");
      const fd = openSync(fifo, "w"); writeSync(fd, "ok\n"); closeSync(fd);
    }
  }
  await child.exited;
  Bun.spawnSync(["rm", "-f", fifo], { env: process.env });
  const err = await new Response(child.stderr).text();
  bridgeLogs.push(err.trim());
  return err.trim();
}
const CDP = process.env.CDP_URL ?? "http://127.0.0.1:9333";

export const INPUTS: Record<string, string> = {
  numbered: "Here's a list of things:\n1. Buy milk and eggs\n2. Call the plumber today\n3. Book the flights",
  bullets: "Packing list:\n- Passport and tickets\n- Phone charger\n- Sunglasses",
  "plain-multiline": "First line of the note.\nSecond line follows here.\nThird line ends it.",
  "single-line": "Just one line of dictated text, nothing else.",
};
const EDITORS = ["t3-rich", "t3-plain", "tiptap-stock", "contenteditable", "textarea"];

type Step = { t: "text"; s: string } | { t: "newline" } | { t: string; [k: string]: unknown };
function plan(text: string): Step[] {
  const p = Bun.spawnSync([planBin], { stdin: new TextEncoder().encode(text), env: process.env });
  if (p.exitCode !== 0) throw new Error(p.stderr.toString());
  return JSON.parse(p.stdout.toString());
}

const target = await (await fetch(`${CDP}/json/new?${encodeURI("file://" + resolve(fixtureDir, "index.html"))}`, { method: "PUT" })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let nextId = 1;
const pending = new Map<number, (v: any) => void>();
ws.onmessage = (m) => { const msg = JSON.parse(String(m.data)); pending.get(msg.id)?.(msg); pending.delete(msg.id); };
const send = (method: string, params: object = {}) => new Promise<any>((r) => {
  const id = nextId++; pending.set(id, r); ws.send(JSON.stringify({ id, method, params }));
});
const evaluate = async (expression: string) => {
  const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails));
  return r.result?.result?.value;
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
await send("Page.bringToFront");
for (let i = 0; i < 50 && !(await evaluate("window.fixtureReady === true")); i++) await sleep(100);
if (!(await evaluate("window.fixtureReady === true"))) throw new Error("fixture did not load");

async function replay(steps: Step[]) {
  for (const step of steps) {
    if (step.t === "newline") {
      const base = { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 36, modifiers: 8 };
      await send("Input.dispatchKeyEvent", { type: "keyDown", ...base, text: "\r", unmodifiedText: "\r" });
      await send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
    } else if (step.t === "text") {
      const s = String(step.s);
      await send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: [...s][0], windowsVirtualKeyCode: 0, nativeVirtualKeyCode: 0 });
      await send("Input.insertText", { text: s });
      await send("Input.dispatchKeyEvent", { type: "keyUp", key: [...s][0], windowsVirtualKeyCode: 0, nativeVirtualKeyCode: 0 });
    } else {
      throw new Error(`driver does not know step ${JSON.stringify(step)}`);
    }
  }
}

const rows: any[] = [];
for (const editor of EDITORS) {
  for (const [name, text] of Object.entries(INPUTS)) {
    await evaluate(`fixtureEditors[${JSON.stringify(editor)}].clear(); fixtureEditors[${JSON.stringify(editor)}].focus(); true`);
    await sleep(50);
    if (bridge) {
      const log = await runBridge(text);
      await sleep(150);
      console.log(`         ${log.replace(/\n/g, " | ")}`);
    } else if (real) {
      const p = Bun.spawnSync([real.bin, real.pid], { stdin: new TextEncoder().encode(text), env: process.env });
      if (p.exitCode !== 0) throw new Error(`post failed: ${p.stderr}`);
      await sleep(600);
    } else {
      await replay(plan(text));
      await sleep(150);
    }
    const got = await evaluate(`fixtureEditors[${JSON.stringify(editor)}].read()`);
    rows.push({ editor, input: name, exact: got === text, expected: text, got });
    console.log(`${got === text ? "EXACT    " : "NOT EXACT"} ${editor.padEnd(16)} ${name.padEnd(16)} ${JSON.stringify(got)}`);
  }
}
await send("Page.close").catch(() => {});
await fetch(`${CDP}/json/close/${target.id}`).catch(() => {});
await Bun.write(outPath, JSON.stringify({ cdp: CDP, plan: planBin, route: bridge ? `ListAwareTyping with real AX readback on pid ${bridge.pid}; batches replayed over CDP` : real ? `real CGEvents via ${real.bin}` : "CDP key events from the plan", bridgeLogs, rows }, null, 2) + "\n");
ws.close();
process.exit(0);
