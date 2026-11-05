"""V34b: vendored mlx-audio midpoint patch, applied in this worker only.

Remove when upstream releases the fix and parakeet-runtime.lock is updated.
Upstream PR and fork commit: docs/parakeet-merge-bridge.md.
Never write into the shared Python environment or load a model here.
"""

import ast
import hashlib
from pathlib import Path

ORIGINAL_SHA256 = "8fbc93df4c2ad061481a2f27650233a0441806d6a10439c18125ced47d808a17"
FIXED_SHA256 = "b128f63541d5b0c4ca3d80dc64a6326e23bc4b2ab2a784663d719cee37793e6c"


def apply_alignment_bridge(alignment):
    if getattr(alignment, "_voicelayer_v34b_merge_bridge", False):
        return
    source = Path(alignment.__file__).read_bytes()
    digest = hashlib.sha256(source).hexdigest()
    if digest == FIXED_SHA256:
        return
    if digest != ORIGINAL_SHA256:
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
