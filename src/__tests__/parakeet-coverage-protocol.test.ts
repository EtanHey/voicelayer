/** V34 protocol seams: real worker body (fake runtime, no MLX), real server pipe, pure scan. */
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { ParakeetServer, ParakeetServiceError } from "../parakeet-server";
import {
  chooseRetryGeometry, geometryInternalEnds, scanInternalWindowGaps, uncoveredGaps,
  PARAKEET_COVERAGE_RETRY_GEOMETRIES, PARAKEET_PRIMARY_GEOMETRY,
} from "../parakeet-coverage";

test("worker: primary geometry unchanged, allow-listed retry geometry passed through, window ends reported, others refused", async () => {
  const root = testTmp("v34-worker"); mkdirSync(root, { recursive: true });
  const script = join(root, "fake-runtime.py");
  writeFileSync(script, `import importlib.util,io,json,pathlib,sys,wave,types
spec=importlib.util.spec_from_file_location('worker',sys.argv[1]);w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
root=pathlib.Path(sys.argv[2]);frames=70*16000;p=root/'take.wav'
with wave.open(str(p),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(b'\\x00\\x00'*frames)
short=root/'short.wav'
with wave.open(str(short),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(b'\\x00\\x00'*16000)
class Array:
 def __truediv__(self,x):return self
 def astype(self,x):return self
class NP:
 float32='float32'
 def frombuffer(self,*a,**k):return Array()
class MX:
 def array(self,x):return x
 def synchronize(self):pass
class Model:
 def __init__(self):self.calls=[]
 def generate(self,a,**k):
  c,o=k['chunk_duration'],k['overlap_duration'];self.calls.append((c,o))
  n=a if isinstance(a,int) else frames
  start=0
  if not isinstance(a,int):
   while True:
    end=min(int(start+c*16000),frames);k['chunk_callback'](end,frames)
    if end>=frames:break
    start+=int((c-o)*16000)
  return types.SimpleNamespace(text='words',sentences=[types.SimpleNamespace(tokens=[types.SimpleNamespace(start=0.0,end=0.3)])])
m=Model()
reqs=[{'id':1,'op':'transcribe','audio_path':str(p)},
 {'id':2,'op':'transcribe','audio_path':str(p),'chunk_seconds':60,'overlap_seconds':15},
 {'id':3,'op':'transcribe','audio_path':str(p),'chunk_seconds':61,'overlap_seconds':15},
 {'id':4,'op':'transcribe','audio_path':str(p),'chunk_seconds':True,'overlap_seconds':15},
 {'id':5,'op':'health'}]
out=io.StringIO();assert w.serve(m,MX(),NP(),io.StringIO(''.join(json.dumps(x)+'\\n' for x in reqs)),out)==0
r=[json.loads(x) for x in out.getvalue().splitlines()]
assert m.calls==[(30.0,2.0),(60.0,15.0)],m.calls
assert r[0]['window_end_frames']==[480000,928000,1120000],r[0]['window_end_frames']
assert r[0]['window_geometry']=={'chunk_seconds':30.0,'overlap_seconds':2.0}
assert r[1]['window_end_frames']==[960000,1120000] and r[1]['window_geometry']=={'chunk_seconds':60.0,'overlap_seconds':15.0}
assert not r[2]['ok'] and r[2]['code']=='ValueError' and not r[3]['ok'] and r[4]['ready']
class Single:
 def generate(self,a,**k):return types.SimpleNamespace(text='one',sentences=[])
v=w.decode(Single(),MX(),NP(),short);assert v['window_end_frames']==[16000] and v['complete']
print('v34 worker groups passed')
`);
  const proc = Bun.spawn(["python3", "-B", script, join(import.meta.dir, "..", "parakeet-worker.py"), root], { env: process.env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect(stderr).toBe(""); expect(code).toBe(0); expect(stdout).toContain("v34 worker groups passed");
});

describe("server: retry geometry and remaining-budget deadline cross the private pipe", () => {
  const dir = testTmp("v34-server"), fixture = join(dir, "child.mjs");
  const servers: ParakeetServer[] = [];
  afterEach(async () => { await Promise.all(servers.splice(0).map(s => s.shutdown())); });
  function make() {
    mkdirSync(dir, { recursive: true });
    writeFileSync(fixture, `import { createInterface } from 'node:readline';
for await (const line of createInterface({input:process.stdin})) {
 const r=JSON.parse(line);
 if(r.op==='health'){process.stdout.write(JSON.stringify({id:r.id,ok:true,ready:true,protocol:1,pid:process.pid})+'\\n');continue;}
 if(r.audio_path==='slow')await new Promise(x=>setTimeout(x,300));
 process.stdout.write(JSON.stringify({id:r.id,ok:true,text:'seen',complete:true,input_frames:16000,covered_frames:16000,sample_rate:16000,
  last_token_end_s:null,inference_s:0,language:null,seen:{chunk:r.chunk_seconds??null,overlap:r.overlap_seconds??null}})+'\\n');
}`);
    const s = new ParakeetServer({ command: [process.execPath, fixture], startupMs: 3000, requestMs: 2000, stopMs: 1000,
      idleSeconds: () => 600, unloadWhenIdle: () => false, isBusy: () => false });
    servers.push(s); return s;
  }
  test("primary sends no geometry; retry sends the allow-listed one; timeoutMs only shortens the deadline", async () => {
    const s = make();
    expect((await s.transcribe("fast") as unknown as { seen: unknown }).seen).toEqual({ chunk: null, overlap: null });
    expect((await s.transcribe("fast", { geometry: { chunkSeconds: 60, overlapSeconds: 15 } }) as unknown as { seen: unknown }).seen).toEqual({ chunk: 60, overlap: 15 });
    let caught: unknown;
    try { await s.transcribe("slow", { timeoutMs: 40 }); } catch (error) { caught = error; }
    expect(caught).toBeInstanceOf(ParakeetServiceError);
    expect((caught as ParakeetServiceError).status).toBe("TIMEOUT");
    // A larger caller value cannot extend the configured 2 s request deadline: 300 ms still succeeds.
    expect((await s.transcribe("slow", { timeoutMs: 10_000_000 })).text).toBe("seen");
  });
});

describe("pure scan", () => {
  const base = { text: "x", input_frames: 70 * 16000, sample_rate: 16000, window_end_frames: [480000, 928000, 1120000] };
  test("overlapping/merged token spans do not invent gaps; out-of-order times are uncertain, not guessed", () => {
    const tokens = [{ start: 24, end: 24.3 }, { start: 24.1, end: 29.8 }, { start: 30, end: 30.2 }];
    const scan = scanInternalWindowGaps({ ...base, raw_token_times: tokens }, PARAKEET_PRIMARY_GEOMETRY);
    expect(scan).toMatchObject({ status: "OK", candidates: [] });
    expect(scanInternalWindowGaps({ ...base, raw_token_times: [{ start: 5, end: 5.2 }, { start: 4, end: 4.2 }] }, PARAKEET_PRIMARY_GEOMETRY))
      .toEqual({ status: "UNKNOWN", reason: "invalid-token-times" });
    expect(scanInternalWindowGaps({ ...base, window_end_frames: [480000, 400000, 1120000], raw_token_times: [] }, PARAKEET_PRIMARY_GEOMETRY))
      .toEqual({ status: "UNKNOWN", reason: "invalid-window-boundaries" });
  });
  test("a gap far from every internal window end is not this guard's business", () => {
    const tokens = [{ start: 1, end: 1.3 }, { start: 12, end: 12.3 }, { start: 13, end: 13.3 }];
    const scan = scanInternalWindowGaps({ ...base, raw_token_times: tokens }, PARAKEET_PRIMARY_GEOMETRY);
    expect(scan).toMatchObject({ status: "OK", candidates: [] });
  });
  test("speech below the minimum inside a gap is not flagged", () => {
    const gap = { afterTokenEndS: 25, beforeTokenStartS: 27, windowEndS: 30 };
    const probabilities = Array.from({ length: 2200 }, (_, i) => (i * 0.032 >= 25.5 && i * 0.032 < 26) ? 0.9 : 0.01);
    expect(uncoveredGaps([gap], probabilities, 0.3, 16000)).toEqual([]);
  });
  test("retry geometry choice is deterministic, bounded to the allow-list, and avoids the flagged gap", () => {
    const g = chooseRetryGeometry([{ afterTokenEndS: 24.8, beforeTokenStartS: 29.5, windowEndS: 30 }], 70 * 16000, 16000);
    expect(PARAKEET_COVERAGE_RETRY_GEOMETRIES).toContainEqual(g);
    expect(g).toEqual({ chunkSeconds: 60, overlapSeconds: 15 });
    for (const end of geometryInternalEnds(g, 70 * 16000, 16000)) expect(end < 24.8 || end > 29.5).toBe(true);
    expect(geometryInternalEnds(PARAKEET_PRIMARY_GEOMETRY, 70 * 16000, 16000)).toEqual([30, 58]);
  });
});
