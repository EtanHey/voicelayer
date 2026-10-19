import { withChildFixtureEnv } from "./setup/child-env";
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { missingSpawnEnvs, testSourceFiles } from "./setup/spawn-env-guard";

test("declared test sources and helpers use explicit current envs or justified exemptions", () => {
  const missing = testSourceFiles(process.cwd()).flatMap(file => missingSpawnEnvs(readFileSync(file, "utf8"), file));
  expect(missing.join("\n")).toBe("");
});

test("spawn guard covers aliases, object options, helpers, sync/exec variants and shell", () => {
  const prefix = 'import { spawn as launch, execFileSync } from "node:child_process"; import * as cp from "child_process";';
  for (const call of ['Bun.spawn(["bun"])', 'Bun.spawnSync({ cmd: ["bun"] })', 'launch("bun", [])',
    'cp.exec("true")', 'cp.execFile("bun", [])', 'cp.fork("script.js", [])', 'execFileSync("bun", [])', 'Bun.$`true`']) {
    expect(missingSpawnEnvs(prefix + call).length).toBe(1);
  }
  expect(missingSpawnEnvs('const original = Bun.spawnSync; original(["bun"])').length).toBe(1);
  expect(missingSpawnEnvs('const original = Bun.spawn.bind(Bun); original(["bun"])').length).toBe(1);
  expect(missingSpawnEnvs(prefix + 'const options = { env: process.env }; function run() { return launch("bun", [], options); }')).toEqual([]);
  expect(missingSpawnEnvs('Bun.spawnSync({ cmd: ["bun"], env: process.env })')).toEqual([]);
  expect(missingSpawnEnvs('Bun.$`true`.env(process.env)')).toEqual([]);
  expect(missingSpawnEnvs('// isolation-exempt: synthetic scanner fixture only; no runtime child is launched\nconst child = Bun.spawn([])')).toEqual([]);
  expect(missingSpawnEnvs('// spawn-env-allow:\nBun.spawn([])').length).toBe(1);
});

test("a child sees the preload's current isolated paths", async () => {
  const code = `
    const paths = await import('./src/paths.ts');
    const { getSTTVocabularyPath } = await import('./src/stt-vocabulary-store.ts');
    const { processingSettingsPath } = await import('./src/processing-settings.ts');
    console.log(JSON.stringify({ flag: process.env.VOICELAYER_TEST_ISOLATED,
      vocabulary: getSTTVocabularyPath(), processing: processingSettingsPath(),
      recordings: process.env.QA_VOICE_RECORDINGS_DIR, history: paths.TTS_HISTORY_FILE,
      state: paths.STATE_DIR, tmp: paths.TMP_ROOT,
      socket: paths.SOCKET_PATH, mcp: paths.MCP_SOCKET_PATH }));`;
  const child = Bun.spawn([process.execPath, "-e", code], { env: process.env, stdout: "pipe", stderr: "pipe" });
  const [output, error, exit] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
  expect(error).toBe("");
  expect(exit).toBe(0);
  const { flag, ...paths } = JSON.parse(output);
  expect(flag).toBe("1");
  for (const path of Object.values(paths)) expect(path).toStartWith(process.env.VOICELAYER_TEST_RUN_ROOT! + "/");
});

