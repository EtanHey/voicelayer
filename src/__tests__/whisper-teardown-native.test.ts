import { test, expect } from 'bun:test';
import { __resetWhisperServerStateForTests, stopServerAndWait } from '../whisper-server';
const binary = Bun.which('whisper-server');
const enabled = process.env.QA_VOICE_GOLDEN_LIVE === '1';
if (!binary || !enabled) console.warn('SKIP native teardown: requires whisper-server and S2_MODEL plus QA_VOICE_GOLDEN_LIVE=1 with heavy lock');
test.skipIf(!binary || !enabled)('owned real server starts and stops (requires S2_MODEL and native opt-in)', async () => {
 const proc = Bun.spawn([binary!, '-m', process.env.S2_MODEL!, '--port', '18997'], {env:process.env, stdout:'ignore',stderr:'inherit'});
 try {
  let ready = false;
  for (let i=0;i<120;i++) {
   if(proc.exitCode !== null) throw new Error('native startup exited');
   try { ready = (await fetch('http://127.0.0.1:18997/health')).ok; } catch {}
   if(ready) break;
   await Bun.sleep(500);
  }
  expect(ready).toBe(true);
  __resetWhisperServerStateForTests({proc, pid:proc.pid,port:18997,adopted:false} as any);
  await stopServerAndWait();
  expect(proc.exitCode).not.toBeNull();
 } finally { if(proc.exitCode===null) proc.kill('SIGKILL'); await proc.exited; __resetWhisperServerStateForTests(null); }
}, 90000);
