------------------------- MODULE TeleprompterASeek -------------------------
(* U5 client order of events: a word click during a line slide, against Pause/Resume
   and a queue advance. Daemon-side seek safety is SpeechWordSeek's; this models VoiceBar. *)
EXTENDS Naturals
CONSTANTS SkipTableReset, SkipPauseGate, StaleSlide
VARIABLES utt, table, paused, clockLine, shown, sliding, slideTo, pending, sends, pausedSend
vars == <<utt, table, paused, clockLine, shown, sliding, slideTo, pending, sends, pausedSend>>
Lines == 0..2
Init == /\ utt = 1 /\ table = 1 /\ paused = FALSE /\ clockLine = 0 /\ shown = 0
        /\ sliding = FALSE /\ slideTo = 0 /\ pending = [u |-> 0, line |-> 0] /\ sends = 0 /\ pausedSend = FALSE
\* state(speaking) with a new utteranceId: VoiceState replaces the word table.
Advance == /\ utt < 2 /\ utt' = utt + 1 /\ table' = IF SkipTableReset THEN table ELSE utt + 1
           /\ paused' = FALSE /\ clockLine' = 0 /\ sliding' = TRUE /\ slideTo' = 0
           /\ UNCHANGED <<shown, pending, sends, pausedSend>>
\* The audio clock reaches the next line: the column starts its 240 ms slide.
Tick == /\ ~paused /\ clockLine < 2 /\ clockLine' = clockLine + 1 /\ sliding' = TRUE /\ slideTo' = clockLine + 1
        /\ UNCHANGED <<utt, table, paused, shown, pending, sends, pausedSend>>
SlideEnd == /\ sliding /\ sliding' = FALSE /\ shown' = IF StaleSlide THEN slideTo ELSE clockLine
            /\ UNCHANGED <<utt, table, paused, clockLine, slideTo, pending, sends, pausedSend>>
\* A word button names the table it was drawn from; a paused column has no seek target.
Click(l) == /\ sends < 3 /\ (~paused \/ SkipPauseGate)
            /\ pending' = [u |-> table, line |-> l] /\ sends' = sends + 1 /\ pausedSend' = (pausedSend \/ paused)
            /\ UNCHANGED <<utt, table, paused, clockLine, shown, sliding, slideTo>>
\* The daemon accepts only its current, unpaused utterance; the player restarts at the word.
SeekLand == /\ pending.u # 0 /\ pending' = [u |-> 0, line |-> 0]
            /\ IF pending.u = utt /\ ~paused
               THEN /\ clockLine' = pending.line /\ sliding' = TRUE
                    /\ slideTo' = IF StaleSlide THEN slideTo ELSE pending.line
               ELSE UNCHANGED <<clockLine, sliding, slideTo>>
            /\ UNCHANGED <<utt, table, paused, shown, sends, pausedSend>>
Pause == /\ ~paused /\ paused' = TRUE /\ UNCHANGED <<utt, table, clockLine, shown, sliding, slideTo, pending, sends, pausedSend>>
Resume == /\ paused /\ paused' = FALSE /\ UNCHANGED <<utt, table, clockLine, shown, sliding, slideTo, pending, sends, pausedSend>>
Next == Advance \/ Tick \/ SlideEnd \/ (\E l \in Lines: Click(l)) \/ SeekLand \/ Pause \/ Resume
Spec == Init /\ [][Next]_vars
\* The words on screen (and every click target) belong to the utterance playing.
TableIsCurrent == table = utt
NoPausedSeek == ~pausedSend
\* Once a slide settles, the column shows the line the clock names: a seek mid-slide retargets it.
SettledShowsClock == ~sliding => shown = clockLine
=============================================================================
