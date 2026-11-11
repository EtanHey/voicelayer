"""Model-free: the worker never decodes a short final window alone (c8 T1).

Synthetic speech runs to the last sample, as when a press stops a take mid-sentence.
The fake decoder reproduces the measured failure: a window under 5 s returns
no tokens. Merges are the real mlx-audio 0.6.3 functions with the V34b bridge.
"""

import importlib.util
from pathlib import Path
import sys
import types
import wave
import zlib

root = Path(__file__).parent
work = Path(sys.argv[1])


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


alignment = load("t1_alignment", root / "fixtures/mlx-audio-0.6.3/alignment.py")
load("t1_bridge", root.parent / "parakeet_merge_bridge.py").apply_alignment_bridge(alignment)
# The worker imports alignment lazily from mlx_audio; serve it the fixture.
for name in ("mlx_audio", "mlx_audio.stt", "mlx_audio.stt.models", "mlx_audio.stt.models.nemo"):
    sys.modules[name] = types.ModuleType(name)
sys.modules["mlx_audio.stt.models.nemo"].alignment = alignment
worker = load("t1_worker", root.parent / "parakeet-worker.py")

SR = 16000
SHORT_WINDOW_S = 5.0


class Audio:
    dtype = "bfloat16"

    def __init__(self, start, end):
        self.start, self.end = start, end

    def __getitem__(self, s):
        return Audio(self.start + s.start, self.start + min(s.stop, self.end - self.start))

    def __truediv__(self, x):
        return self

    def astype(self, x):
        return self


class NP:
    float32 = "float32"

    def frombuffer(self, pcm, dtype):
        return Audio(0, len(pcm) // 2)


class MX:
    bfloat16 = "bfloat16"

    def array(self, x):
        return x

    def synchronize(self):
        pass

    def clear_cache(self):
        pass


def words_until(seconds):
    """One word every 0.4 s from 0.5 s to the very end of the take."""
    out, t, i = [], 0.5, 0
    while t + 0.3 <= seconds:
        out.append((f" w{i}", t, 0.3))
        t, i = t + 0.4, i + 1
    return out


class Model:
    """Decodes whole words inside a window; a short window hears nothing."""

    def __init__(self, words):
        self.words, self.windows = words, []

    def _log_mel_spectrogram(self, audio):
        return audio

    def decode(self, mel):
        a, b = mel.start / SR, mel.end / SR
        self.windows.append((mel.start, mel.end))
        tokens = [] if b - a < SHORT_WINDOW_S else [
            alignment.AlignedToken(id=zlib.crc32(text.encode()), text=text, start=start - a, duration=duration)
            for text, start, duration in self.words if start >= a and start + duration <= b]
        sentences = [types.SimpleNamespace(tokens=tokens)] if tokens else []
        return [types.SimpleNamespace(sentences=sentences)]

    def generate(self, audio, *, chunk_duration, overlap_duration, chunk_callback, **_):
        """Upstream 0.6.3 non-streaming loop: uniform windows, same merges."""
        total = audio.end - audio.start
        size, overlap = int(chunk_duration * SR), int(overlap_duration * SR)
        if total <= size:
            r = self.decode(audio)[0]
            return alignment.sentences_to_result(alignment.tokens_to_sentences(
                [t for s in r.sentences for t in s.tokens]))
        tokens = []
        for start in range(0, total, size - overlap):
            end = min(start + size, total)
            chunk_callback(end, total)
            r = self.decode(audio[slice(start, end)])[0]
            window = []
            for s in r.sentences:
                for t in s.tokens:
                    t.start += start / SR
                    t.end = t.start + t.duration
                    window.append(t)
            if tokens:
                try:
                    tokens = alignment.merge_longest_contiguous(tokens, window, overlap_duration=overlap_duration)
                except RuntimeError:
                    tokens = alignment.merge_longest_common_subsequence(tokens, window, overlap_duration=overlap_duration)
            else:
                tokens = window
            if end == total:
                break
        return alignment.sentences_to_result(alignment.tokens_to_sentences(tokens))


def take(seconds):
    frames = round(seconds * SR)
    path = work / f"take-{frames}.wav"
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(b"\x01\x00" * frames)
    return path, frames


def check_take(seconds):
    path, frames = take(seconds)
    words = words_until(seconds)
    model = Model(words)
    value = worker.decode(model, MX(), NP(), path)
    expected = "".join(w for w, _, _ in words).strip()
    assert value["complete"] and value["covered_frames"] == frames, (seconds, value["covered_frames"])
    assert value["text"] == expected, f"{seconds}s take lost or repeated words: ...{value['text'][-40:]!r} vs ...{expected[-40:]!r}"
    assert all(b - a >= SHORT_WINDOW_S * SR for a, b in model.windows), (seconds, model.windows)
    return model.windows


# 1. The live specimen's geometry: 31.744 s, speech up to the press stop.
#    Upstream windows 0-30 s and 28-31.744 s; the 3.7 s window hears nothing.
windows = check_take(31.744)
assert windows == [(0, 507904)], windows

# 2. Longer takes whose uniform plan ends in a scrap, and takes whose plan is
#    already healthy (unchanged windows), all keep every word exactly once.
for seconds in (30.5, 33.7, 40.0, 58.4, 60.2, 69.0, 87.6, 90.0, 120.3):
    check_take(seconds)

# 3. Plan invariants over many lengths: full coverage, 2 s overlaps, the
#    upstream boundaries kept whenever the final window is long enough, a final
#    window >= 12.5 s and no window over 40.5 s.
size, overlap, floor = 30 * SR, 2 * SR, int(12.5 * SR)
for frames in list(range(size - 3, size + 4)) + list(range(size + 1, 600 * SR, 7919)):
    plan = worker.chunk_plan(frames)
    uniform = []
    for start in range(0, frames, size - overlap):
        uniform.append((start, min(start + size, frames)))
        if uniform[-1][1] == frames:
            break
    assert plan[0][0] == 0 and plan[-1][1] == frames, frames
    assert all(b[0] == a[1] - overlap for a, b in zip(plan, plan[1:])), frames
    assert all(b - a <= int(40.5 * SR) for a, b in plan), frames
    if frames > size:
        assert plan[-1][1] - plan[-1][0] >= floor, frames
    if uniform[-1][1] - uniform[-1][0] >= floor or len(uniform) == 1:
        assert plan == uniform, frames
    else:
        assert plan == uniform[:-2] + [(uniform[-2][0], frames)], frames

print("T1: short final windows never decoded alone; every word kept once")
