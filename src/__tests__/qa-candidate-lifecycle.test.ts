import { expect, test } from "bun:test";
import { join } from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import { createSpeechControl } from "../speech-control";
import { buildWhisperModelStatus } from "../model-status";
import { buildHealthResponse } from "../daemon-health";

const helper = join(import.meta.dir, "../../scripts/lib/qa-candidate-lifecycle.py");
const root = join(process.env.VOICELAYER_TEST_RUN_ROOT!, "qa23-safety");
mkdirSync(root, { recursive: true });
function python(body: string) {
  const result = Bun.spawnSync(["python3", "-c", `import runpy,os,json,signal\nfrom pathlib import Path\nfrom types import SimpleNamespace\ng=runpy.run_path(${JSON.stringify(helper)})['main'].__globals__\nroot=Path(${JSON.stringify(root)})\n${body}`],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  return { exit: result.exitCode, out: result.stdout.toString(), error: result.stderr.toString() };
}
for (const state of ["recording", "transcribing", "unknown", "idle"]) {
  test(`resident ${state} refusal evidence`, () => {
    writeFileSync(join(root, "recording-state.json"), JSON.stringify({ state, pid: process.pid }));
    const result = python("g['idle'](root,root)");
    expect(result.exit).toBe(state === "idle" ? 0 : 1);
    if (state !== "idle") expect(result.error).toContain("REFUSED");
  });
}
test("ask lock refuses idle and a missing file never proves idle", () => {
  const result = python("d=root/'ask';d.mkdir(exist_ok=True);(d/'voicelayer-session-x.lock').touch()\ntry:g['idle'](d,root);raise AssertionError('accepted ask')\nexcept RuntimeError:pass\ntry:g['idle'](root/'missing',root/'missing');raise AssertionError('accepted missing state')\nexcept FileNotFoundError:pass");
  expect(result.exit).toBe(0);
});
for (const player of ["afplay", "say", "edge-tts", "rec", "sox", "ffplay", "mpv", "mpg123", "unknown-child"]) {
  test(`refuses ${player} child while ask/speak has no session lock`, () => {
    const result = python(`g['refuse_activity']([(10,1,'/app/VoiceBar'),(11,10,'/bin/bun'),(12,11,'/bin/${player}')],[10],lambda pid:'mcp-server-daemon.ts' if pid==11 else '${player}',lambda owned:False)`);
    expect(result.exit).toBe(1); expect(result.error).toContain("REFUSED: playback/capture");
  });
}
test("refuses Qwen TCP activity and unknown evidence", () => {
  const result = python("rows=[(10,1,'/app/VoiceBar'),(11,10,'/bin/bun')]\ntry:g['refuse_activity'](rows,[10],lambda pid:'mcp-server-daemon.ts',lambda owned:True);raise AssertionError('accepted Qwen')\nexcept RuntimeError:pass\ntry:g['refuse_activity'](rows,[10],lambda pid:'',lambda owned:False);raise AssertionError('accepted unknown')\nexcept RuntimeError:pass");
  expect(result.exit).toBe(0);
});
test("a player appearing at the final sample prevents SIGTERM", () => {
  const result = python("g['pids']=lambda app:[10];g['idle']=lambda *a:None\nrows=iter([[(10,1,'/app/VoiceBar')],[(10,1,'/app/VoiceBar'),(12,10,'/bin/afplay')]])\ng['processes']=lambda:next(rows);g['command_line']=lambda pid:'afplay';g['qwen_connections']=lambda owned:False\ng['os'].kill=lambda *a:(_ for _ in ()).throw(AssertionError('unsafe signal'))\ng['quit_app'](Path('/app'))");
  expect(result.exit).toBe(1); expect(result.error).toContain("REFUSED: playback/capture");
});
test("unhealthy QA refuses normally; force sends exact-PID SIGTERM only", () => {
  const result = python("g['pids']=lambda app:[10];rows=[(10,1,'/qa/VoiceBar')]\ng['processes']=lambda:list(rows);g['qa_health']=lambda env:(_ for _ in ()).throw(RuntimeError('unhealthy'))\nsignals=[]\ndef signal_pid(pid,sig):\n signals.append((pid,sig));rows.clear()\ng['os'].kill=signal_pid\nenv={'VOICELAYER_TMP_ROOT':str(root),'VOICELAYER_STATE_DIR':str(root)}\ntry:g['quit_app'](Path('/qa'),env);raise AssertionError('accepted unhealthy')\nexcept RuntimeError:pass\nassert not signals\ng['quit_app'](Path('/qa'),env,force=True)\nassert signals==[(10,signal.SIGTERM)]");
  expect(result.exit).toBe(0); expect(result.error).toBe("");
});
test("restore kickstarts the canonical job without -k and validates its PID", () => {
  const result = python("g['job_info']=lambda:42;g['APP']=root/'absent.app';g['B']['environment']=lambda:{}\ncalled=[];g['quit_app']=lambda *a,**k:called.append(k);g['wait_ready']=lambda *a:None\ng['pids']=lambda app:[42];g['subprocess'].run=lambda argv,**kw:called.append(argv)\ng['restore_resident']()\nassert called==[{'force':False},['/bin/launchctl','kickstart',g['LABEL']]]\ng['pids']=lambda app:[99]\ntry:g['restore_resident']();raise AssertionError('accepted wrong job PID')\nexcept RuntimeError:pass");
  expect(result.exit).toBe(0); expect(result.error).toBe("");
});
test("respawn aborts startup; stale socket inodes cannot prove readiness", () => {
  const result = python("g['pids']=lambda app:[42]\ntry:g['wait_ready'](g['APP'],{},True);raise AssertionError('accepted respawn')\nexcept RuntimeError:pass\ng['pids']=lambda app:[42] if app==g['APP'] else [];g['time'].sleep=lambda seconds:None\ng['connected']=lambda *args:(_ for _ in ()).throw(OSError('stale inode'))\ntry:g['wait_ready'](g['APP'],{'VOICELAYER_SOCKET_PATH':'stale'});raise AssertionError('accepted stale inode')\nexcept RuntimeError:pass");
  expect(result.exit).toBe(0);
});
test("the five-second down window detects a delayed respawn", () => {
  const result = python("ticks=iter([0,1,2,3,4,5]);g['time'].monotonic=lambda:next(ticks);g['time'].sleep=lambda seconds:None\ncalls=iter([[],[],[42]]);g['pids']=lambda app:next(calls)\ng['stay_down']()");
  expect(result.exit).toBe(1); expect(result.error).toContain("REFUSED: resident respawned");
});
test("QA health is authenticated and off by default", async () => {
  const old = process.env.VOICELAYER_QA_HEALTH;
  const modelStatus = buildWhisperModelStatus({ configuredPath: null, configuredSizeBytes: null, residentHealthy: false, launchRecord: null, configuredEffort: "fast" });
  const control = createSpeechControl("qa-token", () => ({ ...buildHealthResponse({ queueDepth: 0, recordingState: "idle", modelStatus }), type: "health", recording_jobs: [], processing_count: 0, mic_take_id: null }));
  try {
    delete process.env.VOICELAYER_QA_HEALTH;
    await expect(control({ cmd: "health", token: "qa-token" })).rejects.toThrow("Invalid speech command");
    process.env.VOICELAYER_QA_HEALTH = "1";
    await expect(control({ cmd: "health", token: "wrong" })).rejects.toThrow("Unauthorized");
    expect((await control({ cmd: "health", token: "qa-token" })).recording_state).toBe("idle");
  } finally {
    if (old === undefined) delete process.env.VOICELAYER_QA_HEALTH; else process.env.VOICELAYER_QA_HEALTH = old;
  }
});
test("unknown KeepAlive configuration refuses before any launchctl call", () => {
  const result = python("g['HOME']=root/'job-home';path=g['HOME']/'Library/LaunchAgents/com.voicelayer.voicebar.plist';path.parent.mkdir(parents=True,exist_ok=True)\nconfig={'Label':'com.voicelayer.voicebar','ProgramArguments':[str(g['RESIDENT']/'Contents/MacOS/VoiceBar')],'KeepAlive':True,'RunAtLoad':True,'StandardOutPath':str(g['HOME']/'Library/Logs/voicelayer/voicebar.log'),'StandardErrorPath':str(g['HOME']/'Library/Logs/voicelayer/voicebar-err.log')}\npath.write_bytes(g['plistlib'].dumps(config))\ng['subprocess'].run=lambda *a,**k:(_ for _ in ()).throw(AssertionError('unsafe host command'))\ng['job_info']()");
  expect(result.exit).toBe(1); expect(result.error).toContain("REFUSED: resident supervision/KeepAlive");
});
test("a respawn rollback restores supervision without automatically forcing QA", () => {
  const result = python("g['job_info']=lambda:None;g['pids']=lambda app:[];g['APP']=root/'rollback.app'\ninfo=g['APP']/'Contents/Info.plist';info.parent.mkdir(parents=True,exist_ok=True);info.write_bytes(g['plistlib'].dumps({'CFBundleIdentifier':g['B']['IDENTITY'],'CFBundleShortVersionString':'2.3.0','LSEnvironment':{}}))\ng['B']['prepare']=lambda env:None;g['quit_app']=lambda *a,**k:None\ng['subprocess'].run=lambda *a,**k:(_ for _ in ()).throw(AssertionError('unsafe host command'))\ng['stay_down']=lambda:(_ for _ in ()).throw(RuntimeError('resident respawned'))\nforces=[];g['restore_resident']=lambda force=False:forces.append(force)\ntry:g['switch']();raise AssertionError('accepted respawn')\nexcept RuntimeError as error:assert 'resident supervision restored' in str(error) and 'resident respawned' in str(error)\nassert forces==[False]");
  expect(result.exit).toBe(0); expect(result.error).toBe("");
});
test("think mode has an explicit isolated log destination", () => {
  const result = python("env=g['B']['environment'](Path('/qa'),Path('/nonexistent-qa-home'))\nassert env['QA_VOICE_THINK_FILE']=='/qa/tmp/thinking.md'");
  expect(result.exit).toBe(0);
});
test("KeepAlive qualification requires a proven clean stopped exit", () => {
  const result = python("g['HOME']=root/'clean-job';path=g['HOME']/'Library/LaunchAgents/com.voicelayer.voicebar.plist';path.parent.mkdir(parents=True,exist_ok=True)\nconfig={'Label':'com.voicelayer.voicebar','ProgramArguments':[str(g['RESIDENT']/'Contents/MacOS/VoiceBar')],'KeepAlive':{'SuccessfulExit':False},'RunAtLoad':True,'StandardOutPath':str(g['HOME']/'Library/Logs/voicelayer/voicebar.log'),'StandardErrorPath':str(g['HOME']/'Library/Logs/voicelayer/voicebar-err.log')}\npath.write_bytes(g['plistlib'].dumps(config))\noutput='\\n'.join(key+' = '+value for key,value in {'path':str(path),'program':config['ProgramArguments'][0],'stdout path':config['StandardOutPath'],'stderr path':config['StandardErrorPath']}.items())\ng['subprocess'].run=lambda *a,**k:SimpleNamespace(returncode=0,stdout=output+'\\nlast exit code = 1\\n')\ntry:g['job_info'](stopped=True);raise AssertionError('accepted crash')\nexcept RuntimeError:pass\ng['subprocess'].run=lambda *a,**k:SimpleNamespace(returncode=0,stdout=output+'\\nlast exit code = 0\\n')\nassert g['job_info'](stopped=True) is None");
  expect(result.exit).toBe(0); expect(result.error).toBe("");
});
