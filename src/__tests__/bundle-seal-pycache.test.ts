import { expect, test } from "bun:test";
import { readFileSync, mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { ParakeetServer } from "../parakeet-server";
import { runSpeechGeneration } from "../tts/generation-process";

const root = join(import.meta.dir, "../..");
const text = (path: string) => readFileSync(join(root, path), "utf8");

test("Python spawn sites explicitly disable bytecode despite inherited settings", async () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "bytecode-"));
  const receipt = join(directory, "env.txt");
  const old = process.env.PYTHONDONTWRITEBYTECODE;
  process.env.PYTHONDONTWRITEBYTECODE = "";
  try {
    expect(await runSpeechGeneration([process.execPath, "-e", `require('fs').writeFileSync(${JSON.stringify(receipt)}, process.env.PYTHONDONTWRITEBYTECODE || 'missing')`])).toBe(0);
    expect(readFileSync(receipt, "utf8")).toBe("1");
  } finally {
    if (old === undefined) delete process.env.PYTHONDONTWRITEBYTECODE;
    else process.env.PYTHONDONTWRITEBYTECODE = old;
    rmSync(directory, { recursive: true });
  }
});

for (const path of ["src/parakeet-server.ts", "src/parakeet-runtime.ts", "src/tts-health.ts", "src/voicereview-web/server.ts", "flow-bar/Sources/VoiceBar/CloneEngineRuntime.swift", "src/cli/voicelayer.sh"]) {
  test(`${path} protects Python bytecode writes`, () => {
    expect(text(path).includes("PYTHONDONTWRITEBYTECODE")).toBe(true);
  });
}

test("bundle check rejects bytecode and cache directories including empty ones", () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "bundle-"));
  const app = join(directory, "VoiceBar.app");
  mkdirSync(join(app, "Contents/Resources"), { recursive: true });
  const check = () => Bun.spawnSync(["bash", join(root, "scripts/check-voicebar-python-cache-free.sh"), app], { env: process.env });
  try {
    expect(check().exitCode).toBe(0);
    const cache = join(app, "Contents/Resources/__pycache__");
    mkdirSync(cache);
    expect(check().exitCode).toBe(1);
    rmSync(cache, { recursive: true });
    writeFileSync(join(app, "Contents/Resources/module.pyc"), "bytecode");
    expect(check().exitCode).toBe(1);
  } finally { rmSync(directory, { recursive: true }); }
});

test("release and QA builds check Python caches before signing", () => {
  expect(text("flow-bar/build-app.sh").includes('bash "$REPO_ROOT/scripts/check-voicebar-python-cache-free.sh" "$APP_DIR"')).toBe(true);
});


test("Parakeet protocol child receives bytecode protection", async () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "parakeet-env-"));
  const receipt = join(directory, "env.txt"), script = join(directory, "child.mjs");
  writeFileSync(script, `import { createInterface } from 'node:readline';
require('fs').writeFileSync(${JSON.stringify(receipt)}, process.env.PYTHONDONTWRITEBYTECODE || 'missing');
for await (const line of createInterface({input:process.stdin})) {
 const r=JSON.parse(line); console.log(JSON.stringify({id:r.id,ok:true,ready:true,protocol:1,pid:process.pid}));
}`);
  const server = new ParakeetServer({command: [process.execPath, script], startupMs: 3000});
  try {
    await server.start();
    expect(readFileSync(receipt, "utf8")).toBe("1");
  } finally { await server.shutdown(); rmSync(directory, { recursive: true }); }
});
