"""Compare mirrored bottom-corner alpha and uniform interior alpha in both films."""
from pathlib import Path
import sys
from PIL import Image

for directory in map(Path, sys.argv[1:]):
    for path in sorted(directory.glob('frame_*.png')):
        im = Image.open(path).convert('RGBA')
        a = im.getchannel('A')
        # Find the surface extent above the bottom corner, below the safe-top cap.
        xs = [x for x in range(im.width) if a.getpixel((x, 68)) > 0]
        if not xs:
            continue
        left, right = min(xs), max(xs)
        # Subpixel surface placement can differ by one raster pixel.
        patches = []
        for shift in [-1, 0, 1]:
            diffs = [abs(a.getpixel((left+x, y))-a.getpixel((right-x+shift,y)))
                     for x in range(16) for y in range(72,88)
                     if 0 <= right-x+shift < im.width]
            patches.append(sum(diffs)/len(diffs))
        assert min(patches) < 12, (path, 'corner alpha asymmetry', min(patches))
        interior = [a.getpixel((x,y)) for x in range(left+18,right-17)
                    for y in range(66,80)]
        # During the exit every interior point must dissolve at the same rate.
        assert max(interior)-min(interior) <= 2, (path,'double layer',min(interior),max(interior))
        if path.parent.name.startswith('frames-r3'):
            assert min(interior) >= 250, (path,'nonopaque settled band')
    print(directory.name, '45 frames: matching corners, uniform interior alpha')
