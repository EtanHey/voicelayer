"""Real-model qualification of the Parakeet folded-window upper bound (c8 T3).

Public synthetic speech only (macOS `say`, invented sentences), packed so speech
runs to the last sample at each target length, decoded three ways: the worker's
planned windows, mlx-audio's uniform 30 s / 2 s windows, and one whole pass.
Prints words in / missing / inserted, decode seconds and peak MLX memory.

  HF_HUB_OFFLINE=1 <parakeet python> -I scripts/qualify-parakeet-fold-bound.py \
    "$PWD/src" <model dir> "$PWD/.build.noindex/t3-synth" out.json 40.0,40.4999,40.5
"""
import sys, os, wave, subprocess, importlib.util, json, time, difflib, re, resource
src, model_path, work, out_json = sys.argv[1:5]
lengths = [float(x) for x in sys.argv[5].split(",")]
sys.path.insert(0, src)
import mlx.core as mx, numpy as np
from parakeet_merge_bridge import apply_parakeet_bridge
apply_parakeet_bridge()
from mlx_audio.stt.utils import load_model
spec = importlib.util.spec_from_file_location("worker", os.path.join(src, "parakeet-worker.py")); w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
SENTENCES = """The orange lantern swayed above the quiet harbor.
A gray heron waited patiently beside the shallow river.
Seven students carried heavy boxes up the narrow stairs.
The baker opened his shop before the sun came up.
Thick fog rolled across the valley during the night.
My neighbor painted her fence a bright shade of green.
The train arrived late because of snow on the tracks.
We planted tomatoes and beans along the southern wall.
An old clock ticked loudly in the empty hallway.
The children built a small raft from fallen branches.
Fresh bread and warm soup were waiting on the table.
The pilot announced that we would land in twenty minutes.
A sudden gust of wind scattered the papers everywhere.
She tuned the guitar and played a gentle melody.
The museum closed early for the holiday weekend.
Two foxes crossed the field just after midnight.
He forgot his umbrella and walked home in the rain.
The library keeps rare maps in a locked cabinet.
Our team finished the project a week ahead of schedule.
A silver kettle whistled on the stove in the kitchen.
The mountain trail was steep and covered with loose stones.
Please remember to water the plants while I am away.
The fisherman mended his nets on the wooden dock.
Bright lanterns lined the street during the festival.
The doctor asked him to rest for a few more days.
A curious cat watched the birds from the window sill.
They repaired the bridge after the spring flood.
The garden smelled of roses and freshly cut grass.
Our guide explained how the ancient walls were built.
The radio played old songs late into the evening.""".splitlines()
VOICES = ["Samantha", "Daniel"]
SR = 16000
clips = {}
def clip(voice, i):
    key = (voice, i)
    if key not in clips:
        p = os.path.join(work, f"{voice}-{i}.wav")
        if not os.path.exists(p):
            subprocess.run(["say", "-v", voice, "-o", p, "--data-format=LEI16@16000", SENTENCES[i]], check=True)
        with wave.open(p) as f: clips[key] = f.readframes(f.getnframes())
    return clips[key]
def norm(text): return re.findall(r"[a-z0-9']+", text.lower())
def build(L, voice):
    frames, chosen = int(round(L * SR)), []
    used = int(0.3 * SR)
    for i in range(len(SENTENCES)):
        c = clip(voice, i)
        if used + len(c) // 2 + int(0.25 * SR) * bool(chosen) > frames: break
        used += len(c) // 2 + int(0.25 * SR) * bool(chosen); chosen.append(i)
    slack = frames - used
    gaps = len(chosen)  # leading gap plus one between each pair
    pcm = bytearray(b"\x00\x00" * (int(0.3 * SR) + slack // gaps))
    for k, i in enumerate(chosen):
        if k: pcm += b"\x00\x00" * (int(0.25 * SR) + slack // gaps)
        pcm += clip(voice, i)
    pcm += b"\x00\x00" * (frames - len(pcm) // 2)
    assert len(pcm) // 2 == frames, (len(pcm) // 2, frames)
    p = os.path.join(work, f"take-{voice}-{L}.wav")
    with wave.open(p, "wb") as f: f.setnchannels(1); f.setsampwidth(2); f.setframerate(SR); f.writeframes(bytes(pcm))
    return p, " ".join(SENTENCES[i] for i in chosen)
def score(ref, hyp):
    r, h = norm(ref), norm(hyp)
    sm = difflib.SequenceMatcher(a=r, b=h, autojunk=False)
    dele = sum(i2 - i1 for op, i1, i2, j1, j2 in sm.get_opcodes() if op in ("delete", "replace"))
    ins = sum(j2 - j1 for op, i1, i2, j1, j2 in sm.get_opcodes() if op in ("insert", "replace"))
    return len(r), dele, ins
model = load_model(model_path)
rows = []
for L in lengths:
    for voice in VOICES:
        p, ref = build(L, voice)
        pcm, frames = w.read_pcm(p)
        a = mx.array(np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0)
        row = {"L": L, "voice": voice, "plan_s": [(s / SR, e / SR) for s, e in w.chunk_plan(frames)]}
        for name, fn in (("new", lambda: w.decode(model, mx, np, p)["text"]),
                         ("old_uniform", lambda: model.generate(a, chunk_duration=30.0, overlap_duration=2.0, stream=False, verbose=False).text),
                         ("single", lambda: model.generate(a, stream=False, verbose=False).text)):
            mx.synchronize(); mx.clear_cache(); mx.reset_peak_memory(); t = time.monotonic()
            text = fn(); mx.synchronize()
            n, d, i = score(ref, text)
            row[name] = {"words_in": n, "missing": d, "inserted": i, "decode_s": round(time.monotonic() - t, 3), "peak_mlx_gb": round(mx.get_peak_memory() / 2**30, 3)}
        rows.append(row)
        print(json.dumps(row), flush=True)
print(json.dumps({"process_maxrss_gb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30, 3)}))
json.dump(rows, open(out_json, "w"), indent=1)
