# Idle wings and VoiceBar's own windows (R0856-12)

Walkthrough 2026-11-02 08:56, 74.1-75.5 s: the notch wings vanished for about 1.5 s.
VoiceBar's log shows the panel dropping to the bare idle frame (192 x 49) at
08:58:05.582 with the key window "VoiceBar Settings", and returning to the launcher
frame (472 x 259) at 08:58:07.124. The pointer's debounced exit (after the 2.5 s
grace) collapses idle at once, and the pointer had to leave the notch to use Settings.
Run: `bash formal/idle-wings/check.sh`.

| Config | Expected | Result |
| --- | --- | --- |
| Old (exit collapses even while Settings has focus) | `NoVanishWhileFocused` fails | 6 states, violated |
| Fixed (focus holds the wings; resigning re-arms the countdown) | PASS | 33 states, 18 distinct |
| MutantNoResume (resigning does not re-arm the countdown) | `StillCollapses` fails (temporal, exit 13) | 31 states, violated |

Swift guard: `IdleWingsFocusTests`. The app recomputes focus on key/resign/close and
app-resign notifications (`VoiceBarWindowFocus.holdsIdleWings`); that wiring is not
covered by a unit test and needs the installed-app check.
