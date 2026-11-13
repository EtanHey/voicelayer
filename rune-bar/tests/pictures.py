"""Fixture-only pixel contracts, called by cargo test. Requires Pillow."""
import json, os, pathlib, subprocess, sys
from PIL import Image
binary, repro = sys.argv[1:]
root = pathlib.Path(__file__).resolve().parents[2]
out = root / '.build.noindex/r2-pixels'
out.mkdir(exist_ok=True)
def render(binary, name, theme='dark', ordinary=False):
    env = dict(os.environ, VOICELAYER_RUNE_FIXTURE='1')
    if ordinary: env['RUNE_REPRO_ORDINARY']='1'
    args=[binary,'--theme',theme,'--snap',str(out/f'{name}.png'),'--tree',str(out/f'{name}.json')]
    if binary != repro: args += ['--script',str(root/'rune-bar/docs/scripts/select.json'),'--at','1']
    subprocess.run(args,env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return Image.open(out/f'{name}.png').convert('RGB'), json.loads((out/f'{name}.json').read_text())
def nodes(v):
    if isinstance(v,dict):
        yield v
        for x in v.values(): yield from nodes(x)
    elif isinstance(v,list):
        for x in v:yield from nodes(x)
def lum(p): return .2126*p[0]+.7152*p[1]+.0722*p[2]
for theme in ['dark','light']:
    im,tree=render(binary,theme,theme); ns=list(nodes(tree))
    def rect(key, parent=''):return next(n['rect'] for n in ns if n.get('key')==key and 'rect' in n and parent in n.get('path',''))
    def pixel(x,y):return im.getpixel((round(x*2),round(y*2)))
    a=rect('add');s=rect('search');r=rect('term-0-1')
    def ink(rect, inset):
        x,y,w,h=rect
        ps=im.crop((int((x+inset)*2),int((y+8)*2),int((x+w-8)*2),int((y+h-8)*2))).getdata()
        return (max if theme=='dark' else min)(map(lum,ps))
    assert abs(ink(a,36)-ink(s,42))>=40, 'action must be stronger than placeholder'
    assert max(abs(x-y) for x,y in zip(pixel(a[0]+12,a[1]+5),pixel(s[0]+12,s[1]+5)))<=2,'matching control fill'
    bg=pixel(10,110); selected=pixel(r[0]+10,r[1]+10)
    assert abs(lum(bg)-lum(selected))<=.12*255, (theme,bg,selected)
    for key in ['pencil','menu']:
        q=rect(key,'term-0-1/')
        assert max(abs(x-y) for x,y in zip(pixel(q[0]+2,q[1]+2),selected))<=2,(theme,key)
    print(theme,'action contrast, matching fills, quiet selection, ghost controls PASS')
a,_=render(repro,'virtual'); b,_=render(repro,'ordinary',ordinary=True)
# The partly visible row is centred below this band, identically in both lists.
assert a.crop((0,217,1240,1216)).tobytes()==b.crop((0,217,1240,1216)).tobytes(), 'whole visible viewport must agree'
assert max(map(lum,b.crop((0,217,1240,1193)).getdata()))>200, 'ordinary reference must actually paint labels'
print('virtual/ordinary trailing band identical PASS')
