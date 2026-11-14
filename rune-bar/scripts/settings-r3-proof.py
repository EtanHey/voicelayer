"""Fixture-only headless frames and rendered regression measurements. No native input."""
import json, math, os, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True,exist_ok=True)
script=OUT/'flick-r3-events.json'
SCRATCH=ROOT.parent/'.build.noindex/r3'
BIN=ROOT.parent/'.build.noindex/rune-target/debug/settings'
PIC=ROOT/'docs/pictures'
SCRATCH.mkdir(parents=True,exist_ok=True)
def run(args,tab=0,height=640,theme='dark',variant=None):
 env=os.environ.copy()
 for key in list(env):
  if key.startswith('VOICELAYER_RUNE_SETTINGS_'): del env[key]
 env.update(VOICELAYER_RUNE_SETTINGS_TAB=str(tab),VOICELAYER_RUNE_SETTINGS_STATE=str(SCRATCH/'layout.json'),VOICELAYER_RUNE_SCREEN_HEIGHT='900')
 if variant:env['VOICELAYER_RUNE_SETTINGS_'+variant]='1'
 (SCRATCH/'layout.json').write_text(json.dumps({'height':height}))
 p=subprocess.run([str(BIN),'--size',f'720x{height}','--theme',theme,*map(str,args)],env=env,capture_output=True,text=True)
 with (OUT/'render-r3.log').open('a') as f:f.write(p.stderr+p.stdout)
 if p.returncode:raise RuntimeError(p.stderr)
def flat(v):
 if isinstance(v,dict):
  if 'rect' in v and 'key' in v:yield v
  for x in v.values():yield from flat(x)
 elif isinstance(v,list):
  for x in v:yield from flat(x)
if not os.environ.get('SETTINGS_MEASURE_ONLY'):
 for theme in ['dark','light']:
  for h in [640,900]:
   for tab,name in enumerate(['general','transcription','dictionary','speech','history']):
    run(['--snap',PIC/f'settings-{name}-{h}-{theme}.png','--tree',SCRATCH/f'{name}-{h}-{theme}.json','--at','1'],tab,h,theme)
   for variant,tab,name in [('BROKEN',0,'broken'),('LOCKED',1,'locked'),('UNKNOWN',1,'unknown'),('LOCKED',3,'locked-speech')]:
    run(['--snap',PIC/f'settings-{name}-{h}-{theme}.png','--at','1'],tab,h,theme,variant)
 print('36 fixture pictures rendered',flush=True)
 
 flick=[]
 for j in range(3):
  t=j*.48+.05;flick.append({'t':t,'type':'drag','key':'pager','dx':-160,'dy':0,'dur':.16})
 script=OUT/'flick-r3-events.json';script.write_text(json.dumps(flick,indent=2))
 run(['--script',script,'--frames',45,'--fps',30,'--out',SCRATCH/'flick-frames','--video',OUT/'flick-r3.mp4'])
measure=[]
for i in range(45):
 tree=SCRATCH/'frame-tree.json'
 run(['--script',script,'--fps',30,'--at',str(i/30),'--tree',tree])
 es=json.loads(tree.read_text())['elements']
 headings=[dict(text=e.get('text',e.get('key')),x=e['rect'][0]) for e in es if e.get('text') in ['Controls','Recognizer','Short'] or e.get('key')=='search']
 measure.append(dict(frame=i,time=i/30,headings=headings))
(OUT/'flick-r3.json').write_text(json.dumps(measure,indent=2))
print('flick and 45 heading samples rendered',flush=True)

# Critical REFLOW spring (0.4 s, zero bounce): compare each release against its
# largest possible 1/30 s displacement, including every possible sampling phase.
w=2*math.pi/.4;dt=1/30
f=lambda t:(1+w*t)*math.exp(-w*t)
t_peak=dt/(math.exp(w*dt)-1)
fraction=f(t_peak)-f(t_peak+dt)
summary=[]
for start,end,name,rest in [(6,16,'Recognizer',80),(21,31,'search',24),(35,44,'Short',80)]:
 xs=[next(e['x'] for e in measure[i]['headings'] if e['text']==name) for i in range(start,end+1)]
 steps=[a-b for a,b in zip(xs,xs[1:])]
 bound=abs(xs[0]-rest)*fraction
 assert all(step>=-.05 for step in steps), (name,'reversal',steps)
 assert max(steps)<=bound+.1,(name,'jump',max(steps),bound)
 assert sum(step>1 for step in steps)>=5,(name,'cut to rest')
 summary.append(dict(heading=name,release_frame=start,max_step=max(steps),spring_max_step=bound,animating=True))
(OUT/'flick-r3-proof.json').write_text(json.dumps(summary,indent=2))
print('3/3 flicks monotonic and bounded by REFLOW largest step',flush=True)
