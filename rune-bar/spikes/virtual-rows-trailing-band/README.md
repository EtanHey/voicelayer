# Trailing band isolation

Run from rune-bar: `cargo run --locked --bin trailing-band -- --snap ../.build.noindex/virtual.png`.
Repeat with `RUNE_REPRO_ORDINARY=1` and a different output path.
The 1,000 rows are invented, 64 points tall, below a 108.25-point header,
in a viewport ending at y=608. The partially visible row starts at y=596.25.

Expected: virtual and ordinary lists draw identical pixels in y=596.5..608.
Actual: the bands are byte-identical. The labels are vertically centred: their
first ink is below y=608. This band is the leading blank area inside the row,
not a row rejected by Rune. A separate solid-white-row probe painted through
y=607, confirming that partial-row background paint is retained too.

Cause: our 64-point row spacing and centred contents, not an established Rune
clipping defect. Plain dictionary rows now use 48 points; variant rows retain
64. No Rune patch or clipping workaround was made. Empty leading/trailing
space of a clipped row remains possible, as it is in the ordinary list.
`fixture_pixel_contracts_and_virtual_band_comparison` compares both renderings.
The executable is a small standalone repro, not an alternate application path.
