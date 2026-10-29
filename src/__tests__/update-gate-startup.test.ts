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

for (const marker of [true, false]) test(`G2e stale startup lock marker=${marker} finishes under 50ms and admits voice`, async () => {
  if (marker) fs.writeFileSync(path + ".voice-diag.json", "{\"kind\":\"UNKNOWN\"}\n");
  const start = performance.now();
  await initializeVoiceGate();
  const ms = performance.now() - start;
  console.info(`G2e startup marker=${marker}: ${ms.toFixed(3)}ms`);
  expect(ms).toBeLessThan(50);
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
  expect(index).toBeLessThan(statements.findIndex(text => text.startsWith("connectToBar(")));
  if (name !== "mcp-server.ts") expect(index).toBeGreaterThan(statements.findLastIndex(text => text.includes("acquireProcessLock(")));
  if (name === "mcp-server-daemon.ts") expect(index).toBeGreaterThan(statements.findIndex(text => text.includes("isVoicelayerDisabled()")));
  // Execute the actual startup-init statement with a held promise, then the
  // connection boundary. No daemon import, socket, singleton or mic is opened.
  const init = ts.transpile(statements[index], { target: ts.ScriptTarget.ESNext });
  const run = new Function("initializeVoiceGate", "console", "connectToBar", `return (async () => { ${init}; connectToBar(); })();`);
  let release!: () => void;
  const pending = new Promise<void>(resolve => { release = resolve; });
  const initialize = mock(() => pending), connect = mock(() => {});
  const start = performance.now();
  const running = run(initialize, console, connect);
  try {
    await Bun.sleep(0);
    expect(initialize).toHaveBeenCalledTimes(1);
    expect(connect).toHaveBeenCalledTimes(1);
    console.info(`G2e ${name} connect while init pending: ${(performance.now() - start).toFixed(3)}ms`);
  } finally { release(); await running; }
});
