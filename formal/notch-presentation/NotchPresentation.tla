------------------------- MODULE NotchPresentation -------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Variant
VARIABLES s, shown
vars == <<s, shown>>
Modes == {"idle", "recording", "transcribing", "speaking", "error", "disconnected"}
Notes == {"none", "busy", "quit", "rejection"}
Busy(x) == x.mode \in {"recording", "transcribing", "speaking"} \/ x.updateBusy \/ x.preview
SelectionBusy(x) == x.mode \in {"recording", "transcribing"} \/ x.preview
StatusVisible(x) == x.mode = "error" \/ (x.mode = "idle" /\ (x.status # "none" \/ x.preview))
StatusText(x) == IF x.mode = "error" /\ x.status = "none" THEN "Error"
                 ELSE IF x.mode = "idle" /\ x.status = "none" /\ x.preview THEN "preview" ELSE x.status
HasStatusBand(x, shell) == x.mode = "error" \/
                         (x.mode = "idle" /\ shell \in {"compactStatus", "history"} /\
                          (x.status = "long" \/ (x.status = "select" /\ shell = "history")))
Normalize(x) ==
  IF (x.note = "busy" /\ ~SelectionBusy(x))
     \/ (Variant = "fixed" /\ x.note = "quit" /\ ~Busy(x))
  THEN [x EXCEPT !.note = "none", !.timer = 0] ELSE x
Project(x) ==
  LET note == x.note # "none" /\ (Variant # "fixed" \/ x.mode # "transcribing")
      collapsedIdle == x.mode = "idle" /\ x.collapsed /\ ~x.engaged
      compact == x.mode \in {"transcribing", "speaking", "error", "disconnected"}
                 \/ (x.mode = "idle" /\ (x.status # "none" \/ x.preview) /\ ~collapsedIdle)
      tele == ~collapsedIdle /\ x.teleprompter /\ ~(x.mode = "idle" /\ compact)
      baseShell == IF tele THEN "teleprompter" ELSE IF x.mode = "recording" THEN "recording"
               ELSE IF x.history THEN "history" ELSE IF compact THEN "compactStatus"
               ELSE IF x.engaged \/ note \/ (x.mode = "idle" /\ ~x.collapsed) THEN "hoverLauncher" ELSE "idle"
      status == StatusVisible(x) /\ (Variant # "fixed" \/ StatusText(x) # "Error")
                /\ (Variant = "fixed" \/ HasStatusBand(x, baseShell) \/ baseShell = "compactStatus")
      visible == note \/ (status /\ StatusText(x) # "preview")
      shell == IF Variant = "fixed" /\ visible /\ baseShell = "idle" THEN "compactStatus" ELSE baseShell
      band == IF Variant = "fixed" THEN visible ELSE HasStatusBand(x, shell) \/ note
      wing == IF Variant = "fixed" /\ visible THEN FALSE
              ELSE status /\ x.status # "long" /\ shell = "compactStatus"
                   /\ ~(x.mode = "error" /\ x.status = "select")
  IN [shell |-> shell, visible |-> visible, band |-> band, wing |-> wing,
      variant |-> IF Variant = "fixed" \/ shell \notin {"history", "teleprompter"}
                  THEN "compact" ELSE "expanded",
      text |-> IF status THEN StatusText(x) ELSE "none",
      historyInline |-> (status /\ x.mode = "error") \/
                        (Variant = "fixed" /\ note /\ x.note = "busy"),
      busyHistoryInline |-> Variant = "fixed" /\ note /\ x.note = "busy",
      transient |-> note]
Publish(x) == /\ s' = Normalize(x) /\ shown' = Project(Normalize(x))
Init == /\ s \in [mode : {"idle"}, status : {"none"}, note : {"none"}, timer : {0},
                  raised : {{}}, updateBusy : BOOLEAN, history : BOOLEAN,
                  teleprompter : BOOLEAN, engaged : BOOLEAN, collapsed : BOOLEAN, preview : BOOLEAN]
        /\ shown = Project(s)
SetMode(m) == /\ m \in Modes /\ m # s.mode
              /\ Publish([s EXCEPT !.mode = m, !.status = "none"])
SetStatus(t) == /\ s.mode \in {"idle", "error"} /\ t \in {"none", "short", "long", "select"}
                /\ t # s.status /\ Publish([s EXCEPT !.status = t])
ShowNote(n) == /\ n \in Notes \ {"none"} /\ n \notin s.raised
               /\ (n = "busy" => SelectionBusy(s))
               /\ (n = "quit" => Busy(s))
               /\ Publish([s EXCEPT !.note = n, !.timer = 2, !.raised = @ \cup {n}])
EndUpdate == /\ s.updateBusy /\ Publish([s EXCEPT !.updateBusy = FALSE])
EndPreview == /\ s.preview /\ Publish([s EXCEPT !.preview = FALSE])
Expire == /\ s.timer > 0
          /\ Publish([s EXCEPT !.timer = @ - 1,
                               !.note = IF s.timer = 1 THEN "none" ELSE @])
Next == (\E m \in Modes: SetMode(m)) \/ (\E t \in {"none", "short", "long", "select"}: SetStatus(t))
        \/ (\E n \in Notes \ {"none"}: ShowNote(n)) \/ EndUpdate \/ EndPreview \/ Expire
Spec == Init /\ [][Next]_vars /\ WF_vars(Expire)
TypeOK == /\ s.mode \in Modes /\ s.note \in Notes /\ s.timer \in 0..2
          /\ s.status \in {"none", "short", "long", "select"}
          /\ s.raised \subseteq Notes \ {"none"}
          /\ s.updateBusy \in BOOLEAN /\ s.history \in BOOLEAN
          /\ s.teleprompter \in BOOLEAN /\ s.engaged \in BOOLEAN
          /\ s.collapsed \in BOOLEAN /\ s.preview \in BOOLEAN
          /\ shown = Project(s) /\ ((s.note = "none") = (s.timer = 0))
N1CompactNote == shown.visible => shown.variant = "compact" /\ ~shown.wing
VisibleHasShell == shown.visible => shown.shell # "idle"
N2NoProcessingBand == s.mode = "transcribing" => ~shown.band
N4NoSubstitute == shown.text \notin {"Error", "Details below"}
N5InlineHistory == /\ ((shown.text # "none" /\ s.mode = "error") => shown.historyInline)
                   /\ ((shown.transient /\ s.note = "busy") => shown.busyHistoryInline)
NoteHasCause == shown.transient => /\ (s.note = "quit" => Busy(s))
                                   /\ (s.note = "busy" => SelectionBusy(s))
                                   /\ (s.note = "rejection" => s.timer > 0)
NoteNeverStuck == (s.note # "none") ~> (s.note = "none")
=============================================================================