test("required redirects and missing isolated roots reject fallback before user file access", () => {
  // Synthetic HOME even during RED: importing paths may create its state directory.
  const code = `
    const p = await import('./src/paths.ts');
    const v = await import('./src/stt-vocabulary-store.ts');
    const s = await import('./src/processing-settings.ts');
    const w = await import('./src/whisper-performance.ts');
    const t = await import('./src/tts-settings.ts');
    const polish = await import('./src/stt-polish.ts');
    const failures = [];
    for (const value of [undefined, '', '  ']) {
      const env = { VOICELAYER_TEST_ISOLATED: '1' };
      for (const [name, fn] of [
        ['VOICELAYER_TMP_ROOT', p.getTmpRoot], ['QA_VOICE_RECORDINGS_DIR', p.getRecordingsArchiveRoot], ['VOICELAYER_STATE_DIR', p.getStateDir],
        ['VOICELAYER_SOCKET_PATH', p.getVoiceBarSocketPath], ['VOICELAYER_MCP_SOCKET_PATH', p.getMcpSocketPath],
        ['QA_VOICE_STT_VOCABULARY_PATH', e => v.getSTTVocabularyPath({env: e})],
        ['VOICELAYER_PROCESSING_SETTINGS_PATH', s.processingSettingsPath],
        ['QA_VOICE_WHISPER_PERFORMANCE_PATH', w.whisperPerformanceConfigPath],
        ['VOICELAYER_TTS_SETTINGS_PATH', t.ttsSettingsPath],
        ['QA_VOICE_STT_POLISH_SOCKET', polish.getSTTPolishSocketPath],
      ]) {
        env[name] = value;
        try { fn(env); failures.push(name + ':' + String(value)); } catch (e) {
          if (!String(e).includes('isolated')) throw e;
        }
        delete env[name];
      }
    }
    const { join } = await import('node:path');
    const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
    const preloadVocabulary = process.env.QA_VOICE_STT_VOCABULARY_PATH;
    const homeVocabulary = join(runRoot, 'synthetic-home', '.local/state/voicelayer/stt-vocabulary.json');
    const classifyVocabulary = path => path === preloadVocabulary && path.startsWith(runRoot + '/')
      ? [] : ['production vocabulary'];
    // Process isolation wins over empty/partial caller envs; none may fall back to HOME.
    for (const env of [{}, { VOICELAYER_TEST_ISOLATED: '0' },
      { QA_VOICE_STT_VOCABULARY_PATH: '' }, { QA_VOICE_STT_VOCABULARY_PATH: '  ' }]) {
      failures.push(...classifyVocabulary(v.getSTTVocabularyPath({ env })));
    }
    // Negative control: the same guard must reject an actual HOME-default candidate.
    if (JSON.stringify(classifyVocabulary(homeVocabulary)) !== JSON.stringify(['production vocabulary'])) {
      failures.push('HOME fallback negative control');
    }
    // Resolve production names only with process isolation absent, still under synthetic HOME.
    const isolated = process.env.VOICELAYER_TEST_ISOLATED;
    delete process.env.VOICELAYER_TEST_ISOLATED;
    try {
      if (p.getTmpRoot({}) !== '/tmp') failures.push('production tmp');
      if (v.getSTTVocabularyPath({ env: {} }) !== homeVocabulary) failures.push('production vocabulary default');
    } finally {
      process.env.VOICELAYER_TEST_ISOLATED = isolated;
    }
    console.log(JSON.stringify(failures));`;
  const child = Bun.spawnSync([process.execPath, "-e", code], {
    env: { ...process.env, HOME: join(process.env.VOICELAYER_TEST_RUN_ROOT!, "synthetic-home") },
    stdout: "pipe", stderr: "pipe",
  });
  expect(child.stderr.toString()).toBe("");
  expect(child.exitCode).toBe(0);
  expect(JSON.parse(child.stdout.toString())).toEqual([]);
});

// The allowlist is only for testing the preload's defence for production helpers.
test("preload forwards current env for runtime helpers that omit Bun's env option", async () => {
  // isolation-exempt: intentional omission proves the preload runtime-helper defence without user file access
  const child = Bun.spawn([process.execPath, "-e", "console.log(JSON.stringify([process.env.VOICELAYER_TEST_ISOLATED, process.env.QA_VOICE_STT_VOCABULARY_PATH]))"]);
  expect(await child.exited).toBe(0);
  expect(JSON.parse(await new Response(child.stdout).text())).toEqual([
    "1", process.env.QA_VOICE_STT_VOCABULARY_PATH,
  ]);
  // isolation-exempt: intentional omission proves the synchronous runtime-helper defence without user file access
  const sync = Bun.spawnSync({ cmd: [process.execPath, "-e", "console.log(process.env.VOICELAYER_TMP_ROOT)"] });
  expect(sync.exitCode).toBe(0);
  expect(sync.stdout.toString().trim()).toBe(process.env.VOICELAYER_TMP_ROOT!);
});


