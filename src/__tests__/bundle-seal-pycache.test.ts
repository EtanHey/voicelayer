import { expect, test } from "bun:test";
import { readFileSync, mkdirSync, mkdtempSync, writeFileSync, rmSync, symlinkSync, existsSync } from "node:fs";
import { join } from "node:path";
import { ParakeetServer } from "../parakeet-server";
import { parakeetChildEnvironment } from "../parakeet-python-env";
import { synthesizeWithRetry } from "../tts-health";
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
    const alias = join(directory, "linked.app");
    symlinkSync(app, alias);
    expect(Bun.spawnSync(["bash", join(root, "scripts/check-voicebar-python-cache-free.sh"), alias], { env: process.env }).exitCode).toBe(1);
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
require('fs').writeFileSync(${JSON.stringify(receipt)}, JSON.stringify({prefix:process.env.PYTHONPYCACHEPREFIX, dont:process.env.PYTHONDONTWRITEBYTECODE}));
for await (const line of createInterface({input:process.stdin})) {
 const r=JSON.parse(line); console.log(JSON.stringify({id:r.id,ok:true,ready:true,protocol:1,pid:process.pid}));
}`);
  const old = process.env.PYTHONDONTWRITEBYTECODE;
  process.env.PYTHONDONTWRITEBYTECODE = "1";
  const server = new ParakeetServer({command: [process.execPath, script], startupMs: 3000});
  try {
    await server.start();
    const env = JSON.parse(readFileSync(receipt, "utf8"));
    expect(env.prefix).toBe(parakeetChildEnvironment().PYTHONPYCACHEPREFIX);
    expect(env.prefix).not.toMatch(/\.app(?:\/|$)/i);
    expect(env.prefix.startsWith(process.env.VOICELAYER_TMP_ROOT!)).toBe(true);
    expect(env.dont).toBeUndefined();
  } finally {
    if (old === undefined) delete process.env.PYTHONDONTWRITEBYTECODE;
    else process.env.PYTHONDONTWRITEBYTECODE = old;
    await server.shutdown(); rmSync(directory, { recursive: true });
  }
});


test("Parakeet cache override rejects app paths and app symlink ancestors", () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "prefix-"));
  try {
    const app = join(directory, "bundle.app"); mkdirSync(app);
    const alias = join(directory, "alias"); symlinkSync(app, alias);
    for (const prefix of [join(app, "cache"), join(alias, "cache")]) {
      expect(() => parakeetChildEnvironment({ ...process.env, VOICELAYER_PARAKEET_PYCACHE_PREFIX: prefix })).toThrow("inside-app");
    }
    const prefix = join(process.env.VOICELAYER_TMP_ROOT!, "cache/voicelayer/custom-pycache");
    expect(parakeetChildEnvironment({ ...process.env, VOICELAYER_PARAKEET_PYCACHE_PREFIX: prefix }).PYTHONPYCACHEPREFIX).toBe(prefix);
  } finally { rmSync(directory, { recursive: true }); }
});

test("Edge synthesis child receives DONTWRITE", async () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "edge-env-"));
  const receipt = join(directory, "env.txt"), spawn = Bun.spawn;
  // Run an env-recording interpreter substitute through the real synthesis spawn seam.
  Bun.spawn = ((cmd: unknown, options: any) => spawn([process.execPath, "-e",
    `require('fs').writeFileSync(${JSON.stringify(receipt)}, process.env.PYTHONDONTWRITEBYTECODE || 'missing')`], { ...options, env: { ...process.env, ...options?.env } })) as typeof Bun.spawn;
  try {
    await synthesizeWithRetry("fixture", "voice", "+0%", join(directory, "audio.mp3"), "fixture.py", 0);
    expect(readFileSync(receipt, "utf8")).toBe("1");
  } finally { Bun.spawn = spawn; rmSync(directory, { recursive: true }); }
});

test("runtime source copy excludes Python artifacts before bundle validation", () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "copy-"));
  try {
    const source = join(directory, "repo"), app = join(directory, "bundle.app");
    mkdirSync(join(source, "src/nested/__pycache__"), { recursive: true });
    writeFileSync(join(source, "src/nested/__pycache__/module.pyc"), "cached");
    writeFileSync(join(source, "src/standalone.pyc"), "cached");
    writeFileSync(join(source, "src/module.py"), "# retained");
    const body = text("flow-bar/build-app.sh").match(/bundle_runtime_source\(\) \{([\s\S]*?)\n\}/)![1];
    const result = Bun.spawnSync(["bash", "-c", body], { env: { ...process.env, REPO_ROOT: source, APP_DIR: app } });
    expect(result.exitCode).toBe(0);
    expect(existsSync(join(app, "Contents/Resources/src/module.py"))).toBe(true);
    mkdirSync(join(source, "models/__pycache__"), { recursive: true });
    writeFileSync(join(source, "models/__pycache__/model.pyc"), "cached");
    writeFileSync(join(source, "models/model.pyc"), "cached");
    writeFileSync(join(source, "models/silero_vad.onnx"), "retained");
    const modelCopy = text("flow-bar/build-app.sh").split("\n").filter(line =>
      line.includes('mkdir -p "$APP_DIR/Contents/Resources/models"') ||
      line.trimStart().startsWith("rsync -a") && line.includes('$REPO_ROOT/models/')).join("\n");
    expect(Bun.spawnSync(["bash", "-c", modelCopy], { env: { ...process.env, REPO_ROOT: source, APP_DIR: app } }).exitCode).toBe(0);
    expect(existsSync(join(app, "Contents/Resources/models/silero_vad.onnx"))).toBe(true);
    expect(Bun.spawnSync(["bash", join(root, "scripts/check-voicebar-python-cache-free.sh"), app], { env: process.env }).exitCode).toBe(0);
  } finally { rmSync(directory, { recursive: true }); }
});

test("release verifier rejects cached bundle before signing/version checks", () => {
  const directory = mkdtempSync(join(process.env.VOICELAYER_TMP_ROOT!, "verify-"));
  try {
    const app = join(directory, "bundle.app"), zip = join(directory, "bundle.zip");
    mkdirSync(join(app, "Contents/Resources/__pycache__"), { recursive: true });
    writeFileSync(zip, "fixture");
    writeFileSync(join(app, "Contents/Info.plist"), "fixture");
    writeFileSync(join(app, "Contents/Resources/package.json"), "{}");
    const result = Bun.spawnSync(["bash", join(root, "scripts/verify-voicebar-release.sh"), "--version", "2.3.0", "--app", app, "--zip", zip, "--skip-tap-check"], { env: process.env });
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("Python cache artifacts");
  } finally { rmSync(directory, { recursive: true }); }
});
