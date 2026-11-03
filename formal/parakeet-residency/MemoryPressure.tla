---------------------------- MODULE MemoryPressure ----------------------------
EXTENDS Naturals
VARIABLES resident, busy, stage, pressureUnloadedBusy, defaultIdleEviction, idleEnabled
vars == <<resident, busy, stage, pressureUnloadedBusy, defaultIdleEviction, idleEnabled>>
Init == /\ resident = FALSE /\ busy = "idle" /\ stage = "warming"
        /\ pressureUnloadedBusy = FALSE /\ defaultIdleEviction = FALSE
        /\ idleEnabled = FALSE
\* The app/daemon is already serving capture commands while the pipe warms.
CaptureStart == /\ busy = "idle" /\ busy' = "capture"
                /\ UNCHANGED <<resident,stage,pressureUnloadedBusy,defaultIdleEviction,idleEnabled>>
WarmCompletes == /\ stage = "warming" /\ stage' = "ready" /\ resident' = TRUE
                 /\ UNCHANGED <<busy,pressureUnloadedBusy,defaultIdleEviction,idleEnabled>>
InferenceStart == /\ busy = "capture" /\ stage = "ready" /\ resident
                  /\ busy' = "transcribing"
                  /\ UNCHANGED <<resident,stage,pressureUnloadedBusy,defaultIdleEviction,idleEnabled>>
InferenceCompletes == /\ busy = "transcribing" /\ busy' = "idle"
                      /\ UNCHANGED <<resident,stage,pressureUnloadedBusy,defaultIdleEviction,idleEnabled>>
\* This is the busy check inside the serialized daemon stop, not a stale app probe.
Pressure == /\ resident /\ stage = "ready" /\ busy = "idle"
            /\ resident' = FALSE
            /\ pressureUnloadedBusy' = (pressureUnloadedBusy \/ busy # "idle")
            /\ UNCHANGED <<busy,stage,defaultIdleEviction,idleEnabled>>
NextDictationReload == /\ ~resident /\ stage = "ready" /\ busy = "capture"
                       /\ stage' = "warming"
                       /\ UNCHANGED <<resident,busy,pressureUnloadedBusy,defaultIdleEviction,idleEnabled>>
SetIdlePolicy == /\ idleEnabled' = ~idleEnabled
                 /\ UNCHANGED <<resident,busy,stage,pressureUnloadedBusy,defaultIdleEviction>>
IdleExpiry == /\ resident /\ stage = "ready" /\ busy = "idle" /\ idleEnabled
              /\ resident' = FALSE
              /\ defaultIdleEviction' = (defaultIdleEviction \/ ~idleEnabled)
              /\ UNCHANGED <<busy,stage,pressureUnloadedBusy,idleEnabled>>
Next == CaptureStart \/ WarmCompletes \/ InferenceStart \/ InferenceCompletes \/ Pressure \/
        NextDictationReload \/ SetIdlePolicy \/ IdleExpiry
Spec == Init /\ [][Next]_vars
PressureNeverUnloadsBusy == ~pressureUnloadedBusy
DefaultNeverIdleEvicts == ~defaultIdleEviction
BootCaptureAllowed == (stage = "warming" /\ busy = "idle") => ENABLED CaptureStart
=============================================================================
