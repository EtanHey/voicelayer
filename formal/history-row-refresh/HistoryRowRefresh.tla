-------------------------- MODULE HistoryRowRefresh --------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Incremental, Replay
VARIABLES disk, displayed, loading, snapshot, pending, delivered, observed, completed, interrupted
vars == <<disk, displayed, loading, snapshot, pending, delivered, observed, completed, interrupted>>

Init == /\ disk = 0 /\ displayed = 0 /\ loading = FALSE /\ snapshot = 0
        /\ pending = 0 /\ delivered = {} /\ observed = 0 /\ completed = FALSE /\ interrupted = FALSE

StartPage == /\ ~loading /\ ~completed
             /\ loading' = TRUE /\ snapshot' = disk
             /\ UNCHANGED <<disk, displayed, pending, delivered, observed, completed, interrupted>>

ArchiveWrite == /\ disk < 2 /\ disk' = disk + 1
                /\ UNCHANGED <<displayed, loading, snapshot, pending, delivered, observed, completed, interrupted>>

ArchiveEvent(version) == /\ version \in 1..disk /\ version \notin delivered
                /\ delivered' = delivered \cup {version}
                /\ displayed' = (IF Incremental /\ version >= observed THEN version ELSE displayed)
                /\ loading' = (IF Incremental THEN loading ELSE FALSE)
                /\ pending' = (IF Incremental /\ loading /\ Replay /\ version >= observed THEN version ELSE pending)
                /\ observed' = (IF version >= observed THEN version ELSE observed)
                /\ interrupted' = (interrupted \/ (~Incremental /\ loading))
                /\ UNCHANGED <<disk, snapshot, completed>>

FinishPage == /\ loading
              /\ displayed' = (IF Replay /\ pending > 0 THEN pending ELSE snapshot)
              /\ loading' = FALSE /\ completed' = TRUE /\ pending' = 0
              /\ UNCHANGED <<disk, snapshot, delivered, observed, interrupted>>

Next == StartPage \/ ArchiveWrite \/ (\E version \in 1..2: ArchiveEvent(version)) \/ FinishPage
Spec == Init /\ [][Next]_vars
PagingNotCancelled == ~interrupted
SettledPageIsFresh == (completed /\ delivered = {1, 2}) => displayed = disk
=============================================================================
