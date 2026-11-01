import { canonicalWeightTargets } from "./setup/stt-parakeet-policy";
import { test, expect } from "bun:test";
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync, symlinkSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { installSttSpawnGuard } from "./setup/stt-spawn-guard";
import { testTmp } from "./setup/test-tmp";

test("Parakeet script operand is refused; fixture import data and generic Python remain usable", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1") return;
  const root = testTmp("parakeet-guard"); mkdirSync(root, { recursive: true });
  const worker = join(import.meta.dir, "../parakeet-worker.py");
  // A synthetic outside worker proves interception without executing real imports.
  const outside = mkdtempSync(join(tmpdir(), "parakeet-entry-"));
  try {
    const script = join(outside, "parakeet-worker.py"); writeFileSync(script, "raise RuntimeError('SYNTHETIC_EXECUTED')\n");
    for (const args of [["python3", "-u", script], ["python3", "-B", "--", script]]) {
      const x = Bun.spawnSync(args, { env: process.env });
      expect(x.exitCode).toBe(78); expect(x.stderr.toString()).toContain("STT_LIVE_OPT_IN_REQUIRED");
      expect(x.stderr.toString()).not.toContain("SYNTHETIC_EXECUTED");
    }
    const fixture = join(root, "fake-runtime.py"); writeFileSync(fixture, "import sys; print('FAKE_ONLY')\n");
    const data = Bun.spawnSync(["python3", fixture, worker], { env: process.env });
    expect(data.exitCode).toBe(0); expect(data.stdout.toString().trim()).toBe("FAKE_ONLY");
    const fakeWorker = join(root, "parakeet-worker.py"); writeFileSync(fakeWorker, "print('FAKE_WORKER')\n");
    expect(Bun.spawnSync(["python3", fakeWorker], { env: process.env }).stdout.toString().trim()).toBe("FAKE_WORKER");
    const escape = join(root, "escaped.py"); symlinkSync(script, escape);
    expect(Bun.spawnSync(["python3", escape], { env: process.env }).exitCode).toBe(78);
    const last = readFileSync(process.env.VOICELAYER_TEST_STT_STUB_LOG!, "utf8").trim().split("\n").at(-1)!;
    expect(JSON.parse(last)).toMatchObject({engine: "parakeet", denied: true, exitCode: 78});
    expect(last).not.toContain(outside);
    const shell = Bun.spawnSync(["/bin/sh", "-c", 'python3 -u "$1"', "guard", script], {env: process.env});
    expect(shell.exitCode).toBe(78);
  } finally { rmSync(outside, { recursive: true, force: true }); }
});

test("kernel denies actual weight reads outside canonical fixtures, including symlink escapes and raw descendants", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const root = testTmp("weights-guard"); mkdirSync(root, {recursive: true});
  const outside = mkdtempSync(join(tmpdir(), "parakeet-weights-"));
  try {
    const weight = join(outside, "synthetic.safetensors"); writeFileSync(weight, "SYNTHETIC_ONLY");
    const neutral = join(outside, "neutral.txt"); writeFileSync(neutral, "NEUTRAL");
    expect(readFileSync(neutral, "utf8")).toBe("NEUTRAL");
    expect(() => readFileSync(weight)).toThrow();
    const fake = join(root, "fake.safetensors"); writeFileSync(fake, "FAKE");
    expect(readFileSync(fake, "utf8")).toBe("FAKE");
    const escape = join(root, "alias.safetensors"); symlinkSync(weight, escape);
    expect(() => readFileSync(escape)).toThrow();
    for (const cmd of [["/bin/cat", weight], [process.execPath, "-e", "require('fs').readFileSync(process.argv[1])", weight]]) {
      const x = require("node:child_process").spawnSync(cmd[0], cmd.slice(1), {env: process.env});
      expect(x.status).not.toBe(0); expect(x.stdout.toString()).toBe("");
    }
  } finally { rmSync(outside, {recursive:true,force:true}); }
});


