# V34b: mlx-audio midpoint merge bridge

Status: temporary bridge for mlx-audio 0.6.3; remove when upstream releases the fix.

- Upstream PR: https://github.com/Neywa-Labs/mlx-audio/pull/1125
- Fork: https://github.com/EtanHey/mlx-audio
- Fork commit: `0b4047eccbeed2378be2563967b5280644efe0ae`
- Upstream main inspected: `e0833581c52963ff52b9916dc6eace8ca870aae0`
- Original source: `mlx_audio/stt/models/nemo/alignment.py`, lines 97–101,
  176–180 and 214–218, identical in tag `v0.6.3` and the inspected main.

Both adjacent chunks can recognize the same token across the merge midpoint.
The old end/start predicates discard both copies. The fork assigns ownership by
token center, with midpoint ties assigned to the later chunk. It changes all
three timestamp fallback sites.

The boundary-word guard also handles adjacent chunks spelling one shared word
with different subword tokens (for example ` o` + `kay` + `?` versus ` Okay` +
`.`). Token matching cannot align those IDs, and timestamp fallback can splice
them into `o.`. Before either merge function runs, the guard checks the last
complete word of the earlier chunk against the first of the later chunk. Only
matching words with overlapping timestamps and starts less than half the overlap
apart are collapsed. The earlier complete word, including its punctuation, is
kept. Nonoverlapping repeats, differing words and multiword tokens use the existing
merge. No audio, runtime package or model assets are rewritten. This additional
VoiceLayer guard still needs an upstream fix; #1125 covers the midpoint patch.

`src/parakeet_merge_bridge.py` carries that predicate patch. Worker startup applies
it in memory before loading the model. Source hashes pin the original 0.6.3
module and the exact fixed module; unfamiliar source fails startup. An already
fixed source is accepted. Only the two merge functions are recompiled, retaining
the original token classes. Parakeet's eagerly imported function bindings are
also updated. Repeated application is harmless. The environment's package files,
wheel lock, model assets and runtime pointer are never modified.

The fixture under `src/__tests__/fixtures/mlx-audio-0.6.3/` is an unmodified copy
of the upstream alignment module, with its MIT license. It contains no recording
or transcript. The bridge test demonstrates the old zero-token result, the fixed
one-token result, surrounding repetitions, eager bindings, idempotence, unchanged
source bytes, and refusal of unfamiliar source without MLX or model loading.

## Cleanup

When the upstream PR is merged **and a release contains it**, update
`src/parakeet-runtime.lock` and the runtime version checks through the normal
runtime-upgrade workflow. Verify the regression against the unpatched released
package, then remove `src/parakeet_merge_bridge.py`, its worker startup import and
call, the bridge tests/fixture, and this document. A merge alone is not the
cleanup trigger. Installed-app acceptance remains a separate release step.
