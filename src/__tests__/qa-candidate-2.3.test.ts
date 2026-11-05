import { expect, test } from "bun:test";
import { join } from "node:path";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { resolveRecorderBinary } from "../recorder-binary";

const helper = join(import.meta.dir, "../../scripts/lib/qa-candidate-2.3.py");
function python(body: string) {
  const result = Bun.spawnSync(["python3", "-c", `import runpy,os,json\nfrom pathlib import Path\nm=runpy.run_path(${JSON.stringify(helper)})\n${body}`],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  return { exit: result.exitCode, out: result.stdout.toString(), error: result.stderr.toString() };
}
const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "qa23-refusal");
mkdirSync(root, { recursive: true });
test("generated writable environment has no resident paths", () => {
  const result = python(`env=m['environment'](Path('/qa-candidate'),Path('/nonexistent-qa-source'))\nassert env['VOICEBAR_USER_DEFAULTS_SUITE']=='com.voicelayer.voicebar.qa23'\nassert env['VOICEBAR_QA_PRESERVE_OVERRIDES']=='1'\nfor key,value in env.items():\n if value.startswith('/'):\n  assert value.startswith(('/qa-candidate/','/tmp/vl-qa23-')), (key,value)\nprint(json.dumps(env))`);
  expect(result.exit).toBe(0); expect(result.error).toBe("");
  expect(JSON.parse(result.out).VOICEBAR_QA_FIXTURE_RECORDER).toBeUndefined();
});
test("fixture recorder emits the WAV PCM through the existing recorder override", () => {
  const result = python(`import subprocess,wave\nbase=Path(${JSON.stringify(root)})\nwav=base/'input.wav'\nwith wave.open(str(wav),'wb') as f:\n f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000); f.writeframes(b'\\x34\\x12'*800)\nenv=m['fixture_recorder'](wav,base)\np=subprocess.Popen([env['VOICELAYER_TEST_FAKE_REC_BIN'],'-q','-'],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)\ntry:\n assert p.stdout.read(1600)==b'\\x34\\x12'*800\nfinally:\n p.terminate();p.wait(timeout=3)\nprint(json.dumps(env))`);
  expect(result.exit).toBe(0); expect(result.error).toBe("");
  const env = JSON.parse(result.out);
  expect(env).toMatchObject({ VOICEBAR_QA_FIXTURE_RECORDER: "1", VOICEBAR_QA_SKIP_PERMISSION_PROMPTS: "1", VOICEBAR_QA_SKIP_HOTKEY: "1" });
  expect(resolveRecorderBinary(env)).toBe(env.VOICELAYER_TEST_FAKE_REC_BIN);
});

test("relay installer refuses a QA app before any host command or HOME write", () => {
  const result = Bun.spawnSync(["bash", join(import.meta.dir, "../../scripts/install-voicebar-f5-hidutil.sh")],
    { env: { ...process.env, VOICELAYER_QA_HEALTH: "1" }, stdout: "pipe", stderr: "pipe" });
  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toContain("REFUSED: QA app cannot install the system F5 relay");
});
test("relay installer refuses a foreign HOME even without a QA marker", () => {
  const home = join(root, "foreign-home"), bin = join(root, "host-tool-stubs");
  mkdirSync(home, { recursive: true }); mkdirSync(bin, { recursive: true });
  for (const name of ["launchctl", "plutil", "hidutil"]) writeFileSync(join(bin, name), "#!/bin/sh\nexit 99\n", { mode: 0o755 });
  const result = Bun.spawnSync(["bash", "-c", 'unset VOICELAYER_TEST_ISOLATED VOICELAYER_QA_HEALTH VOICEBAR_QA_PRESERVE_OVERRIDES VOICEBAR_USER_DEFAULTS_SUITE; exec bash "$1"', "qa-home-check", join(import.meta.dir, "../../scripts/install-voicebar-f5-hidutil.sh")],
    { env: { ...process.env, HOME: home, PATH: `${bin}:/usr/bin:/bin` }, stdout: "pipe", stderr: "pipe" });
  expect(result.exitCode).toBe(1); expect(result.stderr.toString()).toContain("REFUSED: relay installer requires the real HOME");
  expect(existsSync(join(home, "Library"))).toBe(false);
});
