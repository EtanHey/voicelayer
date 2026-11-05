# U3a Settings frames (2.3 General + Transcription)

Synthetic NSHostingView renders (no resident app, sockets or audio), 1:1, light and dark. Fixture microphones and
times are examples. Regenerate:

```bash
VOICEBAR_U3A_SHOTS=<dir> VOICEBAR_U3A_BEFORE_AFTER=<dir> VOICEBAR_U3A_LABEL=after \
  swift test --package-path flow-bar --filter 'SettingsGeneralPaneShots|SettingsTranscriptionPane|SettingsRowAnatomy|SettingsU3aBeforeAfterShots'
```

`before-*` frames come from the same `SettingsU3aBeforeAfterShotsTests` file run on the integration/2.3 base.

| # | Frame | What it shows |
|---|---|---|
| 01 | before-general | Settings window (780 pt) on General before U3a |
| 02 | after-general | General after U3a: Setup ready row, Microphone priority with "Used for dictation", Dictation, VoiceBar |
| 03 | before-general-broken | Before, with Accessibility off |
| 04 | after-general-broken | After, with Accessibility off: "Finish setup", broken step first with Open System Settings |
| 05 | before-transcription | Transcription before U3a |
| 06 | after-transcription | Transcription after U3a |
| 07 | general-ready-720 | General pane at a 720 pt window (532 pt content) |
| 08 | general-ready-390 | General pane at a 390 pt window (338 pt content): controls wrap under the text |
| 09 | general-broken-720 | Setup broken (Accessibility, speaking voice) at 720 |
| 10 | general-broken-390 | Setup broken at 390 |
| 11 | transcription-parakeet-720 | Recognizer radio rows, Unload when idle, K-ui note, Language, Processing (Smart chunks: Unavailable with Parakeet) |
| 12 | transcription-parakeet-390 | The same at 390 |
| 13 | transcription-downloading-720 | Whisper downloading 34 % while Parakeet stays loaded (S4) |
| 14 | transcription-downloading-390 | The same at 390 |

`contrast.md`: measured text (≥ 4.5:1) and glyph (≥ 3:1) contrast against the window and the drawn grouped-section
background, light and dark.
