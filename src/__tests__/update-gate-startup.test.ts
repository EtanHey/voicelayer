import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as fs from "node:fs";
import { join } from "node:path";
import ts from "typescript";
import { initializeVoiceGate, withCaptureVoiceAdmission } from "../update-gate-admission";

const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
let path: string;
let log: ReturnType<typeof spyOn>;
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  path = join(fs.mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "startup-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  fs.mkdirSync(path + ".lock"); // Stale evidence is retained, never reaped.
  log = spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  log.mockRestore();
  process.env.VOICELAYER_UPDATE_GATE_PATH = original;
});

for (const marker of [true, false]) test(`G2e stale startup lock marker=${marker} uses bounded off-path budget and admits voice`, async () => {
  if (marker) fs.writeFileSync(path + ".voice-diag.json", "{\"kind\":\"UNKNOWN\"}\n");
  const start = performance.now();
  await initializeVoiceGate();
  const ms = performance.now() - start;
  console.info(`G2e startup marker=${marker}: ${ms.toFixed(3)}ms`);
  expect(ms).toBeLessThan(marker ? 50 : 1750);
  if (!marker) expect(ms).toBeGreaterThanOrEqual(1400);
  expect(await withCaptureVoiceAdmission(() => "voice admitted")).toBe("voice admitted");
  expect(fs.existsSync(path + ".lock")).toBe(true);
  expect(fs.existsSync(path + ".voice-diag.json")).toBe(true);
  expect(log).toHaveBeenCalled();
});

for (const name of ["daemon.ts", "mcp-server-daemon.ts", "mcp-server.ts"]) test(`G2e ${name} reaches connectToBar while gate init is pending`, async () => {
  const source = fs.readFileSync(join(import.meta.dir, "..", name), "utf8");
  const file = ts.createSourceFile(name, source, ts.ScriptTarget.Latest, true);
  const main = file.statements.find((node): node is ts.FunctionDeclaration => ts.isFunctionDeclaration(node) && node.name?.text === "main")!;
  const statements = main.body!.statements.map(node => node.getText(file));
  const index = statements.findIndex(text => text.includes("initializeVoiceGate()"));
  expect(index).toBeGreaterThanOrEqual(0);
  expect(index).toBeGreaterThan(statements.findIndex(text => text.startsWith("connectToBar(")));
  if (name === "mcp-server.ts") expect(index).toBeGreaterThan(statements.findIndex(text => text.includes("await server.connect(")));
  if (name === "mcp-server-daemon.ts") expect(index).toBeGreaterThan(statements.findIndex(text => text.includes("await createMcpDaemon(")));
  if (name !== "mcp-server.ts") expect(index).toBeGreaterThan(statements.findLastIndex(text => text.includes("acquireProcessLock(")));
  if (name === "mcp-server-daemon.ts") expect(index).toBeGreaterThan(statements.findIndex(text => text.includes("isVoicelayerDisabled()")));
  // Keep the source ordering and its earlier asynchronous backend boundary.
  // Stub media/transport effects; even the first synchronous init must wait.
  const startup = statements.flatMap(text => text.includes("initializeVoiceGate()") ? [text] :
    text.includes("await getBackend()") ? ["await getBackend();"] :
    text.startsWith("connectToBar(") ? ["connectToBar();"] :
    (text.includes("await server.connect(") || text.includes("await createMcpDaemon(")) ? ["await server.connect();"] : []);
  const run = new Function("initializeVoiceGate", "console", "connectToBar", "getBackend", "server",
    `return (async () => { ${ts.transpile(startup.join("\n"), { target: ts.ScriptTarget.ESNext })} })();`);
  let backendReady!: () => void, transportReady!: () => void;
  const backend = new Promise<void>(resolve => { backendReady = resolve; });
  const transport = new Promise<void>(resolve => { transportReady = resolve; });
  const order: string[] = [];
  const initialize = mock(() => { order.push("init"); return new Promise<void>(() => {}); });
  const connect = mock(() => { order.push("bar"); });
  const running = run(initialize, console, connect, () => backend,
    { connect: () => { order.push("transport"); return transport; } });
  await Bun.sleep(0);
  expect(initialize).not.toHaveBeenCalled();
  expect(connect).not.toHaveBeenCalled();
  backendReady(); await Bun.sleep(0);
  if (name !== "daemon.ts") expect(initialize).not.toHaveBeenCalled();
  transportReady(); await running; await Bun.sleep(0);
  expect(initialize).toHaveBeenCalledTimes(1);
  expect(order).toEqual(name !== "daemon.ts" ? ["bar", "transport", "init"] : ["bar", "init"]);
});

test("G2f detached startup tolerates a 100ms live transition without sticky diagnostics", async () => {
  const unlock = setTimeout(() => fs.rmdirSync(path + ".lock"), 100);
  try {
    await initializeVoiceGate();
    expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
    expect(fs.existsSync(path)).toBe(true);
    expect(log).not.toHaveBeenCalled();
  } finally { clearTimeout(unlock); }
});