test("guard discovery follows package roots and includes colocated tests plus helpers", () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "scan-roots-"));
  try {
    writeFileSync(join(root, "package.json"), JSON.stringify({ scripts: { test: "bun test ./src ./tests ./site ./extra" } }));
    const files = ["src/feature.test.ts", "src/feature.spec.tsx", "site/view.test.js", "extra/new.spec.mjs",
      "src/__tests__/setup/helper.ts", "tests/helper.ts", "src/runtime.ts", "site/app.js", "unlisted/hidden.test.ts"];
    for (const file of files) {
      mkdirSync(join(root, file, ".."), { recursive: true });
      writeFileSync(join(root, file), "");
    }
    expect(testSourceFiles(root).map(file => relative(root, file)).sort()).toEqual(files.slice(0, 6).sort());
    expect(testSourceFiles(process.cwd())).toContain(join(process.cwd(), "src/voicereview-web/server.test.ts"));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("guard rejects subset envs and requires a specific isolation exemption tag", () => {
  for (const env of ["{}", '{ PATH: "fixture" }', "undefined"]) {
    expect(missingSpawnEnvs(`Bun.spawnSync(["bun"], { env: ${env} })`).length).toBe(1);
  }
  expect(missingSpawnEnvs('Bun.$`true`.env({})').length).toBe(1);
  expect(missingSpawnEnvs('const env = { ...process.env }; Bun.spawnSync(["bun"], { env })')).toEqual([]);
  expect(missingSpawnEnvs('// spawn-env-allow: aaaaaaaaaaaaaaaa\nBun.spawnSync(["bun"])').length).toBe(1);
  expect(missingSpawnEnvs('// isolation-exempt: reason\nBun.spawnSync(["bun"])').length).toBe(1);
  expect(missingSpawnEnvs('// isolation-exempt: synthetic script only reports environment keys for the preload regression\nconst child = Bun.spawnSync(["bun"], { env: {} })')).toEqual([]);
});

test("preload preserves isolation keys over explicit subset envs for both spawn forms", async () => {
  const keys = ["VOICELAYER_TEST_ISOLATED", "VOICELAYER_TEST_RUN_ROOT", "VOICELAYER_TMP_ROOT", "VOICELAYER_STATE_DIR",
    "VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH", "QA_VOICE_STT_VOCABULARY_PATH", "QA_VOICE_RECORDINGS_DIR",
    "QA_VOICE_THINK_FILE", "QA_VOICE_MCP_PID_PATH", "VOICELAYER_TEST_FAKE_REC", "VOICELAYER_TEST_FAKE_REC_BIN"];
  const code = `console.log(JSON.stringify(${JSON.stringify(keys)}.map(key => process.env[key])))`;
  const expected = keys.map(key => process.env[key]);
  for (const env of [{}, { VOICELAYER_TEST_ISOLATED: "0", VOICELAYER_STATE_DIR: "", VOICELAYER_TEST_FAKE_REC: "0" }]) {
    // isolation-exempt: subset env deliberately tests preload key preservation; child only reports env names
    const asyncChild = Bun.spawn([process.execPath, "-e", code], { env, stdout: "pipe" });
    expect(await asyncChild.exited).toBe(0);
    expect(JSON.parse(await new Response(asyncChild.stdout).text())).toEqual(expected);
    // isolation-exempt: object-form subset env deliberately tests preload key preservation without user file access
    const sync = Bun.spawnSync({ cmd: [process.execPath, "-e", code], env });
    expect(sync.exitCode).toBe(0);
    expect(JSON.parse(sync.stdout.toString())).toEqual(expected);
  }
  // isolation-exempt: explicit undefined env reproduces Bun startup-snapshot fallback; child reports env keys only
  const sync = Bun.spawnSync([process.execPath, "-e", code], { env: undefined });
  expect(sync.exitCode).toBe(0);
  expect(JSON.parse(sync.stdout.toString())).toEqual(expected);
});


test("fixture env selection restores the parent after spawn success or failure", () => {
  const key = "TESTISO1_SYNTHETIC_FIXTURE_KEY";
  const before = process.env[key];
  const marker = {};
  expect(withChildFixtureEnv({ [key]: "sandbox" }, () => {
    expect(process.env[key]).toBe("sandbox");
    return marker;
  })).toBe(marker);
  expect(process.env[key]).toBe(before);
  expect(() => withChildFixtureEnv({ [key]: undefined }, () => {
    expect(process.env[key]).toBeUndefined();
    throw new Error("synthetic spawn failure");
  })).toThrow("synthetic spawn failure");
  expect(process.env[key]).toBe(before);
});
