# Native synthetic recording fixture

This UIE2E-only app renders production views with synthetic timer and level events.
It does not open the microphone, start a daemon, install F5, or replace VoiceBar.
Native rendering proves UI behavior; it does not prove live capture or transcription.

Build from the candidate worktree (keep all output under `.noindex`):

```sh
qa="$PWD/.build.noindex/native-qa/vl-ui-host"
mkdir -p "$qa"
printf 'voicebar-ui-e2e-v1\n' > "$qa/.uie2e-sandbox"
VOICEBAR_QA_BUILD=1 VOICEBAR_UIE2E_ADHOC=1 VOICEBAR_CODESIGN_IDENTITY=- \
  bash flow-bar/build-app.sh --install-path "$qa/VoiceBarQA.app" --no-stop --no-relaunch
bash scripts/voicebar-ui-fixture.sh "$qa/VoiceBarQA.app" "$qa" recording-ptt
```

Fixture names: `recording-ptt`, `recording-vad` (Lock), `recording-ptt-long`
(61 minutes), `idle`, and `launcher`. The QA Settings buttons can switch fixtures.
The synthetic clock and levels advance every 50 ms through the existing event
handler. No production capture implementation is added.

The runner holds output mute for its lifetime, then restores the prior state.
A guest reporting no mute value must pass the QA app's read-only CoreAudio check
that there is no default output device; a failed lookup refuses startup.
Terminate the runner normally (Ctrl-C) after the check; it cleans up its QA child.
Never terminate the resident VoiceBar. Inspect `fixture.pid`, `fixture.log` and
`capture-fixture.json` under the fixture root. The geometry receipt labels physical
notch versus flat display. Host mode uses AppKit's actual safe area and auxiliary
areas for both the rendered model and hit layout, anchored to that display.
The default XCUI fixture keeps its existing isolated top-right placement.

For terminal-mac, transfer the QA bundle and this runner with its
`scripts/lib/output-mute-guard.sh` dependency into the guest. Use an absolute
root such as `$HOME/.build.noindex/qa/vl-ui-guest`, never `.../x9`.
The resolved basename must start `vl-ui-`, with the exact marker above.
A guest without a physical notch can verify timer, waveform and control content;
it cannot establish physical-notch attachment, clipping or hover behavior.

Pre-push suites use `scripts/queue-heavy-suite.py` and a per-user lock at
`~/.local/state/voicelayer/heavy-suite.lock`. All VoiceLayer worktrees on that Mac
share it. The installed fleet helper is additionally used when present at
`~/Gits/golems/.worktrees/hooks-live/scripts/hooks/heavy-suite.py`; a missing helper
retains the VoiceLayer serial queue. The mutable development helper is never used.
Missing Python or HOME refuses execution rather than running unqueued.
