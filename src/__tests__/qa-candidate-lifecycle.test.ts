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
  const result = Bun.spawnSync(["python3", "-c", `import runpy,os,json,signal\nfrom pathlib import Path\nfrom types import SimpleNamespace\ng=runpy.run_path(${JSON.stringify(helper)})['main'].__globals__\ng['read_plist']=lambda path:g['plistlib'].loads(path.read_bytes())\nroot=Path(${JSON.stringify(root)})\ng['HOME']=root/'fixture-home';g['BASE']=root/'fixture-candidate'\n${body}`],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  return { exit: result.exitCode, out: result.stdout.toString(), error: result.stderr.toString() };
}
test.each(["idle", "afplay", "foreign", "impostor", "recording", "open", "pending", "unknown", "qa", "qa-open", "dead", "wrong-parent", "wrong-session", "outside-bundle", "direct-argv"])("lifetime booking safety: %s", (mode) => {
  const result = python(`mode=${JSON.stringify(mode)};d=root/mode;d.mkdir(exist_ok=True)
g['HOME']=d/'home';g['BASE']=d/'candidate';g['RESIDENT']=d/'resident/VoiceBar.app';g['APP']=d/'qa/VoiceBar.app';app=g['APP'] if mode.startswith('qa') else g['RESIDENT']
rows=[(10,1,str(app/'Contents/MacOS/VoiceBar')),(11,10,'/bin/bun')]
if mode=='afplay':rows.append((12,11,'/usr/bin/afplay'))
if mode=='foreign':rows.append((21,1,'/bin/bun'))
if mode=='wrong-parent':rows[1]=(11,99,'/bin/bun')
g['processes']=lambda:rows
argv=[str(d/'.bun/bin/bun'),'run',str(app/'Contents/Resources/src/mcp-server-daemon.ts')]
if mode=='outside-bundle':argv[2]=str(d/'foreign/Contents/Resources/src/mcp-server-daemon.ts')
if mode=='direct-argv':argv.remove('run')
g['command_line']=lambda pid:('/bin/bun /fixture/other.ts /fixture/src/mcp-server-daemon.ts' if mode=='impostor' else ' '.join(argv)) if pid==11 else 'afplay'
g['os'].kill=lambda pid,sig:None if sig==0 else (_ for _ in ()).throw(AssertionError('signal'))
if mode=='dead':g['os'].kill=lambda pid,sig:(_ for _ in ()).throw(ProcessLookupError('dead'))
if mode=='unknown':g['command_line']=lambda pid:(_ for _ in ()).throw(OSError('unreadable process'))
lock=d/'voicelayer-session-fixture.lock';pid=21 if mode=='foreign' else 11
lock.write_text(json.dumps({'pid':pid,'sessionId':'other' if mode=='wrong-session' else 'mcp-'+str(pid)}));before=lock.read_bytes()
(d/'recording-state.json').write_text(json.dumps({'state':'recording' if mode=='recording' else 'idle','pid':11}))
if mode in ['open','pending','qa-open']:
 index=(g['BASE']/'home' if mode.startswith('qa') else g['HOME'])/('.local/share/voicelayer/recordings.speech-'+mode.split('-')[-1]);index.mkdir(parents=True);(index/'active-ask').touch()
health=(lambda:{'recording_state':'idle','queue_depth':0,'processing_count':0,'recording_jobs':[]}) if mode.startswith('qa') else None
try:g['idle'](d,d,health);g['refuse_activity'](rows,[10],g['command_line'],lambda owned:False)
finally:assert lock.read_bytes()==before`);
  expect(result.exit).toBe(mode === "idle" || mode === "qa" ? 0 : 1);
  if (mode === "dead") expect(result.error).toContain("REFUSED: lifetime booking owner exited");
});
test.skipIf(process.platform !== "darwin")("Apple parser accepts the installed template comment without rewriting it", () => {
  const result = python(`g['HOME']=root/'apple-plist-home'
path=g['HOME']/'Library/LaunchAgents/com.voicelayer.voicebar.plist';path.parent.mkdir(parents=True,exist_ok=True)
raw=(g['B']['ROOT']/'launchd/com.voicelayer.voicebar.plist').read_bytes().replace(b'__VOICEBAR_LOG_DIR__',str(g['HOME']/'Library/Logs/voicelayer').encode())
assert b'mode 600 -- /tmp' in raw;path.write_bytes(raw)
if 'read_plist' in g['B']:g['read_plist']=g['B']['read_plist']
output=chr(10).join(key+' = '+value for key,value in {'path':str(path),'program':str(g['RESIDENT']/'Contents/MacOS/VoiceBar'),'stdout path':str(g['HOME']/'Library/Logs/voicelayer/voicebar.log'),'stderr path':str(g['HOME']/'Library/Logs/voicelayer/voicebar-err.log')}.items())
run=g['subprocess'].run
g['subprocess'].run=lambda argv,**kw:run(argv,**kw) if argv[0]=='/usr/bin/plutil' else SimpleNamespace(returncode=0,stdout=output)
assert g['job_info']() is None
assert path.read_bytes()==raw`);
  expect(result.error).toBe(""); expect(result.exit).toBe(0);
});
for (const state of ["recording", "transcribing", "unknown", "idle"]) {
  test(`resident ${state} refusal evidence`, () => {
    writeFileSync(join(root, "recording-state.json"), JSON.stringify({ state, pid: process.pid }));
    const result = python("g['idle'](root,root)");
    expect(result.exit).toBe(state === "idle" ? 0 : 1);
    if (state !== "idle") expect(result.error).toContain("REFUSED");
  });
}
test.each(["stale", "newer", "equal", "non-idle", "unreadable", "malformed", "wrong-weekday", "wrong-parent", "outside", "multiple", "live"])("resident stale-state rule: %s", (mode) => {
  const result = python(`mode=${JSON.stringify(mode)};d=root/('stale-state-'+mode);d.mkdir(exist_ok=True)
app=g['RESIDENT']=d/'fixtures.noindex/VoiceBar.app'
rows=[(10,1,str(app/'Contents/MacOS/VoiceBar')),(11,10,'/bin/bun')]
if mode=='wrong-parent':rows[1]=(11,1,'/bin/bun')
if mode=='multiple':rows.append((12,10,'/bin/bun'))
g['processes']=lambda:rows
g['command_line']=lambda pid:'/bin/bun run '+str((d/'fixtures.noindex/foreign.app' if mode=='outside' else app)/'Contents/Resources/src/mcp-server-daemon.ts')
probes=[]
def alive(pid,sig):
 assert sig==0,'must never signal'
 probes.append(pid)
 if pid==99 and mode!='live':raise ProcessLookupError('dead fixture pid')
g['os'].kill=alive
starts=[]
def start(argv,**kw):
 assert argv==['/bin/ps','-o','lstart=','-p','11']
 assert kw['env']['LC_ALL']=='C' and kw['env']['TZ']=='UTC'
 starts.append(11)
 if mode=='unreadable':raise g['subprocess'].CalledProcessError(1,argv)
 return 'bad time' if mode=='malformed' else ('Fri' if mode=='wrong-weekday' else 'Thu')+' Jan  1 00:01:40 1970\\n'
g['subprocess'].check_output=start
path=d/'recording-state.json';path.write_text(json.dumps({'state':'recording' if mode=='non-idle' else 'idle','pid':99}))
stamp={'newer':101,'equal':100}.get(mode,99)*10**9;os.utime(path,ns=(stamp,stamp));before=path.read_bytes()
try:g['idle'](d,d)
finally:assert path.read_bytes()==before and path.stat().st_mtime_ns==stamp
if mode=='live':assert probes==[99] and starts==[]
if mode=='stale':assert starts==[11]`);
  expect(result.exit).toBe(mode === "stale" || mode === "live" ? 0 : 1);
  if (mode !== "stale" && mode !== "live") {
    expect(result.error).toContain("REFUSED:");
    expect(result.error).not.toContain("ProcessLookupError");
  }
});
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

