# Wing entry after History (R0856-05)

Walkthrough 2026-11-02 08:56, 37.2 -> 37.5 s: recording started with History open; Stop + Cancel were
drawn at once while the shell waited out the 0.12 s content-exit delay (its body was shrinking), so the
red Stop was clipped by the old, mic-width wing and the empty slab stayed. Now a growing wing never
waits, and controls arriving with it show once the glass covers them.
Run: `bash formal/wing-entry/check.sh`. Ticks of 1/120 s.

| Config | Expected | Result |
| --- | --- | --- |
| Old (shell waits 14 ticks, controls drawn at once) | `NoClippedControl` fails | see results/Old.log |
| Fixed (shell moves at once, controls wait for cover: 21 ticks, two slots) | PASS | see results/Fixed.log |
| MutantNeverShown (controls never shown) | `ControlsAppear` fails (temporal) | see results/MutantNeverShown.log |

The spring's real shape is replayed frame by frame against the drawn shell path in
`NotchRecordingFromHistoryTests`, for one and two slots of growth, from History and from the launcher.
