------------------------- MODULE ResidentRecognizer -------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS BrokenLegacy, BrokenRecovery
VARIABLES models, owner, stage, desired, target, recovery, pendingLegacy,
          request, capture, hold, previous
vars == <<models,owner,stage,desired,target,recovery,pendingLegacy,request,capture,hold,previous>>
Init == /\ models = {} /\ owner = "none" /\ stage = "idle"
        /\ desired = "W" /\ target = "P" /\ previous = "W" /\ recovery = "none"
        /\ pendingLegacy = FALSE /\ request = FALSE /\ capture = FALSE /\ hold = FALSE
BeginPicker(t) == /\ owner = "none" /\ ~request /\ ~capture /\ ~hold
                  /\ owner' = "picker" /\ stage' = "stopP" /\ target' = t
                  /\ previous' = IF models = {} THEN desired ELSE CHOOSE e \in models: TRUE
                  /\ UNCHANGED <<models,desired,recovery,pendingLegacy,request,capture,hold>>
StopP == /\ owner = "picker" /\ stage = "stopP"
         /\ models' = models \ {"P"} /\ stage' = "stopW"
         /\ UNCHANGED <<previous,owner,desired,target,recovery,pendingLegacy,request,capture,hold>>
StopW == /\ owner = "picker" /\ stage = "stopW" /\ ~capture
         /\ models' = models \ {"W"} /\ stage' = "load" /\ desired' = target /\ recovery' = "none"
         /\ UNCHANGED <<previous,owner,target,pendingLegacy,request,capture,hold>>
Load == /\ owner = "picker" /\ stage = "load" /\ ~capture /\ ~hold
        /\ models = {} /\ models' = {target} /\ owner' = "none" /\ stage' = "idle"
        /\ UNCHANGED <<previous,desired,target,recovery,pendingLegacy,request,capture,hold>>
StartupFails == /\ owner = "picker" /\ stage = "load" /\ ~capture
                /\ models' = {target} /\ stage' = "cleanup"
                /\ UNCHANGED <<previous,owner,desired,target,recovery,pendingLegacy,request,capture,hold>>
RecoveryCleanup == /\ owner = "picker" /\ stage = "cleanup"
                   /\ models' = {} /\ stage' = "recover"
                   /\ UNCHANGED <<previous,owner,desired,target,recovery,pendingLegacy,request,capture,hold>>
RecoverPrevious == /\ owner = "picker" /\ stage = "recover" /\ ~capture /\ ~hold
                   /\ models = {}
                   /\ models' = IF previous = target THEN {} ELSE {previous}
                   /\ recovery' = IF previous = target THEN "none" ELSE previous
                   /\ owner' = "none" /\ stage' = "idle"
                   /\ UNCHANGED <<previous,desired,target,pendingLegacy,request,capture,hold>>
UnknownCleanup == /\ owner = "picker" /\ stage \in {"stopP","stopW","cleanup"}
                  /\ hold' = TRUE /\ owner' = "blocked" /\ stage' = "hold"
                  /\ UNCHANGED <<previous,models,desired,target,recovery,pendingLegacy,request,capture>>
ConfirmedCleanup == /\ hold /\ models' = {} /\ hold' = FALSE /\ recovery' = "none"
                    /\ owner' = "none" /\ stage' = "idle" /\ pendingLegacy' = FALSE
                    /\ UNCHANGED <<previous,desired,target,request,capture>>
CaptureChanges == /\ capture' = ~capture
                  /\ UNCHANGED <<previous,models,owner,stage,desired,target,recovery,pendingLegacy,request,hold>>
CaptureWins == /\ capture /\ owner = "picker" /\ stage \in {"stopW","load","recover"}
               /\ owner' = "none" /\ stage' = "idle"
               /\ UNCHANGED <<previous,models,desired,target,recovery,pendingLegacy,request,capture,hold>>
LegacyStart == /\ owner = "none" /\ ~capture /\ ~request /\ ~hold /\ ~pendingLegacy /\ desired = "W" /\ recovery # "P"
               /\ pendingLegacy' = TRUE /\ owner' = IF BrokenLegacy THEN "none" ELSE "legacy"
               /\ UNCHANGED <<previous,models,stage,desired,target,recovery,request,capture,hold>>
LegacyCompletes == /\ pendingLegacy /\ ~capture /\ ~hold
                   /\ models' = models \cup {"W"} /\ pendingLegacy' = FALSE
                   /\ owner' = IF owner = "legacy" THEN "none" ELSE owner
                   /\ UNCHANGED <<previous,stage,desired,target,recovery,request,capture,hold>>
RequestStart == /\ owner = "none" /\ ~request /\ ~capture /\ ~hold
                /\ request' = TRUE
                /\ models' = IF recovery # "none" /\ ~BrokenRecovery THEN {recovery} ELSE models \cup {desired}
                /\ UNCHANGED <<previous,owner,stage,desired,target,recovery,pendingLegacy,capture,hold>>
RequestCompletes == /\ request /\ request' = FALSE
                    /\ UNCHANGED <<previous,models,owner,stage,desired,target,recovery,pendingLegacy,capture,hold>>
Next == (\E t \in {"P","W"}: BeginPicker(t)) \/ StopP \/ StopW \/ Load \/ StartupFails \/
        RecoveryCleanup \/ RecoverPrevious \/ UnknownCleanup \/ ConfirmedCleanup \/ CaptureChanges \/
        CaptureWins \/ LegacyStart \/ LegacyCompletes \/ RequestStart \/ RequestCompletes
Spec == Init /\ [][Next]_vars
OneModel == Cardinality(models) <= 1
UnknownBlocks == hold => (owner = "blocked" /\ ~request)
=============================================================================
