--------------------------- MODULE CloneEngine ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Mode
VARIABLES engines, phase, wanted, quitting, stopped, delay, faults, foreignKilled, retiring
vars == <<engines, phase, wanted, quitting, stopped, delay, faults, foreignKilled, retiring>>

Init == /\ engines \in {{}, {"foreign"}}
        /\ phase = "checking" /\ wanted = TRUE /\ quitting = FALSE /\ stopped = FALSE
        /\ delay = 0 /\ faults = 2 /\ foreignKilled = FALSE /\ retiring = FALSE

Attempt == /\ ~retiring /\ wanted /\ ~quitting /\ phase = "checking" /\ Mode # "old"
           /\ (IF "foreign" \in engines /\ Mode # "mutant"
                 THEN /\ phase' = "running" /\ UNCHANGED engines
                 ELSE /\ phase' = "reserving" /\ UNCHANGED engines)
           /\ UNCHANGED <<wanted, quitting, stopped, delay, faults, foreignKilled, retiring>>
Reserve == /\ ~retiring /\ wanted /\ ~quitting /\ phase = "reserving"
           /\ (IF "foreign" \in engines /\ Mode # "mutant"
                   THEN /\ phase' = "running" /\ UNCHANGED engines
                   ELSE /\ engines' = engines \cup {"owned"} /\ phase' = "starting")
           /\ UNCHANGED <<wanted, quitting, stopped, delay, faults, foreignKilled, retiring>>
Ready == /\ phase = "starting" /\ "owned" \in engines
         /\ phase' = "running"
         /\ UNCHANGED <<engines, wanted, quitting, stopped, delay, faults, foreignKilled, retiring>>
Crash == /\ ~retiring /\ "owned" \in engines /\ faults > 0 /\ wanted /\ ~quitting
         /\ engines' = engines \ {"owned"} /\ phase' = "backoff"
         /\ delay' = 2 /\ faults' = faults - 1
         /\ UNCHANGED <<wanted, quitting, stopped, foreignKilled, retiring>>
Tick == /\ phase = "backoff" /\ delay > 0
        /\ delay' = delay - 1
        /\ UNCHANGED <<engines, phase, wanted, quitting, stopped, faults, foreignKilled, retiring>>
Retry == /\ wanted /\ ~quitting /\ phase = "backoff" /\ delay = 0
         /\ phase' = "checking"
         /\ UNCHANGED <<engines, wanted, quitting, stopped, delay, faults, foreignKilled, retiring>>
Stop == /\ ~quitting /\ ~stopped
        /\ ("owned" \in engines \/ engines = {})
        /\ retiring' = ("owned" \in engines)
        /\ phase' = (IF "owned" \in engines THEN "stopping" ELSE "stopped")
        /\ wanted' = FALSE /\ stopped' = TRUE /\ delay' = 0
        /\ UNCHANGED <<engines, quitting, faults, foreignKilled>>
Start == /\ stopped /\ ~quitting
         /\ wanted' = TRUE /\ stopped' = FALSE /\ phase' = "checking"
         /\ UNCHANGED <<engines, quitting, delay, faults, foreignKilled, retiring>>
Restart == /\ ~quitting /\ "owned" \in engines /\ faults > 0
           /\ retiring' = TRUE /\ phase' = "stopping"
           /\ wanted' = TRUE /\ stopped' = FALSE /\ delay' = 0
           /\ faults' = faults - 1
           /\ UNCHANGED <<engines, quitting, foreignKilled>>
Reap == /\ retiring /\ Mode # "unreaped"
        /\ engines' = engines \ {"owned"} /\ retiring' = FALSE
        /\ phase' = (IF wanted /\ ~quitting THEN "checking" ELSE "stopped")
        /\ UNCHANGED <<wanted, quitting, stopped, delay, faults, foreignKilled>>
Quit == /\ ~quitting
        /\ quitting' = TRUE /\ wanted' = FALSE /\ stopped' = TRUE /\ delay' = 0 /\ phase' = "stopped"
        /\ engines' = engines \ {"owned"} /\ retiring' = FALSE
        /\ foreignKilled' = foreignKilled \/ ("foreign" \in engines /\ "foreign" \notin engines')
        /\ UNCHANGED faults
ForeignAppears == /\ engines = {} /\ faults > 0 /\ ~quitting
                  /\ engines' = {"foreign"} /\ faults' = faults - 1
                  /\ UNCHANGED <<phase, wanted, quitting, stopped, delay, foreignKilled, retiring>>
ForeignExits == /\ "foreign" \in engines /\ faults > 0 /\ ~quitting
               /\ engines' = engines \ {"foreign"} /\ faults' = faults - 1
               /\ phase' = (IF wanted THEN "backoff" ELSE "stopped")
               /\ delay' = (IF wanted THEN 2 ELSE 0)
               /\ UNCHANGED <<wanted, quitting, stopped, foreignKilled, retiring>>
Next == Attempt \/ Reserve \/ Ready \/ Crash \/ Tick \/ Retry \/ Stop \/ Start \/ Restart \/ Reap \/ Quit \/ ForeignAppears \/ ForeignExits
Spec == Init /\ [][Next]_vars /\ WF_vars(Attempt) /\ WF_vars(Reserve) /\ WF_vars(Ready) /\ WF_vars(Tick) /\ WF_vars(Retry) /\ WF_vars(Reap)
AtMostOneEngine == Cardinality(engines) <= 1
NeverKillForeign == ~foreignKilled
StopWins == stopped => (("owned" \notin engines \/ retiring) /\ delay = 0 /\ ~wanted)
RetireRetainsOwner == retiring => "owned" \in engines
EventuallyStopped == stopped ~> ("owned" \notin engines \/ ~stopped)
EventuallyRunningIfAutostart == (wanted /\ ~quitting) ~> (phase = "running" \/ ~wanted \/ quitting)
=============================================================================
