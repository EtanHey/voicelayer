"""V34b: vendored mlx-audio midpoint patch, applied in this worker only.

Remove when upstream releases the fix and parakeet-runtime.lock is updated.
Upstream PR and fork commit: docs/parakeet-merge-bridge.md.
Never write into the shared Python environment or load a model here.
"""

import ast
import hashlib
import functools
from pathlib import Path

ORIGINAL_SHA256 = "8fbc93df4c2ad061481a2f27650233a0441806d6a10439c18125ced47d808a17"
FIXED_SHA256 = "b128f63541d5b0c4ca3d80dc64a6326e23bc4b2ab2a784663d719cee37793e6c"


def merge_boundary_word(a, b, overlap_duration):
    """Keep the earlier complete word when overlapping chunks retokenize it."""
    if not a or not b:
        return None
    first = len(a) - 1
    while first > 0 and not a[first].text[:1].isspace():
        first -= 1
    end = 1
    while end < len(b) and not b[end].text[:1].isspace():
        end += 1
    left, right = a[first:], b[:end]
    left_text = "".join(t.text for t in left).strip()
    right_text = "".join(t.text for t in right).strip()
    # Refuse tokens containing multiple words; punctuation alone is no anchor.
    if len(left_text.split()) != 1 or len(right_text.split()) != 1:
        return None
    left_key = left_text.rstrip(".?!").casefold()
    right_key = right_text.rstrip(".?!").casefold()
    if not any(c.isalnum() for c in left_key) or left_key != right_key:
        return None
    left_start, left_end = min(t.start for t in left), max(t.end for t in left)
    right_start, right_end = min(t.start for t in right), max(t.end for t in right)
    left_center = (left_start + left_end) / 2
    right_center = (right_start + right_end) / 2
    if (not (right_start <= left_center < right_end
             and left_start <= right_center < left_end)
            or abs(left_start - right_start) >= overlap_duration / 2):
        return None
    return a + b[end:]


def preserve_boundary_word(merge):
    @functools.wraps(merge)
    def wrapped(a, b, *, overlap_duration):
        result = merge_boundary_word(a, b, overlap_duration)
        return result if result is not None else merge(a, b, overlap_duration=overlap_duration)
    return wrapped


def apply_alignment_bridge(alignment):
    if getattr(alignment, "_voicelayer_v34b_merge_bridge", False):
        return
    source = Path(alignment.__file__).read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest not in (ORIGINAL_SHA256, FIXED_SHA256):
        raise RuntimeError(
            "Unknown mlx-audio alignment source; re-evaluate V34b bridge"
        )
    patched = source.replace(
        b"t.end <= cutoff_time", b"(t.start + t.end) / 2 < cutoff_time"
    ).replace(b"t.start >= cutoff_time", b"(t.start + t.end) / 2 >= cutoff_time")
    if hashlib.sha256(patched).hexdigest() != FIXED_SHA256:
        raise RuntimeError("V34b patch differs from upstream fix")
    # Replace only the two functions.
    # Retain the original token classes and all other module globals.
    for node in ast.parse(patched).body:
        if isinstance(node, ast.FunctionDef) and node.name in (
            "merge_longest_contiguous",
            "merge_longest_common_subsequence",
        ):
            code = compile(
                ast.Module(body=[node], type_ignores=[]), alignment.__file__, "exec"
            )
            exec(code, alignment.__dict__)
    for name in ("merge_longest_contiguous", "merge_longest_common_subsequence"):
        setattr(alignment, name, preserve_boundary_word(getattr(alignment, name)))
    alignment._voicelayer_v34b_merge_bridge = True


def apply_parakeet_bridge():
    from mlx_audio.stt.models.nemo import alignment
    from mlx_audio.stt.models.parakeet import parakeet

    apply_alignment_bridge(alignment)
    # mlx-audio 0.6.3 eagerly imports Parakeet through stt.__init__.
    parakeet.merge_longest_contiguous = alignment.merge_longest_contiguous
    parakeet.merge_longest_common_subsequence = (
        alignment.merge_longest_common_subsequence
    )
