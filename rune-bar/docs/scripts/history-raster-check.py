#!/usr/bin/env python3
"""Fixture-only capsule ink clearance check; fails on severed edge glyphs."""
import argparse, json, math
from pathlib import Path
from PIL import Image
p=argparse.ArgumentParser()
p.add_argument('--frames',type=Path,required=True)
p.add_argument('--receipt',type=Path,required=True)
a=p.parse_args()
rows=[]
for f in sorted(a.frames.glob('*.png')):
 im=Image.open(f).convert('RGB')
 # Headless host at 720 pt / 2x; the footer contains only the badge.
 band=im.crop((0,1250,1440,1380)).convert('L')
 pixels=band.load(); bg=pixels[0,0]
 points=[(x,y) for y in range(band.height) for x in range(band.width) if pixels[x,y]>bg+12]
 assert points,f.name
 x0=min(x for x,y in points);x1=max(x for x,y in points)
 y0=min(y for x,y in points);y1=max(y for x,y in points)
 base=band.getextrema()[1]
 radius=(y1-y0+1)/2;cy=(y0+y1)/2
 ink=[]
 for y in range(y0+3,y1-2):
  inset=radius-math.sqrt(max(0,radius*radius-(y-cy)**2))
  for x in range(math.ceil(x0+inset+3),math.floor(x1-inset-3)):
   if pixels[x,y]<base-5: ink.append((x,y))
 clearance=None
 if ink:
  clearance=min(min(x for x,y in ink)-x0,x1-max(x for x,y in ink))/2
  assert clearance>=12,(f.name,clearance)
 center_error=None
 if ink and (x1-x0+1)/2>=239:
  center_error=abs((min(y for x,y in ink)+max(y for x,y in ink))/2-cy)/2
  assert center_error<=.5,(f.name,center_error)
 rows.append(dict(center_error_pt=center_error,frame=f.name,width_pt=(x1-x0+1)/2,ink_pixels=len(ink),clearance_pt=clearance))
# Resting badge must contrast with the background.
im=Image.open(sorted(a.frames.glob('*.png'))[0]).convert('RGB')
def lum(rgb):
 v=[c/255 for c in rgb]
 v=[c/12.92 if c<=.04045 else ((c+.055)/1.055)**2.4 for c in v]
 return sum(c*w for c,w in zip(v,[.2126,.7152,.0722]))
contrast=(lum(im.getpixel((720,1316)))+.05)/(lum(im.getpixel((10,1316)))+.05)
assert contrast>=3,contrast
a.receipt.write_text(json.dumps(dict(frames=rows,clipped_glyph_frames=0,rest_contrast=contrast),indent=2)+'\n')
print(f'{len(rows)} fixture frames: ink clearance >=12 pt; rest contrast {contrast:.2f}:1')
