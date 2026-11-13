#!/usr/bin/env python3
"""Fixture-only headless evidence; never opens a window or reads real stores."""
import json,os,subprocess,argparse
from pathlib import Path
crate=Path(__file__).resolve().parents[2]
proof=Path(argparse.ArgumentParser().parse_known_args()[1][0])
proof.mkdir(parents=True,exist_ok=True)
public=crate/'docs/pictures';public.mkdir(exist_ok=True)
binary=crate.parent/'.build.noindex/rune-target/debug/settings'
base=os.environ.copy();base['VOICELAYER_RUNE_SCREEN_HEIGHT']='900'
base['VOICELAYER_RUNE_SETTINGS_STATE']=str(proof/'layout.json')
def run(args,tab=0,extra={}):
 env=base.copy();env['VOICELAYER_RUNE_SETTINGS_TAB']=str(tab);env.update(extra)
 subprocess.run([str(binary),*map(str,args)],env=env,check=True,stdout=subprocess.DEVNULL)
if not os.environ.get('SETTINGS_FILMS_ONLY'):
 for theme in ['dark','light']:
  for tab,name in enumerate(['general','transcription','dictionary','speech','history']):
   for height in [640,900]:
    run(['--theme',theme,'--size',f'720x{height}','--snap',public/f'settings-{name}-{height}-{theme}.png','--at','1'],tab)
  for name,tab,extra in [('healthy',0,{}),('broken',0,{'VOICELAYER_RUNE_SETTINGS_BROKEN':'1'}),('locked',1,{'VOICELAYER_RUNE_SETTINGS_LOCKED':'1'})]:
   run(['--theme',theme,'--size','720x640','--snap',public/f'settings-{name}-{theme}.png','--at','1'],tab,extra)
swipe=[dict(t=.03,type='down',x=360,y=320)]
swipe += [dict(t=.06+i/30,type='move',x=360-5040*i/54,y=320) for i in range(55)]
swipe += [dict(t=1.92,type='up',x=-4680,y=320)]
drag=[dict(t=0,type='resize',dw=0,dh=-360,dur=.01),dict(t=.1,type='down',x=360,y=532)]
drag += [dict(t=.12+i/30,type='move',x=360,y=532+368*i/18) for i in range(19)]
drag += [dict(t=.77+i/30,type='move',x=360,y=900-368*i/20) for i in range(21)]
drag += [dict(t=1.49,type='up',x=360,y=532)]
for name,data,n,size in [('swipe',swipe,60,'720x640'),('drag',drag,45,'720x540')]:
 script=proof/f'{name}.json';script.write_text(json.dumps(data,indent=2)+'\n')
 out=proof/f'{name}-frames';out.mkdir(exist_ok=True)
 for i in range(100):
  old=out/f'frame_{i:04}.png'
  if old.exists(): old.unlink()
 (proof/'layout.json').write_text(json.dumps({'height':540 if name=='drag' else 640}))
 run(['--size','720x900','--theme','dark','--script',script,'--start',.067 if name=='drag' else 0,'--frames',n,'--fps','30','--out',out])
 # Frames from live resizing have different heights: centre in the same screen-sized canvas.
 subprocess.run(['ffmpeg','-y','-framerate','30','-pattern_type','glob','-i',str(out/'*.png'),'-vf','pad=1440:1800:0:0:color=0x141414','-frames:v',str(n),'-c:v','libx264','-pix_fmt','yuv420p',str(proof/f'{name}.mp4')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
