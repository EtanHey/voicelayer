--------------------------- MODULE CloneEngine ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Mode
VARIABLES engines, phase, wanted, quitting, stopped, delay, faults, foreignKilled
vars == <<engines, phase, wanted, quitting, stopped, delay, faults, foreignKilled>>

Init == /\ engines \in {{}, {"foreign"}}
        /\ phase = "checking" /\ wanted = TRUE /\ quitting = FALSE /\ stopped = FALSE
        /\ delay = 0 /\ faults = 2 /\ foreignKilled = FALSE

Attempt == /\ wanted /\ ~quitting /\ phase = "checking" /\ Mode # "old"
           /\ (IF "foreign" \in engines /\ Mode # "mutant"
                 THEN /\ phase' = "running" /\ UNCHANGED engines
                 ELSE /\ phase' = "reserving" /\ UNCHANGED engines)
           /\ UNCHANGED <<wanted, quitting, stopped, delay, faults, foreignKilled>>
Reserve == /\ wanted /\ ~quitting /\ phase = "reserving"
           /\ (IF "foreign" \in engines /\ Mode # "mutant"
                   THEN /\ phase' = "running" /\ UNCHANGED engines
                   ELSE /\ engines' = engines \cup {"owned"} /\ phase' = "starting")
           /\ UNCHANGED <<wanted, quitting, stopped, delay, faults, foreignKilled>>
Ready == /\ phase = "starting" /\ "owned" \in engines
         /\ phase' = "running"
         /\ UNCHANGED <<engines, wanted, quitting, stopped, delay, faults, foreignKilled>>
Crash == /\ "owned" \in engines /\ faults > 0 /\ wanted /\ ~quitting
         /\ engines' = engines \ {"owned"} /\ phase' = "backoff"
         /\ delay' = 2 /\ faults' = faults - 1
         /\ UNCHANGED <<wanted, quitting, stopped, foreignKilled>>
Tick == /\ phase = "backoff" /\ delay > 0
        /\ delay' = delay - 1
        /\ UNCHANGED <<engines, phase, wanted, quitting, stopped, faults, foreignKilled>>
Retry == /\ wanted /\ ~quitting /\ phase = "backoff" /\ delay = 0
         /\ phase' = "checking"
         /\ UNCHANGED <<engines, wanted, quitting, stopped, delay, faults, foreignKilled>>
Stop == /\ ~quitting /\ ~stopped
        /\ ("owned" \in engines \/ engines = {})
        /\ engines' = engines \ {"owned"} /\ phase' = "stopped"
        /\ wanted' = FALSE /\ stopped' = TRUE /\ delay' = 0
        /\ UNCHANGED <<quitting, faults, foreignKilled>>
Start == /\ stopped /\ ~quitting
         /\ wanted' = TRUE /\ stopped' = FALSE /\ phase' = "checking"
         /\ UNCHANGED <<engines, quitting, delay, faults, foreignKilled>>
Restart == /\ ~quitting /\ "owned" \in engines /\ faults > 0
           /\ engines' = engines \ {"owned"} /\ phase' = "checking"
           /\ wanted' = TRUE /\ stopped' = FALSE /\ delay' = 0
           /\ faults' = faults - 1
           /\ UNCHANGED <<quitting, foreignKilled>>
Quit == /\ ~quitting
        /\ quitting' = TRUE /\ wanted' = FALSE /\ stopped' = TRUE /\ delay' = 0 /\ phase' = "stopped"
        /\ engines' = engines \ {"owned"}
        /\ foreignKilled' = foreignKilled \/ ("foreign" \in engines /\ "foreign" \notin engines')
        /\ UNCHANGED faults
ForeignAppears == /\ engines = {} /\ faults > 0 /\ ~quitting
                  /\ engines' = {"foreign"} /\ faults' = faults - 1
                  /\ UNCHANGED <<phase, wanted, quitting, stopped, delay, foreignKilled>>
ForeignExits == /\ "foreign" \in engines /\ faults > 0 /\ ~quitting
               /\ engines' = engines \ {"foreign"} /\ faults' = faults - 1
               /\ phase' = (IF wanted THEN "backoff" ELSE "stopped")
               /\ delay' = (IF wanted THEN 2 ELSE 0)
               /\ UNCHANGED <<wanted, quitting, stopped, foreignKilled>>
Next == Attempt \/ Reserve \/ Ready \/ Crash \/ Tick \/ Retry \/ Stop \/ Start \/ Restart \/ Quit \/ ForeignAppears \/ ForeignExits
Spec == Init /\ [][Next]_vars /\ WF_vars(Attempt) /\ WF_vars(Reserve) /\ WF_vars(Ready) /\ WF_vars(Tick) /\ WF_vars(Retry)
AtMostOneEngine == Cardinality(engines) <= 1
NeverKillForeign == ~foreignKilled
StopWins == stopped => ("owned" \notin engines /\ delay = 0 /\ ~wanted)
EventuallyRunningIfAutostart == (wanted /\ ~quitting) ~> (phase = "running" \/ ~wanted \/ quitting)
=============================================================================
