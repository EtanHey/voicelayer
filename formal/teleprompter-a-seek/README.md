# U5 Teleprompter A: client order of events

VoiceBar's side of click-a-word seek. The daemon side (player overlap, stale
seeks, Stop) is `formal/speech-word-seek`.

Run `python3 formal/check-model.py formal/teleprompter-a-seek`. Add `--record` only to refresh the committed evidence.

| Config | Result | What breaks |
| --- | --- | --- |
| Fixed | PASS, 2,640 states | n/a |
| StaleTableMutant | FAIL TableIsCurrent | a new `utteranceId` keeps the old word table |
| PausedSeekMutant | FAIL NoPausedSeek | a paused column still offers seek targets |
| StaleSlideMutant | FAIL SettledShowsClock | a slide settles on the line it started for, ignoring a seek that landed mid-slide |
| OldPausedSliderMutant | FAIL NoPausedSliderSend | 2.4 V3-7: the scrubber slider stays seekable while paused and sends an offset seek the daemon rejects `paused` |
| OldTimingNoticeMutant | FAIL TruthfulTimingNotice | 2.4 V3-6: "Word timing unavailable" reads only legacy `statusText`/`wordBoundaries` while a `speech_words` table drives the highlight |

Mapping:
- `Advance` is `state(speaking)` with a new `utteranceId`. `VoiceState` replaces `speechWords`.
- `Click` is a word button. The target comes from the table the word was drawn from, and it is nil while paused (`TeleprompterAView`, plus the `seekSpeechWord` guard).
- `SeekLand` is the daemon accepting only the current, unpaused utterance.
- `Tick`/`SlideEnd` is the 240 ms slide. The view derives the focus line from the clock on every frame and animates `.animation(value: scrolled)`, so a mid-slide seek retargets the slide. Nothing stores a slide destination.

- `Slide` is the scrubber (`TeleprompterPlaybackScrubBar.control`, gated by `isTeleprompterScrubSeekable`). It sends an offset seek of whatever plays.
- `Words` is `speech_words` for the table on screen. `HighlightTimed` is focusWord's timing source (the table, else legacy timestamps). `NoticeShown` is `timingNotice`. The notice never authorises a seek: the Click/Slide gates do not read timing.

Bounds: two utterances, three lines, three sends (clicks and slides share the count). This is a model proof, not native acceptance.