test.each(["bundled", "outside", "unknown", "duplicate"])("post-launch daemon provenance: %s", (mode) => {
  const result = python(`mode=${JSON.stringify(mode)};app=root/'provenance.app'
rows=[(10,1,str(app/'Contents/MacOS/VoiceBar')),(11,10,'/bin/bun')]
if mode=='duplicate':rows.append((12,10,'/bin/bun'))
g['processes']=lambda:rows;g['os'].kill=lambda pid,sig:None
g['command_line']=lambda pid:'/bin/bun run '+str((app if mode=='bundled' else root/'foreign.app')/'Contents/Resources/src/mcp-server-daemon.ts')
if mode=='unknown':g['command_line']=lambda pid:(_ for _ in ()).throw(OSError('unreadable argv'))
g['require_bundled_daemon'](app)`);
  expect(result.exit).toBe(mode === "bundled" ? 0 : 1);
});

test.each([false, true])("provenance rollback never forces candidate retirement (blocked=%s)", (blocked) => {
  const result = python(`blocked=${blocked ? "True" : "False"};g['job_info']=lambda **kw:None;g['pids']=lambda app:[]
g['APP']=root/'provenance-rollback.app';info=g['APP']/'Contents/Info.plist';info.parent.mkdir(parents=True,exist_ok=True)
info.write_bytes(g['plistlib'].dumps({'CFBundleIdentifier':g['B']['IDENTITY'],'CFBundleShortVersionString':'2.3.0','LSEnvironment':{}}))
g['B']['prepare']=lambda env:None;g['quit_app']=lambda *a,**kw:None
g['subprocess'].run=lambda *a,**kw:None;g['wait_ready']=lambda *a,**kw:None;g['stay_down']=lambda:None
g['require_bundled_daemon']=lambda app:(_ for _ in ()).throw(RuntimeError('outside bundle'))
forces=[]
def restore(force=False):
 forces.append(force)
 if blocked:raise RuntimeError('voice session/ask lock exists')
g['restore_resident']=restore
try:g['switch']();raise AssertionError('accepted outside bundle')
except RuntimeError as error:
 assert ('RECOVERY_REQUIRED' if blocked else 'Switch aborted') in str(error)
 if blocked:assert '--force-resident' in str(error)
assert forces==[False]`);
  expect(result.error).toBe(""); expect(result.exit).toBe(0);
});

