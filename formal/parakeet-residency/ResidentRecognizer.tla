------------------------- MODULE ResidentRecognizer -------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS BrokenLegacy, BrokenRecovery, BrokenAssetsGate, BrokenReadyReselect
VARIABLES models, owner, stage, desired, target, recovery, pendingLegacy,
          request, capture, hold, previous, assetsPresent, attempted, deletedDuringCapture
vars == <<models,owner,stage,desired,target,recovery,pendingLegacy,request,capture,hold,previous,assetsPresent,attempted,deletedDuringCapture>>
Init == /\ models = {} /\ owner = "none" /\ stage = "idle"
        /\ desired = "W" /\ target = "P" /\ previous = "W" /\ recovery = "none"
        /\ pendingLegacy = FALSE /\ request = FALSE /\ capture = FALSE /\ hold = FALSE
        /\ assetsPresent \in {{"W"}, {"W","P"}} /\ attempted = {} /\ deletedDuringCapture = FALSE
BeginPicker(t) == /\ owner = "none" /\ ~request /\ ~capture /\ ~hold
                  /\ (BrokenReadyReselect \/ models # {t} \/ desired # t)
                  /\ owner' = "picker" /\ stage' = "stopP" /\ target' = t
                  /\ previous' = IF models = {} THEN desired ELSE CHOOSE e \in models: TRUE
                  /\ UNCHANGED <<models,desired,recovery,pendingLegacy,request,capture,hold,deletedDuringCapture>>
StopP == /\ owner = "picker" /\ stage = "stopP"
         /\ models' = models \ {"P"} /\ stage' = "stopW"
         /\ UNCHANGED <<previous,owner,desired,target,recovery,pendingLegacy,request,capture,hold,deletedDuringCapture>>
StopW == /\ owner = "picker" /\ stage = "stopW" /\ ~capture
         /\ models' = models \ {"W"} /\ stage' = "load" /\ desired' = target /\ recovery' = "none"
         /\ UNCHANGED <<previous,owner,target,pendingLegacy,request,capture,hold,deletedDuringCapture>>
Load == /\ owner = "picker" /\ stage = "load" /\ ~capture /\ ~hold
        /\ models = {} /\ models' = {target} /\ owner' = "none" /\ stage' = "idle"
        /\ UNCHANGED <<previous,desired,target,recovery,pendingLegacy,request,capture,hold,deletedDuringCapture>>
StartupFails == /\ owner = "picker" /\ stage = "load" /\ ~capture
                /\ models' = {target} /\ stage' = "cleanup"
                /\ UNCHANGED <<previous,owner,desired,target,recovery,pendingLegacy,request,capture,hold,deletedDuringCapture>>
RecoveryCleanup == /\ owner = "picker" /\ stage = "cleanup"
                   /\ models' = {} /\ stage' = "recover"
                   /\ UNCHANGED <<previous,owner,desired,target,recovery,pendingLegacy,request,capture,hold,deletedDuringCapture>>
RecoverPrevious == /\ owner = "picker" /\ stage = "recover" /\ ~capture /\ ~hold
                   /\ models = {}
                   /\ models' = IF previous = target THEN {} ELSE {previous}
                   /\ recovery' = IF previous = target THEN "none" ELSE previous
                   /\ owner' = "none" /\ stage' = "idle"
                   /\ UNCHANGED <<previous,desired,target,pendingLegacy,request,capture,hold,deletedDuringCapture>>
UnknownCleanup == /\ owner = "picker" /\ stage \in {"stopP","stopW","cleanup"}
                  /\ hold' = TRUE /\ owner' = "blocked" /\ stage' = "hold"
                  /\ UNCHANGED <<previous,models,desired,target,recovery,pendingLegacy,request,capture,deletedDuringCapture>>
ConfirmedCleanup == /\ hold /\ models' = {} /\ hold' = FALSE /\ recovery' = "none"
                    /\ owner' = "none" /\ stage' = "idle" /\ pendingLegacy' = FALSE
                    /\ UNCHANGED <<previous,desired,target,request,capture,deletedDuringCapture>>
CaptureChanges == /\ capture' = ~capture
                  /\ UNCHANGED <<previous,models,owner,stage,desired,target,recovery,pendingLegacy,request,hold,deletedDuringCapture>>
CaptureWins == /\ capture /\ owner = "picker" /\ stage \in {"stopW","load","recover"}
               /\ owner' = "none" /\ stage' = "idle"
               /\ UNCHANGED <<previous,models,desired,target,recovery,pendingLegacy,request,capture,hold,deletedDuringCapture>>
LegacyStart == /\ owner = "none" /\ ~capture /\ ~request /\ ~hold /\ ~pendingLegacy /\ desired = "W" /\ recovery # "P"
               /\ pendingLegacy' = TRUE /\ owner' = IF BrokenLegacy THEN "none" ELSE "legacy"
               /\ UNCHANGED <<previous,models,stage,desired,target,recovery,request,capture,hold,deletedDuringCapture>>
LegacyCompletes == /\ pendingLegacy /\ ~capture /\ ~hold
                   /\ models' = models \cup {"W"} /\ pendingLegacy' = FALSE
                   /\ owner' = IF owner = "legacy" THEN "none" ELSE owner
                   /\ UNCHANGED <<previous,stage,desired,target,recovery,request,capture,hold,deletedDuringCapture>>
RequestStart == /\ owner = "none" /\ ~request /\ ~capture /\ ~hold
                /\ request' = TRUE
                /\ models' = IF recovery # "none" /\ ~BrokenRecovery THEN {recovery} ELSE models \cup {desired}
                /\ UNCHANGED <<previous,owner,stage,desired,target,recovery,pendingLegacy,capture,hold,deletedDuringCapture>>
RequestCompletes == /\ request /\ request' = FALSE
                    /\ UNCHANGED <<previous,models,owner,stage,desired,target,recovery,pendingLegacy,capture,hold,deletedDuringCapture>>
ResidencyNext == (\E t \in {"P","W"}: BeginPicker(t)) \/ StopP \/ StopW \/ Load \/ StartupFails \/
        RecoveryCleanup \/ RecoverPrevious \/ UnknownCleanup \/ ConfirmedCleanup \/ CaptureChanges \/
        CaptureWins \/ LegacyStart \/ LegacyCompletes \/ RequestStart \/ RequestCompletes
Next == ResidencyNext /\ UNCHANGED <<assetsPresent,attempted,deletedDuringCapture>>
Spec == Init /\ [][Next]_vars
OneModel == Cardinality(models) <= 1
UnknownBlocks == hold => (owner = "blocked" /\ ~request)

\* Gate-only projection: assets are local file metadata, not model residency.
\* attempted={} represents available=null, sleeping, no error/fallback. The old
\* UI blocked P in exactly this pristine state even when its files were present.
GateCanSelect(e) == e \in assetsPresent /\
                   (~BrokenAssetsGate \/ e = "W" \/ e \in attempted)
GateSelect == /\ GateCanSelect("P")
              /\ desired' = "P" /\ attempted' = attempted \cup {"P"}
              /\ UNCHANGED <<models,owner,stage,target,recovery,pendingLegacy,
                             request,capture,hold,previous,assetsPresent,deletedDuringCapture>>
GateSpec == Init /\ [][GateSelect]_vars
ProvisionedSelectable == "P" \in assetsPresent => GateCanSelect("P")
MissingAssetsBlocked == \A e \in {"W","P"}: e \notin assetsPresent => ~GateCanSelect(e)
GateDoesNotLoad == models = {}

\* Download-only projection. pendingLegacy is per-engine in-flight ownership;
\* capture is an admitted request waiting to enter the recognizer. BrokenLegacy
\* reproduces the old download's maintenance owner across transfer/hash/runtime.
DownloadBegin == /\ stage = "idle" /\ owner = "none" /\ ~request /\ ~capture
                 /\ pendingLegacy' = TRUE /\ stage' = "transfer"
                 /\ owner' = IF BrokenLegacy THEN "download" ELSE "none"
                 /\ UNCHANGED <<models,desired,target,recovery,request,capture,hold,previous,assetsPresent,attempted,deletedDuringCapture>>
DownloadAdvance == /\ stage \in {"transfer","verify"}
                   /\ stage' = IF stage = "transfer" THEN "verify" ELSE "runtime"
                   /\ UNCHANGED <<models,owner,desired,target,recovery,pendingLegacy,request,capture,hold,previous,assetsPresent,attempted,deletedDuringCapture>>
DownloadAdmit == /\ pendingLegacy /\ ~capture /\ ~request
                 /\ capture' = TRUE
                 /\ UNCHANGED <<models,owner,stage,desired,target,recovery,pendingLegacy,request,hold,previous,assetsPresent,attempted,deletedDuringCapture>>
DownloadRequestStart == /\ capture /\ owner = "none" /\ ~request
                        /\ request' = TRUE /\ capture' = FALSE
                        /\ UNCHANGED <<models,owner,stage,desired,target,recovery,pendingLegacy,hold,previous,assetsPresent,attempted,deletedDuringCapture>>
DownloadPublish == /\ stage = "runtime"
                   /\ owner \in {"none","download"}
                   /\ stage' = "idle" /\ owner' = "none" /\ pendingLegacy' = FALSE
                   /\ UNCHANGED <<models,desired,target,recovery,request,capture,hold,previous,assetsPresent,attempted,deletedDuringCapture>>
\* Atomic publication changes no resident model and remains enabled while busy.
DownloadNext == DownloadBegin \/ DownloadAdvance \/ DownloadAdmit \/ DownloadRequestStart \/
                (RequestCompletes /\ UNCHANGED <<assetsPresent,attempted,deletedDuringCapture>>) \/ DownloadPublish
DownloadSpec == Init /\ [][DownloadNext]_vars
DownloadNeverBlocksAdmittedRequest == pendingLegacy /\ capture => ENABLED DownloadRequestStart
VerifiedDownloadAlwaysPublishable == stage = "runtime" => ENABLED DownloadPublish

\* Delete holds the same transition ownership as selection until cleanup and
\* unlink complete. BrokenLegacy reproduces the old recognizer-loaded refusal.
DeleteInit == /\ models = {"P"} /\ owner = "none" /\ stage = "idle"
              /\ desired = "P" /\ target = "P" /\ previous = "W" /\ recovery = "none"
              /\ pendingLegacy = FALSE /\ request = FALSE /\ capture = FALSE /\ hold = FALSE
              /\ assetsPresent = {"P","W"} /\ attempted = {} /\ deletedDuringCapture = FALSE
OtherEngine == IF target = "P" THEN "W" ELSE "P"
DeleteBegin == /\ owner = "none" /\ ~request /\ ~capture /\ ~hold
               /\ target \in assetsPresent /\ OtherEngine \in assetsPresent
               /\ (~BrokenLegacy \/ target \notin models)
               /\ owner' = "delete" /\ stage' = "unload"
               /\ UNCHANGED <<models,desired,target,previous,recovery,pendingLegacy,
                              request,capture,hold,assetsPresent,attempted,deletedDuringCapture>>
DeleteStop == /\ owner = "delete" /\ stage = "unload"
              /\ models' = models \ {target} /\ stage' = "unlink"
              /\ UNCHANGED <<owner,desired,target,previous,recovery,pendingLegacy,
                             request,capture,hold,assetsPresent,attempted,deletedDuringCapture>>
DeleteFiles == /\ owner = "delete" /\ stage = "unlink" /\ ~capture /\ ~hold
               /\ target \notin models
               /\ assetsPresent' = assetsPresent \ {target} /\ desired' = OtherEngine
               /\ deletedDuringCapture' = (deletedDuringCapture \/ capture)
               /\ recovery' = "none" /\ owner' = "none" /\ stage' = "idle"
               /\ UNCHANGED <<models,target,previous,pendingLegacy,request,capture,hold,attempted>>
DeleteCaptureWins == /\ owner = "delete" /\ capture
                     /\ owner' = "none" /\ stage' = "idle"
                     /\ UNCHANGED <<models,desired,target,previous,recovery,pendingLegacy,
                                    request,capture,hold,assetsPresent,attempted,deletedDuringCapture>>
DeleteUnknown == /\ owner = "delete" /\ stage = "unload"
                 /\ hold' = TRUE /\ owner' = "blocked" /\ stage' = "hold"
                 /\ UNCHANGED <<models,desired,target,previous,recovery,pendingLegacy,
                                request,capture,assetsPresent,attempted,deletedDuringCapture>>
DeleteNext == DeleteBegin \/ DeleteStop \/ DeleteFiles \/ DeleteCaptureWins \/ DeleteUnknown \/
              ((RequestStart \/ RequestCompletes \/ CaptureChanges \/ ConfirmedCleanup)
               /\ UNCHANGED <<assetsPresent,attempted,deletedDuringCapture>>)
DeleteSpec == DeleteInit /\ [][DeleteNext]_vars
IdleLoadedCanDelete == (owner = "none" /\ ~request /\ ~capture /\ ~hold /\
                        target \in assetsPresent /\ OtherEngine \in assetsPresent)
                       => ENABLED DeleteBegin
DeletedModelNotResident == models \subseteq assetsPresent
DeleteExcludesRequest == owner = "delete" => ~request

\* QA-04 uses the same admission guard as the complete residency spec.
ReselectNext == (BeginPicker(desired) \/ StopP \/ StopW \/ Load \/
                CaptureChanges \/ RequestStart \/ RequestCompletes)
                /\ UNCHANGED <<assetsPresent,attempted,deletedDuringCapture>>
ReselectSpec == DeleteInit /\ [][ReselectNext]_vars
ReadyDuplicateKeepsLoaded == models = {desired}
ReadySelectionIsNoop == [][(owner = "none" /\ models = {desired}) =>
                           ~(owner' = "picker" /\ target' = desired)]_vars
NoDeleteDuringCapture == ~deletedDuringCapture
=============================================================================
