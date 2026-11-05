-------------------------- MODULE ReadyTimePaste --------------------------
EXTENDS Naturals
CONSTANTS OldPolicy, DoubleDelivery, AllowSecure
Targets == {"editor", "system", "voicebar", "secure", "none"}
Valid(t) == t \in Targets \ {"secure", "none"}
VARIABLES phase, focus, startFocus, readyFocus, selected, count, delivered
vars == <<phase, focus, startFocus, readyFocus, selected, count, delivered>>
Init == /\ phase = "idle" /\ focus \in Targets
        /\ startFocus = "none" /\ readyFocus = "none" /\ selected = "none"
        /\ count = 0 /\ delivered = "none"
Record == /\ phase = "idle" /\ phase' = "recording" /\ startFocus' = focus
          /\ UNCHANGED <<focus, readyFocus, selected, count, delivered>>
\* Cycles allow arbitrarily many focus moves before text is ready.
Move == /\ phase \in {"recording", "written"} /\ focus' \in Targets
        /\ UNCHANGED <<phase, startFocus, readyFocus, selected, count, delivered>>
Ready == /\ phase = "recording" /\ phase' = "ready" /\ readyFocus' = focus
         /\ selected' = IF OldPolicy THEN startFocus ELSE focus
         /\ UNCHANGED <<focus, startFocus, count, delivered>>
Deliver == /\ phase = "ready" /\ phase' = "written"
           /\ LET eligible == (Valid(selected) \/ (AllowSecure /\ selected = "secure"))
                              /\ (~OldPolicy \/ selected = readyFocus)
              IN /\ count' = IF eligible THEN 1 ELSE 0
                 /\ delivered' = IF eligible THEN selected ELSE "none"
           /\ UNCHANGED <<focus, startFocus, readyFocus, selected>>
Complete == /\ phase = "written" /\ phase' = "done"
            /\ count' = IF DoubleDelivery /\ count = 1 THEN 2 ELSE count
            /\ UNCHANGED <<focus, startFocus, readyFocus, selected, delivered>>
Next == Record \/ Move \/ Ready \/ Deliver \/ Complete
Spec == Init /\ [][Next]_vars
DeliveredAtMostOnce == count <= 1
NeverIntoSecureField == delivered # "secure"
DeliversToReadyTimeFocus == (phase \in {"written", "done"} /\ Valid(readyFocus))
                          => (count >= 1 /\ delivered = readyFocus)
=============================================================================
