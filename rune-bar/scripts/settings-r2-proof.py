"""Fixture-only headless frames and rendered regression measurements. No native input."""
import json, os, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=Path(sys.argv[1]).resolve()
SCRATCH=ROOT.parent/'.build.noindex/r2'
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
 with (OUT/'render-r2.log').open('a') as f:f.write(p.stderr+p.stdout)
 if p.returncode:raise RuntimeError(p.stderr)
def flat(v):
 if isinstance(v,dict):
  if 'rect' in v and 'key' in v:yield v
  for x in v.values():yield from flat(x)
 elif isinstance(v,list):
  for x in v:yield from flat(x)
for theme in ['dark','light']:
 for h in [640,900]:
  for tab,name in enumerate(['general','transcription','dictionary','speech','history']):
   run(['--snap',PIC/f'settings-{name}-{h}-{theme}.png','--tree',SCRATCH/f'{name}-{h}-{theme}.json','--at','1'],tab,h,theme)
  for variant,tab,name in [('BROKEN',0,'broken'),('LOCKED',1,'locked'),('UNKNOWN',1,'unknown')]:
   run(['--snap',PIC/f'settings-{name}-{h}-{theme}.png','--at','1'],tab,h,theme,variant)
print('32 fixture pictures rendered',flush=True)
# Continuous swipe crosses seven pages, then damps against the end.
swipe=[{'t':.1,'type':'down','x':360,'y':300}]
for i in range(61):swipe.append({'t':.12+i/30,'type':'move','x':360-5040*i/60,'y':300})
swipe.append({'t':2.16,'type':'up','x':-4680,'y':300})
# Three brief flicks, released away from the page centre. 45 frames each.
flick=[]
for j in range(3):
 t=j*.48+.05;flick.append({'t':t,'type':'drag','key':'pager','dx':-160,'dy':0,'dur':.16})
# Initial geometry is exactly minimum, no relative resize event.
drag=[{'t':0,'type':'drag','key':'settings-bottom-edge','dx':0,'dy':-500,'dur':.01},{'t':.1,'type':'down','x':360,'y':532}]
for i in range(19):drag.append({'t':.12+i/30,'type':'move','x':360,'y':532+360*i/18})
for i in range(19):drag.append({'t':.76+i/30,'type':'move','x':360,'y':892-400*i/18})
drag.append({'t':1.4,'type':'up','x':360,'y':492})
for name,events,frames,tab,height in [('swipe',swipe,90,0,640),('flick',flick,45,0,640),('drag',drag,45,3,900)]:
 script=OUT/f'{name}-r2.json';script.write_text(json.dumps(events,indent=2))
 run(['--script',script,'--start',.06 if name=='drag' else 0,'--frames',frames,'--fps','30','--out',SCRATCH/f'{name}-frames','--tree',OUT/f'{name}-r2-tree.json','--video',OUT/f'{name}-r2.mp4'],tab,height)
 print(name,'film rendered',flush=True)

from PIL import Image
measurements=[]
for theme in ['dark','light']:
 for h in [640,900]:
  for name in ['general','transcription','dictionary','speech','history']:
   tree=json.loads((SCRATCH/f'{name}-{h}-{theme}.json').read_text())
   es=tree['elements']; line=next(e for e in es if e.get('key')=='tab-hairline'); y=round((line['rect'][1]+.5)*2)
   im=Image.open(PIC/f'settings-{name}-{h}-{theme}.png').convert('RGB')
   assert len({im.getpixel((x,y)) for x in range(im.width)}) == 1, (theme,name,'hairline')
   assert im.getpixel((0,y)) != im.getpixel((0,y+4)), (theme,name,'missing hairline')
   assert not any(e.get('text')==name.capitalize() and e['rect'][1]>line['rect'][1]+1 for e in es), (name,'duplicate title')
   if name=='speech':
    field=next(e for e in es if e.get('key')=='threshold')['rect']
    label=next(e for e in es if e.get('text')=='characters')['rect']
    def glyph_center(rect,width=None):
     x,y,w,hh=rect; coords=[]
     for yy in range(round((y-2)*2),round((y+hh+2)*2)):
      for xx in range(round(x*2),round((x+(width or w))*2)):
       pixel=im.getpixel((xx,yy)); bright=sum(pixel)/3
       if (bright>180 if theme=='dark' else bright<110):coords.append(yy)
     return (min(coords)+max(coords)+1)/4
    textrect=next(e for e in es if e.get('key')=='threshold-text')['rect']
    a=glyph_center(textrect,45);b=glyph_center(label)
    assert abs(a-(field[1]+field[3]/2))<=.5,(theme,h,a,field)
    assert abs(a-b)<=.5,(theme,h,a,b)
    measurements.append(dict(theme=theme,height=h,glyph_center=a,field_center=field[1]+field[3]/2,label_glyph_center=b))
(OUT/'pixel-proof-r2.json').write_text(json.dumps(measurements,indent=2))
print('hairline, duplicate-title and glyph pixel oracles PASS',flush=True)

for name,n in [('swipe',90),('flick',45),('drag',45)]:
 for i in range(n):
  im=Image.open(SCRATCH/f'{name}-frames/frame_{i:04}.png').convert('RGB')
  assert len({im.getpixel((x,57)) for x in range(im.width)})==1,(name,i,'hairline during motion')
last=json.loads((OUT/'drag-r2-tree.json').read_text())
root=next(e for e in last['elements'] if e.get('key')=='settings')
assert abs(root['rect'][3]-540)<.5, root['rect']
im=Image.open(SCRATCH/'drag-frames/frame_0044.png').convert('RGB')
assert any(max(im.getpixel((x,y)))>100 for x in range(680,760) for y in range(1055,1068)), 'missing final handle'
print('all film hairlines and final minimum-height handle PASS',flush=True)
