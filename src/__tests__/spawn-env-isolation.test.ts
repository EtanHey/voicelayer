import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { missingSpawnEnvs } from "./setup/spawn-env-guard";

function sources(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
    const path = join(dir, entry.name);
    return entry.isDirectory() ? sources(path) : /\.[cm]?[jt]sx?$/.test(path) ? [path] : [];
  });
}

test("every test child explicitly receives an environment (including helper implementations)", () => {
  const missing = ["src/__tests__", "tests"].flatMap(sources).flatMap(file => missingSpawnEnvs(readFileSync(file, "utf8"), file));
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
  expect(missingSpawnEnvs('// spawn-env-allow: synthetic scanner fixture, no runtime child\nconst child = Bun.spawn([])')).toEqual([]);
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

test("isolated resolvers reject missing, empty and whitespace redirects before HOME fallback", () => {
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
    // Non-test defaults are unchanged; these calls resolve names only, never read stores.
    if (p.getTmpRoot({}) !== '/tmp') failures.push('production tmp');
    if (!v.getSTTVocabularyPath({env: {}}).endsWith('/.local/state/voicelayer/stt-vocabulary.json')) failures.push('production vocabulary');
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
  // spawn-env-allow: intentional omission proves the preload's runtime-helper defence
  const child = Bun.spawn([process.execPath, "-e", "console.log(JSON.stringify([process.env.VOICELAYER_TEST_ISOLATED, process.env.QA_VOICE_STT_VOCABULARY_PATH]))"]);
  expect(await child.exited).toBe(0);
  expect(JSON.parse(await new Response(child.stdout).text())).toEqual([
    "1", process.env.QA_VOICE_STT_VOCABULARY_PATH,
  ]);
  // spawn-env-allow: intentional omission proves the synchronous runtime-helper defence
  const sync = Bun.spawnSync({ cmd: [process.execPath, "-e", "console.log(process.env.VOICELAYER_TMP_ROOT)"] });
  expect(sync.exitCode).toBe(0);
  expect(sync.stdout.toString().trim()).toBe(process.env.VOICELAYER_TMP_ROOT!);
});
