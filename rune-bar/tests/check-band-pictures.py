"""Rendered proof, separate from cargo's element-tree tests. Requires Pillow."""
import colorsys
import sys
from collections import Counter
from pathlib import Path
from PIL import Image
picture = Path(__file__).parents[1] / 'docs/pictures/band-transcribing-end.png'
counts = Counter((r,g,b) for r,g,b,a in Image.open(picture).convert('RGBA').get_flattened_data()
                 if a > 128 and b > 100 and max(r,g,b)-min(r,g,b) > 80)
rgb, count = counts.most_common(1)[0]
hue = colorsys.rgb_to_hsv(*(v/255 for v in rgb))[0]*360
print(f'modal saturated pixel {rgb}, count {count}, hue {hue:.3f}')
assert hue >= 228 and abs(hue-211) >= 15
if len(sys.argv)>1:
    failures=[]
    for n in range(14,45):
        im=Image.open(Path(sys.argv[1])/f'frame_{n:04}.png').convert('RGBA')
        # Both settled glyphs must stay visible after their entrance (white, not blue dots).
        count=sum(a>128 and min(r,g,b)>180 for r,g,b,a in im.crop((32,16,152,72)).get_flattened_data())
        if count<30: failures.append((n,count))
    print('missing settled icons:',failures)
    assert not failures, 'rendered icons disappear despite tree opacity=1'
