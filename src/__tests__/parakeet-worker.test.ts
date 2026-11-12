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
aspec=importlib.util.spec_from_file_location('fixture_alignment',sys.argv[3]);alignment=importlib.util.module_from_spec(aspec);aspec.loader.exec_module(alignment)
for name in ('mlx_audio','mlx_audio.stt','mlx_audio.stt.models','mlx_audio.stt.models.nemo'):sys.modules[name]=types.ModuleType(name)
sys.modules['mlx_audio.stt.models.nemo'].alignment=alignment
def audio(name,frames,rate=16000):
 p=root/name
 with wave.open(str(p),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(rate);f.writeframes(b'\\x00\\x00'*frames)
 return p
short=audio('short.wav',16000);mid=audio('mid.wav',480000);long=audio('long.wav',963584);foreign=audio('foreign.wav',100,8000)
class Array:
 dtype='bfloat16'
 def __init__(self,start=0,end=0):self.start,self.end=start,end
 def __getitem__(self,s):return Array(s.start,s.stop)
 def __truediv__(self,x):return self
 def astype(self,x):return self
class NP:
 float32='float32'
 def frombuffer(self,pcm,**k):return Array(0,len(pcm)//2)
class MX:
 bfloat16='bfloat16'
 def array(self,x):return x
 def synchronize(self):pass
 def clear_cache(self):pass
class Model:
 def __init__(self):self.n=0;self.windows=[]
 def generate(self,a,**k):
  self.n+=1
  return types.SimpleNamespace(text='',sentences=[])
 def _log_mel_spectrogram(self,a):return a
 def decode(self,mel):
  self.windows.append((mel.start,mel.end))
  words=[(' complete',1.0),(' response',59.0)] if len(self.windows)==1 else [(' response',59.0)]
  return [types.SimpleNamespace(sentences=[types.SimpleNamespace(tokens=[alignment.AlignedToken(id=i,text=t,start=s-mel.start/16000,duration=0.4) for i,(t,s) in enumerate(words) if mel.start/16000<=s<mel.end/16000])])]
model=Model();stream=io.StringIO(''.join(json.dumps(x)+'\\n' for x in [
 {'id':1,'op':'health'},{'id':2,'op':'transcribe','audio_path':str(short)},
 {'id':3,'op':'transcribe','audio_path':str(long)},{'id':4,'op':'health'},
 {'id':5,'op':'transcribe','audio_path':str(foreign)},{'id':6,'op':'health'},{'id':7,'op':'shutdown'}]))
out=io.StringIO();assert w.serve(model,MX(),NP(),stream,out)==0;r=[json.loads(x) for x in out.getvalue().splitlines()]
assert len(r)==7 and model.n==1 and model.windows==[(0,480000),(448000,963584)] and r[1]['text']=='' and r[2]['covered_frames']==963584 and r[2]['text']=='complete response' and not r[4]['ok'] and r[5]['ready']
class Broken:
 def generate(self,*a,**k):raise MemoryError()
out=io.StringIO();assert w.serve(Broken(),MX(),NP(),io.StringIO(json.dumps({'id':1,'op':'transcribe','audio_path':str(short)})+'\\n'+json.dumps({'id':2,'op':'health'})+'\\n'),out)==1
r=[json.loads(x) for x in out.getvalue().splitlines()];assert len(r)==1 and r[0]['fatal'] and r[0]['code']=='MemoryError'
class BadCoverage:
 def generate(self,*a,**k):k['chunk_callback'](10,480000);return types.SimpleNamespace(text='partial',sentences=[types.SimpleNamespace(tokens=[types.SimpleNamespace(start=0,end=0.2,text="partial")])])
try:w.decode(BadCoverage(),MX(),NP(),mid);assert False
except ValueError as e:
 assert e.attempt['text']=='partial' and e.attempt['covered_frames']==10 and not e.attempt['complete'] and e.attempt['raw_token_times']==[{'start':0,'end':0.2,'text':'partial'}]
out=io.StringIO();assert w.serve(BadCoverage(),MX(),NP(),io.StringIO(json.dumps({'id':1,'op':'transcribe','audio_path':str(mid)})+'\\n'),out)==0
r=json.loads(out.getvalue());assert not r['ok'] and r['status']=='PARTIAL' and r['attempt']['text']=='partial' and r['attempt']['covered_frames']==10
print('7 groups passed: persistent object/empty-to-success/whole frames over planned windows/foreign WAV/error continuation/fatal stop/partial coverage')
`);
  const proc = Bun.spawn(["python3", "-B", script, join(import.meta.dir, "..", "parakeet-worker.py"), root, join(import.meta.dir, "fixtures", "mlx-audio-0.6.3", "alignment.py")], { env: process.env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect(code).toBe(0); expect(stderr).toBe(""); expect(stdout).toContain("7 groups passed");
});
