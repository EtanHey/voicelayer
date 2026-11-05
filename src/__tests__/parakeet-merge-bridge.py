"""Model-free regression against the unmodified upstream 0.6.3 fixture."""

import importlib.util
from pathlib import Path
import sys
import types


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


root = Path(__file__).parent
alignment = load("v34b_alignment", root / "fixtures/mlx-audio-0.6.3/alignment.py")
bridge = load("v34b_bridge", root.parent / "parakeet_merge_bridge.py")
original = Path(alignment.__file__).read_bytes()
token_class = alignment.AlignedToken
early_bindings = types.SimpleNamespace(
    merge_longest_contiguous=alignment.merge_longest_contiguous,
    merge_longest_common_subsequence=alignment.merge_longest_common_subsequence,
)
for name in ("merge_longest_contiguous", "merge_longest_common_subsequence"):
    a = [token_class(id=7, text=" word", start=10.0, duration=1.0)]
    b = [token_class(id=7, text=" word", start=10.0, duration=1.0)]
    assert getattr(alignment, name)(a, b, overlap_duration=2.0) == []

bridge.apply_alignment_bridge(alignment)
assert alignment.AlignedToken is token_class
for name in ("merge_longest_contiguous", "merge_longest_common_subsequence"):
    a = [token_class(id=7, text=" word", start=10.0, duration=1.0)]
    b = [token_class(id=7, text=" word", start=10.0, duration=1.0)]
    assert getattr(alignment, name)(a, b, overlap_duration=2.0) == b
    before = token_class(id=7, text=" word", start=0.0, duration=0.5)
    after = token_class(id=7, text=" word", start=20.0, duration=0.5)
    assert getattr(alignment, name)(
        [before, *a], [*b, after], overlap_duration=2.0
    ) == [before, *b, after]

fixed_function = alignment.merge_longest_contiguous
bridge.apply_alignment_bridge(alignment)
assert alignment.merge_longest_contiguous is fixed_function
assert Path(alignment.__file__).read_bytes() == original

# Model-free stand-ins for 0.6.3's eager imports: the old function references
# must be rebound even after alignment itself has been patched.
sys.modules["mlx_audio.stt.models.nemo"] = types.SimpleNamespace(alignment=alignment)
sys.modules["mlx_audio.stt.models.parakeet"] = types.SimpleNamespace(
    parakeet=early_bindings
)
bridge.apply_parakeet_bridge()
assert early_bindings.merge_longest_contiguous is alignment.merge_longest_contiguous
assert (
    early_bindings.merge_longest_common_subsequence
    is alignment.merge_longest_common_subsequence
)

# Refuse an unfamiliar package source without replacing either function.
try:
    bridge.apply_alignment_bridge(types.SimpleNamespace(__file__=__file__))
except RuntimeError as error:
    assert "Unknown mlx-audio" in str(error)
else:
    raise AssertionError("Unfamiliar source must fail closed")
print(
    "V34b: straddling tokens retained once, repetitions kept, source unchanged, idempotent, drift refused"
)
