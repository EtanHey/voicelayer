------------------------- MODULE NotchPresentation -------------------------
EXTENDS Integers, FiniteSets
CONSTANTS Variant, Fault
\* Lane A mutants (union with Lane G's set): "no-collapsed-shell" drops only the shell a notice gets in a collapsed
\* notch (VisibleHasShell); "timer-range" arms a note timer outside 0..2 (TypeOK); "timer-reset" re-arms the
\* timer instead of expiring the note (NoteNeverStuck, temporal).
VARIABLES s, shown
vars == <<s, shown>>
Modes == {"idle", "recording", "transcribing", "speaking", "error", "disconnected"}
Notes == {"none", "busy", "quit", "rejection"}
Busy(x) == x.mode \in {"recording", "transcribing", "speaking"} \/ x.updateBusy \/ x.preview
SelectionBusy(x) == x.mode \in {"recording", "transcribing"} \/ x.preview
StatusVisible(x) == x.mode = "error" \/ (x.mode = "idle" /\ (x.status # "none" \/ x.preview))
StatusText(x) == IF x.mode = "error" /\ x.status = "none" THEN IF Fault = "details-substitute" /\ x.details THEN "Details below" ELSE IF Variant = "fixed" /\ Fault # "error-substitute" THEN "none" ELSE "Error"
                 ELSE IF x.mode = "idle" /\ x.status = "none" /\ x.preview THEN "preview" ELSE x.status
WingConfirmation(x) == x.mode = "idle" /\ x.status = "short" /\ x.lines = 1
HasStatusBand(x, shell) == x.mode = "error" \/
                         (x.mode = "idle" /\ shell \in {"compactStatus", "history"} /\
                          (x.status = "long" \/ (x.status = "short" /\ x.lines > 1) \/ (x.status = "select" /\ shell = "history")))
Normalize(x) ==
  IF (x.note = "busy" /\ ~SelectionBusy(x))
     \/ (Variant = "fixed" /\ Fault # "stale-note" /\ x.note = "quit" /\ ~Busy(x))
  THEN [x EXCEPT !.note = "none", !.timer = 0] ELSE x
Project(x) ==
  LET note == x.note # "none" /\ (Variant # "fixed" \/ Fault = "processing-note" \/ x.mode # "transcribing")
      collapsedIdle == x.mode = "idle" /\ x.collapsed /\ ~x.engaged
      compact == x.mode \in {"transcribing", "speaking", "error", "disconnected"}
                 \/ (x.mode = "idle" /\ (x.status # "none" \/ x.preview) /\ ~collapsedIdle)
      tele == ~collapsedIdle /\ x.teleprompter /\ ~(x.mode = "idle" /\ compact)
      \* Etan, QA 0510 R3: a drawer (History or Settings) hangs under the recording wings too; only the
      \* teleprompter outranks it.
      baseShell == IF tele THEN "teleprompter" ELSE IF x.history THEN "history"
               ELSE IF x.mode = "recording" THEN "recording" ELSE IF compact THEN "compactStatus"
               ELSE IF x.engaged \/ note \/ (x.mode = "idle" /\ ~x.collapsed) THEN "hoverLauncher" ELSE "idle"
      status == StatusVisible(x) /\ (StatusText(x) # "none")
                /\ (Variant = "fixed" \/ HasStatusBand(x, baseShell) \/ baseShell = "compactStatus")
      \* Status acknowledgements use the transient status surface; history contains substantive responses.
      \* confirmation with no note beside it is the right wing's own label, in a compact (or collapsed) notch.
      \* Multi-line recovery copy, long copy and anything sharing the notch with a note or History stay the tab.
      wingConfirm == Variant = "fixed" /\ Fault # "confirmation-tab" /\ status /\ ~note
                     /\ WingConfirmation(x) /\ baseShell \in {"compactStatus", "idle"}
      visible == note \/ (status /\ StatusText(x) # "preview" /\ ~wingConfirm)
      shell == IF Fault = "no-shell" THEN "idle"
               ELSE IF Variant = "fixed" /\ Fault # "no-collapsed-shell" /\ (visible \/ wingConfirm) /\ baseShell = "idle" THEN "compactStatus"
               ELSE baseShell
      band == IF Fault = "outside-band" THEN visible /\ ~note ELSE IF Variant = "fixed" THEN visible ELSE HasStatusBand(x, shell) \/ note
      \* Lane A refinement: the F5 hint is an operational label, not a notice. Fixed draws it only as the sole
      \* content of a compact-status wing: never in a collapsed (idle) shell, never beside a visible notice.
      hinted == status /\ (Variant # "fixed" \/ StatusText(x) # "preview" \/ (~visible /\ shell = "compactStatus"))
      wingText == IF Variant = "fixed" /\ visible /\ Fault # "text-wing" THEN "none"
                  ELSE IF hinted /\ x.status # "long" /\ shell = "compactStatus" /\
                          ~(x.mode = "error" /\ x.status = "select") /\ (x.status # "short" \/ x.lines = 1) THEN StatusText(x) ELSE "none"
      leading == 48
      trailing == IF Fault = "wide-wing" THEN 186 ELSE IF Fault = "core-wing" THEN 185 ELSE IF wingText # "none" THEN 132 ELSE 78
      statusLines == IF ~hinted \/ ~band THEN 0 ELSE IF x.status = "select" THEN 2 ELSE IF x.status \in {"long", "short"} THEN x.lines ELSE 1
      noteLines == IF note /\ band THEN x.lines ELSE 0
      rows == (IF statusLines > 0 THEN 1 ELSE 0) + (IF noteLines > 0 THEN 1 ELSE 0)
      pixels == IF Fault = "truncate" /\ band THEN 26 ELSE 16 * (statusLines + noteLines) + 10 * rows
      requiredStatus == status /\ x.mode = "error"
      statusAction == requiredStatus /\ Fault # "error-history"
      noteAction == note /\ x.note = "busy" /\ Variant = "fixed" /\ Fault # "busy-history"
      requiredActions == (IF requiredStatus THEN 1 ELSE 0) + (IF note /\ x.note = "busy" THEN 1 ELSE 0)
      actions == (IF statusAction THEN 1 ELSE 0) + (IF noteAction THEN 1 ELSE 0)
  IN [shell |-> shell, visible |-> visible, band |-> band,
      wingText |-> wingText, leading |-> leading, trailing |-> trailing, core |-> 185,
      feedbackWidth |-> 185 + leading + trailing, bandHeight |-> pixels,
      bandLines |-> IF band THEN (pixels - 10 * rows) \div 16 ELSE 0,
      text |-> IF hinted THEN StatusText(x) ELSE "none",
      historyInline |-> requiredActions > 0 /\ actions = requiredActions,
      transient |-> note]

Publish(x) == /\ s' = Normalize(x) /\ shown' = Project(Normalize(x))
Init == /\ s \in [mode : {"idle"}, status : {"none"}, note : {"none"}, timer : {0},
                  raised : {{}}, updateBusy : BOOLEAN, history : BOOLEAN,
                  teleprompter : BOOLEAN, engaged : BOOLEAN, collapsed : BOOLEAN, preview : BOOLEAN, details : BOOLEAN, lines : 1..3]
        /\ (s.history => ~s.teleprompter /\ ~s.preview)
        /\ (s.engaged => ~s.collapsed /\ ~s.preview)
        /\ shown = IF Fault = "type" THEN [Project(s) EXCEPT !.bandHeight = -1] ELSE Project(s)
SetMode(m) == /\ m \in Modes /\ m # s.mode
              /\ Publish([s EXCEPT !.mode = m, !.status = "none"])
SetStatus(t) == /\ s.mode \in {"idle", "error"} /\ t \in {"none", "short", "long", "select"}
                /\ t # s.status /\ Publish([s EXCEPT !.status = t])
ShowNote(n) == /\ n \in Notes \ {"none"} /\ n \notin s.raised
               /\ (n = "busy" => SelectionBusy(s))
               /\ (n = "quit" => Busy(s))
               /\ Publish([s EXCEPT !.note = n, !.timer = IF Fault = "timer-range" THEN 3 ELSE 2,
                                    !.raised = @ \cup {n}])
EndUpdate == /\ s.updateBusy /\ Publish([s EXCEPT !.updateBusy = FALSE])
EndPreview == /\ s.preview /\ Publish([s EXCEPT !.preview = FALSE])
Expire == /\ s.timer > 0 /\ Fault # "never-expire"
          /\ Publish([s EXCEPT !.timer = IF Fault = "timer-reset" /\ s.timer = 1 THEN 2 ELSE @ - 1,
                               !.note = IF s.timer = 1 /\ Fault # "timer-reset" THEN "none" ELSE @])
Next == (\E m \in Modes: SetMode(m)) \/ (\E t \in {"none", "short", "long", "select"}: SetStatus(t))
        \/ (\E n \in Notes \ {"none"}: ShowNote(n)) \/ EndUpdate \/ EndPreview \/ Expire
Spec == Init /\ [][Next]_vars /\ (Fault = "unfair" \/ WF_vars(Expire))
TypeOK == /\ s.mode \in Modes /\ s.note \in Notes /\ s.timer \in 0..2
          /\ s.status \in {"none", "short", "long", "select"} /\ s.lines \in 1..3 /\ s.details \in BOOLEAN
          /\ s.raised \subseteq Notes \ {"none"} /\ shown.bandHeight \in Nat
          /\ ((s.note = "none") = (s.timer = 0))
N1CompactNote == /\ shown.leading <= 132 /\ shown.trailing <= 132
                 /\ (shown.visible => shown.wingText = "none" /\
                     shown.feedbackWidth <= shown.core + shown.leading + shown.trailing)
VisibleHasShell == shown.visible => shown.shell # "idle"
\* 2.3 N1: a one-line idle confirmation alone in a compact or collapsed notch is the right wing's label, with no
\* band under the notch.
N6ConfirmationInWing == (WingConfirmation(s) /\ s.note = "none" /\ ~s.history /\ shown.shell = "compactStatus")
                        => shown.wingText = s.status /\ ~shown.band /\ shown.trailing <= 132
N2NoProcessingBand == s.mode = "transcribing" => ~shown.band
TextLines(x) == (IF x.mode = "error" /\ StatusText(x) # "none" THEN IF x.status \in {"long", "short"} THEN x.lines ELSE IF x.status = "select" THEN 2 ELSE 1
                ELSE IF x.mode = "idle" /\ x.status # "none" THEN IF x.status \in {"long", "short"} THEN x.lines ELSE IF x.status = "select" THEN 2 ELSE 1 ELSE 0) +
               (IF x.note # "none" THEN x.lines ELSE 0)
N3GrowsDown == (shown.visible /\ TextLines(s) > 0) => shown.band /\ shown.bandLines >= TextLines(s)
N4NoSubstitute == shown.text \notin {"Error", "Details below"}
N5InlineHistory == ((shown.text # "none" /\ s.mode = "error") \/
                   (shown.transient /\ s.note = "busy")) => shown.historyInline
NoteHasCause == shown.transient => /\ (s.note = "quit" => Busy(s))
                                   /\ (s.note = "busy" => SelectionBusy(s))
                                   /\ (s.note = "rejection" => s.timer > 0)
NoteNeverStuck == (s.note # "none") ~> (s.note = "none")
=============================================================================
