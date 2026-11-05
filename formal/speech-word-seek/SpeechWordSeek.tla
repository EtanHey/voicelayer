-------------------------- MODULE SpeechWordSeek --------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS SkipReap, SkipIdentity, SkipStopFence
VARIABLES owner, latest, serial, players, pending, restart, staleSeek, stoppedSeek
vars == <<owner, latest, serial, players, pending, restart, staleSeek, stoppedSeek>>
Token(id, n) == [id |-> id, n |-> n]
Init == /\ owner = 0 /\ latest = 0 /\ serial = 0 /\ players = {} /\ pending = Token(0, 0) /\ restart = Token(0, 0)
        /\ staleSeek = FALSE /\ stoppedSeek = FALSE
Arrive == /\ latest < 2 /\ serial < 4
          /\ owner' = latest + 1 /\ latest' = latest + 1 /\ serial' = serial + 1
          /\ restart' = Token(latest + 1, serial + 1)
          /\ UNCHANGED <<players, pending, staleSeek, stoppedSeek>>
Seek == /\ owner # 0 /\ serial < 4
        /\ pending' = Token(owner, serial + 1) /\ serial' = serial + 1
        /\ UNCHANGED <<owner, latest, players, restart, staleSeek, stoppedSeek>>
Decode == /\ pending.id # 0 /\ pending' = Token(0, 0)
          /\ IF owner = 0 THEN
                /\ stoppedSeek' = SkipStopFence
                /\ restart' = IF SkipStopFence THEN pending ELSE restart
                /\ UNCHANGED staleSeek
              ELSE IF pending.id = owner \/ SkipIdentity THEN
                /\ staleSeek' = (staleSeek \/ pending.id # owner)
                /\ restart' = pending /\ UNCHANGED stoppedSeek
              ELSE UNCHANGED <<restart, staleSeek, stoppedSeek>>
          /\ UNCHANGED <<owner, latest, serial, players>>
Start == /\ restart.id # 0 /\ (players = {} \/ SkipReap)
         /\ players' = players \cup {restart} /\ restart' = Token(0, 0)
         /\ UNCHANGED <<owner, latest, serial, pending, staleSeek, stoppedSeek>>
Reap == /\ players # {} /\ \E p \in players: players' = players \ {p}
        /\ UNCHANGED <<owner, latest, serial, pending, restart, staleSeek, stoppedSeek>>
Stop == /\ owner # 0 /\ owner' = 0 /\ restart' = Token(0, 0)
        /\ UNCHANGED <<latest, serial, players, pending, staleSeek, stoppedSeek>>
Next == Arrive \/ Seek \/ Decode \/ Start \/ Reap \/ Stop
Spec == Init /\ [][Next]_vars
SinglePlayer == Cardinality(players) <= 1
FreshSeek == ~staleSeek
StopWins == ~stoppedSeek
=============================================================================
