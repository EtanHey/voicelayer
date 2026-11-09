------------------------- MODULE TeleprompterASeek -------------------------
(* U5 client order of events: a word click during a line slide, against Pause/Resume
   and a queue advance. Daemon-side seek safety is SpeechWordSeek's; this models VoiceBar.
   2.4 teleprompter freeze (V3-6, V3-7): the scrubber slider is a second seek sender, and the
   "Word timing unavailable" notice is drawn from the client's timing sources. *)
EXTENDS Naturals
CONSTANTS SkipTableReset, SkipPauseGate, StaleSlide,
          SliderIgnoresPause,  \* isTeleprompterScrubSeekable ignores pause (VoiceState.swift), the scrubber sends anyway
          LegacyNotice         \* timingNotice reads only statusText/wordBoundaries, not the speech_words table
VARIABLES utt, table, paused, clockLine, shown, sliding, slideTo, pending, sends, pausedSend,
          timed, legacy, pausedOffsetSend
vars == <<utt, table, paused, clockLine, shown, sliding, slideTo, pending, sends, pausedSend,
          timed, legacy, pausedOffsetSend>>
Lines == 0..2
Init == /\ utt = 1 /\ table = 1 /\ paused = FALSE /\ clockLine = 0 /\ shown = 0
        /\ sliding = FALSE /\ slideTo = 0 /\ pending = [u |-> 0, line |-> 0] /\ sends = 0 /\ pausedSend = FALSE
        /\ timed = FALSE /\ legacy = FALSE /\ pausedOffsetSend = FALSE
\* state(speaking) with a new utteranceId: VoiceState replaces the word table (no timed words yet). The legacy
\* subtitle boundaries may or may not carry server timestamps for this utterance.
Advance == /\ utt < 2 /\ utt' = utt + 1 /\ table' = IF SkipTableReset THEN table ELSE utt + 1
           /\ paused' = FALSE /\ clockLine' = 0 /\ sliding' = TRUE /\ slideTo' = 0
           /\ timed' = FALSE /\ legacy' \in BOOLEAN
           /\ UNCHANGED <<shown, pending, sends, pausedSend, pausedOffsetSend>>
\* speech_words for the table on screen: a valid timing table now drives the highlight (focusWord).
Words == /\ table = utt /\ ~timed /\ timed' = TRUE
         /\ UNCHANGED <<utt, table, paused, clockLine, shown, sliding, slideTo, pending, sends, pausedSend, legacy, pausedOffsetSend>>
\* The audio clock reaches the next line: the column starts its 240 ms slide.
Tick == /\ ~paused /\ clockLine < 2 /\ clockLine' = clockLine + 1 /\ sliding' = TRUE /\ slideTo' = clockLine + 1
        /\ UNCHANGED <<utt, table, paused, shown, pending, sends, pausedSend, timed, legacy, pausedOffsetSend>>
SlideEnd == /\ sliding /\ sliding' = FALSE /\ shown' = IF StaleSlide THEN slideTo ELSE clockLine
            /\ UNCHANGED <<utt, table, paused, clockLine, slideTo, pending, sends, pausedSend, timed, legacy, pausedOffsetSend>>
\* A word button names the table it was drawn from; a paused column has no seek target.
Click(l) == /\ sends < 3 /\ (~paused \/ SkipPauseGate)
            /\ pending' = [u |-> table, line |-> l] /\ sends' = sends + 1 /\ pausedSend' = (pausedSend \/ paused)
            /\ UNCHANGED <<utt, table, paused, clockLine, shown, sliding, slideTo, timed, legacy, pausedOffsetSend>>
\* The scrubber slider: an offset seek (speech_seek scope "current") of whatever plays. It is enabled only while
\* the scrubber allows seeking; a paused read is rejected by the daemon (seekPlayback "paused"), so it must not send.
Slide(l) == /\ sends < 3 /\ (~paused \/ SliderIgnoresPause)
            /\ pending' = [u |-> utt, line |-> l] /\ sends' = sends + 1
            /\ pausedOffsetSend' = (pausedOffsetSend \/ paused)
            /\ UNCHANGED <<utt, table, paused, clockLine, shown, sliding, slideTo, pausedSend, timed, legacy>>
\* The daemon accepts only its current, unpaused utterance; the player restarts at the word.
SeekLand == /\ pending.u # 0 /\ pending' = [u |-> 0, line |-> 0]
            /\ IF pending.u = utt /\ ~paused
               THEN /\ clockLine' = pending.line /\ sliding' = TRUE
                    /\ slideTo' = IF StaleSlide THEN slideTo ELSE pending.line
               ELSE UNCHANGED <<clockLine, sliding, slideTo>>
            /\ UNCHANGED <<utt, table, paused, shown, sends, pausedSend, timed, legacy, pausedOffsetSend>>
Pause == /\ ~paused /\ paused' = TRUE
         /\ UNCHANGED <<utt, table, clockLine, shown, sliding, slideTo, pending, sends, pausedSend, timed, legacy, pausedOffsetSend>>
Resume == /\ paused /\ paused' = FALSE
          /\ UNCHANGED <<utt, table, clockLine, shown, sliding, slideTo, pending, sends, pausedSend, timed, legacy, pausedOffsetSend>>
Next == Advance \/ Words \/ Tick \/ SlideEnd \/ (\E l \in Lines: Click(l) \/ Slide(l)) \/ SeekLand \/ Pause \/ Resume
Spec == Init /\ [][Next]_vars
\* The highlight has a timing source: the speech_words table on screen, or legacy subtitle timestamps.
HighlightTimed == timed \/ legacy
\* What TeleprompterPlaybackScrubBar.timingNotice shows ("Word timing unavailable").
NoticeShown == IF LegacyNotice THEN ~legacy ELSE ~HighlightTimed
\* The words on screen (and every click target) belong to the utterance playing.
TableIsCurrent == table = utt
NoPausedSeek == ~pausedSend
\* Once a slide settles, the column shows the line the clock names: a seek mid-slide retargets it.
SettledShowsClock == ~sliding => shown = clockLine
\* V3-7: a paused read never sends an offset seek from the slider (the daemon rejects it "paused").
NoPausedSliderSend == ~pausedOffsetSend
\* V3-6: "Word timing unavailable" is never shown while a valid timing table drives the highlight. This is about the
\* notice only: timing never authorises a seek (Click/Slide gates are unchanged and audio-bound in SeekLand).
TruthfulTimingNotice == NoticeShown => ~HighlightTimed
=============================================================================
