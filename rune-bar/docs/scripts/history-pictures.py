#!/usr/bin/env python3
"""Headless only. Private archive pixels are routed exclusively outside this checkout."""
import argparse, json, os, subprocess
from pathlib import Path
crate=Path(__file__).resolve().parents[2]
binary=crate.parent/'.build.noindex/rune-target/debug/history'
parser=argparse.ArgumentParser()
parser.add_argument('--proof-dir', type=Path, required=True)
parser.add_argument('--private-out', type=Path)
args=parser.parse_args()
proof=args.proof_dir
public=crate/'docs/pictures'
public.mkdir(parents=True,exist_ok=True)
(proof/'frames-r2').mkdir(parents=True,exist_ok=True)
(proof/'expand-frames-r2').mkdir(parents=True,exist_ok=True)
scripts=crate/'docs/scripts'
expanded=[dict(t=.2,type='tap',key='entry-0')]
badge=[dict(t=.03,type='wheel',key='viewport',dy=-100000,dx=0),
       dict(t=.1,type='down',key='pull-zone')]
badge += [dict(t=.13+i*.025,type='move',x=360,y=658+i*50/10) for i in range(11)]
badge += [dict(t=.42,type='up',x=360,y=708),dict(t=.95,type='down',key='pull-zone')]
badge += [dict(t=1+i*.025,type='move',x=360,y=658+i*100/20) for i in range(21)]
badge += [dict(t=1.6,type='up',x=360,y=758)]
for name,data in [('history-expand',expanded),('history-badge',badge)]:
 (scripts/f'{name}.json').write_text(json.dumps(data,indent=2)+'\n')
def run(args,category=0,fixture=True):
 env=os.environ.copy();env['VOICELAYER_RUNE_HISTORY_CATEGORY']=str(category)
 if fixture: env['VOICELAYER_RUNE_FIXTURE']='1'
 else: env.pop('VOICELAYER_RUNE_FIXTURE',None)
 # No tree, trace or text logging for real archives.
 subprocess.run([str(binary)]+args,env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for theme in ['dark','light']:
 for name,category in [('dictations',0),('ask',1),('speech',2)]:
  run(['--theme',theme,'--snap',str(public/f'history-{name}-{theme}.png'),'--at','1'],category)
 for name,script,at in [('expanded','history-expand',1),('badge-mid','history-badge',.38),('badge-full','history-badge',1.55)]:
  run(['--theme',theme,'--snap',str(public/f'history-{name}-{theme}.png'),'--script',str(scripts/f'{script}.json'),'--at',str(at)])

run(['--script',str(scripts/'history-badge.json'),'--frames','120','--start','0','--every','2','--out',str(proof/'frames-r2')])
run(['--script',str(scripts/'history-expand.json'),'--frames','40','--start','0.1','--every','2','--out',str(proof/'expand-frames-r2')])
if args.private_out:
 args.private_out.mkdir(parents=True,exist_ok=True)
 for name,category in [('dictations',0),('ask',1),('speech',2)]:
  run(['--theme','dark','--snap',str(args.private_out/f'history-{name}.png'),'--at','1'],category,False)
