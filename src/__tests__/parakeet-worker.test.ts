/** Pure fake-runtime tests of the real Python worker body. Never import MLX. */
import { test, expect } from "bun:test";
import { mkdirSync, writeFileSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { join } from "path";

test("Python worker persistence, full frames, errors and fatal stop", async () => {
  const root = testTmp("parakeet-python"); mkdirSync(root, { recursive: true });
  const script = join(root, "fake-runtime.py");
  writeFileSync(script, `import importlib.util,io,json,pathlib,sys,wave,types
spec=importlib.util.spec_from_file_location('worker',sys.argv[1]);w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
root=pathlib.Path(sys.argv[2])
def audio(name,frames,rate=16000):
 p=root/name
 with wave.open(str(p),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(b'\\x00\\x00'*frames)
 return p
short=audio('short.wav',16000);long=audio('long.wav',963584);foreign=audio('foreign.wav',100,8000)
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
 def __init__(self):self.n=0
 def generate(self,a,**k):
  self.n+=1
  if self.n>1:k['chunk_callback'](963584,963584)
  return types.SimpleNamespace(text='' if self.n==1 else 'complete response',sentences=[])
model=Model();stream=io.StringIO(''.join(json.dumps(x)+'\\n' for x in [
 {'id':1,'op':'health'},{'id':2,'op':'transcribe','audio_path':str(short)},
 {'id':3,'op':'transcribe','audio_path':str(long)},{'id':4,'op':'health'},
 {'id':5,'op':'transcribe','audio_path':str(foreign)},{'id':6,'op':'health'},{'id':7,'op':'shutdown'}]))
out=io.StringIO();assert w.serve(model,MX(),NP(),stream,out)==0;r=[json.loads(x) for x in out.getvalue().splitlines()]
assert len(r)==7 and model.n==2 and r[1]['text']=='' and r[2]['covered_frames']==963584 and not r[4]['ok'] and r[5]['ready']
class Broken:
 def generate(self,*a,**k):raise MemoryError()
out=io.StringIO();assert w.serve(Broken(),MX(),NP(),io.StringIO(json.dumps({'id':1,'op':'transcribe','audio_path':str(short)})+'\\n'+json.dumps({'id':2,'op':'health'})+'\\n'),out)==1
r=[json.loads(x) for x in out.getvalue().splitlines()];assert len(r)==1 and r[0]['fatal'] and r[0]['code']=='MemoryError'
class BadCoverage:
 def generate(self,*a,**k):k['chunk_callback'](10,963584);return types.SimpleNamespace(text='partial',sentences=[types.SimpleNamespace(tokens=[types.SimpleNamespace(start=0,end=0.2)])])
try:w.decode(BadCoverage(),MX(),NP(),long);assert False
except ValueError as e:
 assert e.attempt['text']=='partial' and e.attempt['covered_frames']==10 and not e.attempt['complete'] and e.attempt['raw_token_times']==[{'start':0,'end':0.2}]
out=io.StringIO();assert w.serve(BadCoverage(),MX(),NP(),io.StringIO(json.dumps({'id':1,'op':'transcribe','audio_path':str(long)})+'\\n'),out)==0
r=json.loads(out.getvalue());assert not r['ok'] and r['status']=='PARTIAL' and r['attempt']['text']=='partial' and r['attempt']['covered_frames']==10
print('7 groups passed: persistent object/empty-to-success/whole frames/foreign WAV/error continuation/fatal stop/partial coverage')
`);
  const proc = Bun.spawn(["python3", "-B", script, join(import.meta.dir, "..", "parakeet-worker.py"), root], { env: process.env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect(code).toBe(0); expect(stderr).toBe(""); expect(stdout).toContain("7 groups passed");
});