test("changed configured interpreter after inherited sandbox fails closed", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const root = testTmp("runtime-controls"); mkdirSync(root, {recursive:true});
  const outside = mkdtempSync(join(tmpdir(), "parakeet-runtime-"));
  try {
    const runtime = join(outside, "synthetic-python"), alias = join(root, "runtime-alias");
    writeFileSync(runtime, "#!/bin/sh\nexit 61\n", {mode:0o700}); symlinkSync(runtime, alias);
    const direct = join(outside, "parakeet-worker.py"); writeFileSync(direct,"#!/bin/sh\nexit 62\n",{mode:0o700});
    const code = `import {installSttSpawnGuard} from ${JSON.stringify(join(import.meta.dir,"setup/stt-spawn-guard.ts"))};
      const fs=require('fs');const root=process.argv[1];
      process.env.VOICELAYER_PARAKEET_PYTHON=process.argv[2];
      fs.mkdirSync(root);installSttSpawnGuard(root,process.env.VOICELAYER_TEST_RUN_ROOT);`;
    const x = Bun.spawnSync([process.execPath,"-e",code,join(root,"installed"),runtime,alias,direct],{env:process.env});
    expect(x.exitCode).not.toBe(0); expect(x.stderr.toString()).toContain("STT guard kernel policy failed");
  } finally {rmSync(outside,{recursive:true,force:true});}
});

test("same exact live opt-in skips guard installation using harmless sentinel only", () => {
  const saved=process.env.QA_VOICE_GOLDEN_LIVE;
  try {process.env.QA_VOICE_GOLDEN_LIVE="1";expect(installSttSpawnGuard("/never-used-opt-in-root")).toBeNull();}
  finally {if(saved===undefined)delete process.env.QA_VOICE_GOLDEN_LIVE;else process.env.QA_VOICE_GOLDEN_LIVE=saved;}
});


test("weight target discovery uses metadata for extensionless cache symlinks under an inherited read deny", () => {
  const outside = mkdtempSync(join(tmpdir(), "parakeet-weight-target-"));
  try {
    const target=join(realpathSync(outside),"immutable-blob"),alias=join(outside,"model.safetensors");
    writeFileSync(target,"SYNTHETIC_ONLY");symlinkSync(target,alias);
    expect(canonicalWeightTargets({VOICELAYER_PARAKEET_MODEL:outside,HF_HUB_CACHE:join(outside,"missing")},[])).toEqual([target]);
    expect(canonicalWeightTargets({VOICELAYER_PARAKEET_MODEL:outside,HF_HUB_CACHE:join(outside,"missing")},[realpathSync(outside)])).toEqual([]);
  } finally {rmSync(outside,{recursive:true,force:true});}
});


test("forged cache cannot drop denial of a newly configured canonical weight target", () => {
  if (process.env.QA_VOICE_GOLDEN_LIVE === "1" || process.platform !== "darwin") return;
  const outside=mkdtempSync(join(tmpdir(),"parakeet-new-target-"));
  const root=testTmp("forged-weight-cache");mkdirSync(root,{recursive:true});
  try {
    const blob=join(realpathSync(outside),"blob");writeFileSync(blob,"SYNTHETIC_ONLY");symlinkSync(blob,join(outside,"model.safetensors"));
    const code=`const fs=require('fs');const {installSttSpawnGuard}=await import(process.argv[1]);
      const root=process.argv[2],model=process.argv[3],target=process.argv[4];
      const cache=root+'/.test-tmp/'+process.pid+'-abcd';fs.mkdirSync(cache,{recursive:true});
      const old=process.env.VOICELAYER_TEST_STT_GUARD_ROOT;
      const state=JSON.parse(fs.readFileSync(old+'/stt-kernel-verified.json'));state.weights.push(target);
      fs.writeFileSync(cache+'/stt-kernel-verified.json',JSON.stringify(state));
      fs.writeFileSync(cache+'/voicelayer-test-stt-kernel-canary-v3',${JSON.stringify("#!/bin/sh\nexit 77\n")},{mode:0o700});
      fs.writeFileSync(cache+'/voicelayer-test-stt-weight-canary','SYNTHETIC_ONLY');
      process.env.VOICELAYER_TEST_STT_GUARD_ROOT=cache;process.env.VOICELAYER_PARAKEET_MODEL=model;
      fs.mkdirSync(root+'/child');installSttSpawnGuard(root+'/child',process.env.VOICELAYER_TEST_RUN_ROOT);
      throw Error('UNSAFE_CACHE_ACCEPTED');`;
    const x=Bun.spawnSync([process.execPath,"-e",code,join(import.meta.dir,"setup/stt-spawn-guard.ts"),root,outside,blob],{env:process.env});
    expect(x.exitCode).not.toBe(0);expect(x.stderr.toString()).toContain("STT guard kernel policy failed");expect(x.stderr.toString()).not.toContain("UNSAFE_CACHE_ACCEPTED");
  } finally {rmSync(outside,{recursive:true,force:true});}
});