test.each(["queue", "processing", "jobs", "capture-error", "missing", "unhealthy"])("QA lifetime booking refuses %s health", (mode) => {
  const result = python(`mode=${JSON.stringify(mode)};d=root/('qa-health-'+mode);d.mkdir(exist_ok=True)
app=g['APP'];g['processes']=lambda:[(10,1,str(app/'Contents/MacOS/VoiceBar')),(11,10,'/bin/bun')]
g['os'].kill=lambda pid,sig:None;g['command_line']=lambda pid:'/bin/bun run '+str(app/'Contents/Resources/src/mcp-server-daemon.ts')
(d/'voicelayer-session-health.lock').write_text(json.dumps({'pid':11,'sessionId':'mcp-11'}))
data={'recording_state':'idle','queue_depth':0,'processing_count':0,'recording_jobs':[]}
if mode=='queue':data['queue_depth']=1
if mode=='processing':data['processing_count']=1
if mode=='jobs':data['recording_jobs']=[{'take_id':'busy'}]
if mode=='capture-error':data['capture_error']='unknown'
if mode=='missing':data.pop('queue_depth')
def health():
 if mode=='unhealthy':raise RuntimeError('unavailable')
 return data
g['idle'](d,d,health)`);
  expect(result.exit).toBe(1); expect(result.error).toContain(mode === "unhealthy" ? "unavailable" : "REFUSED");
});
test("KeepAlive qualification requires a proven clean stopped exit", () => {
  const result = python("g['HOME']=root/'clean-job';path=g['HOME']/'Library/LaunchAgents/com.voicelayer.voicebar.plist';path.parent.mkdir(parents=True,exist_ok=True)\nconfig={'Label':'com.voicelayer.voicebar','ProgramArguments':[str(g['RESIDENT']/'Contents/MacOS/VoiceBar')],'KeepAlive':{'SuccessfulExit':False},'RunAtLoad':True,'StandardOutPath':str(g['HOME']/'Library/Logs/voicelayer/voicebar.log'),'StandardErrorPath':str(g['HOME']/'Library/Logs/voicelayer/voicebar-err.log')}\npath.write_bytes(g['plistlib'].dumps(config))\noutput='\\n'.join(key+' = '+value for key,value in {'path':str(path),'program':config['ProgramArguments'][0],'stdout path':config['StandardOutPath'],'stderr path':config['StandardErrorPath']}.items())\ng['subprocess'].run=lambda *a,**k:SimpleNamespace(returncode=0,stdout=output+'\\nlast exit code = 1\\n')\ntry:g['job_info'](stopped=True);raise AssertionError('accepted crash')\nexcept RuntimeError:pass\ng['subprocess'].run=lambda *a,**k:SimpleNamespace(returncode=0,stdout=output+'\\nlast exit code = 0\\n')\nassert g['job_info'](stopped=True) is None");
  expect(result.exit).toBe(0); expect(result.error).toBe("");
});

test.skipIf(process.platform !== "darwin")("Apple parser failure refuses without rewriting the input", () => {
  const result = python("path=root/'invalid.plist';path.write_bytes(b'<plist><dict>')\ntry:g['B']['read_plist'](path);raise AssertionError('accepted invalid plist')\nexcept g['subprocess'].CalledProcessError:pass\nassert path.read_bytes()==b'<plist><dict>'");
  expect(result.error).toBe(""); expect(result.exit).toBe(0);
});
