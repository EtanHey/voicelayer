# Corpus replay verification

`bash scripts/voicelayer-verify.sh --corpus N` certifies the daemon and Swift
interaction path against a frozen list of local VoiceBar recordings. The default
list is [`scripts/corpus-replay-manifest.txt`](../scripts/corpus-replay-manifest.txt),
and `N` selects its first `N` entries in declared order. New recordings do not
change the selected corpus.

The manifest was frozen on 2026-07-13 from the ten newest usable recordings for
PR #339. Its fourth entry intentionally produces a protected-token rejection,
which proves that a safety guard can preserve the fallback without aborting the
runtime certification. `applied`, `rejected`, `shadowed`, and `skipped` are valid
handled polish outcomes. Empty output, degenerate output such as `1.`, missing or
unusable pinned specimens, process errors, and unsupported polish statuses still
fail the gate.

To certify an intentionally different frozen set, create a newline-delimited
manifest of recording IDs and set `VOICELAYER_VERIFY_CORPUS_MANIFEST`. Update the
checked-in default only as an explicit reviewable change; do not derive it from
the moving newest recordings during a certification run.
