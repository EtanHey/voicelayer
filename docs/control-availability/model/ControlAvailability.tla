----------------------- MODULE ControlAvailability -----------------------
\* A bounded one-dispatch contract: arbitrary factored snapshots, then one
\* handler call. This is availability/refinement, NOT whole-app liveness.
\* Derived from 4bf20052; L4f refines Seek to the current source refusal while paused.
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
VARIABLES s, prior, last, outcome, feedback, dispatched
vars == <<s, prior, last, outcome, feedback, dispatched>>

Phases == {"none", "opening", "open", "paused", "draining", "transcribing"}
Playback == {"none", "playing", "paused", "previous", "readback", "preparing"}
Tabs == {"TabGeneral", "TabTranscription", "TabDictionary", "TabSpeech", "TabHistory"}
Archives == {"ArchiveDrawer", "ArchiveWindow", "ArchiveLatest"}
Microphones == {"MicDefault", "MicReorder", "MicMove", "MicVisibleFirst"}
RecognizerMutations == {"SelectRecognizer", "LoadRecognizer", "UnloadRecognizer"}
Clones == {"CloneStart", "CloneRestart", "CloneStop"}
MediaButtons == {"ReadClipboard", "PreviewShort", "PreviewLong", "HistoryPlay"}
Transports == {"PausePlayback", "ResumePlayback", "Previous", "NextRead", "Replay", "Seek"}
Emergency == {"Stop", "Cancel", "F5Release"}
Presentation == Tabs \cup {"Hide", "Show", "OpenHistory", "OpenSettings", "CloseDrawer"}
Controls == Archives \cup Microphones \cup RecognizerMutations \cup Clones \cup
  MediaButtons \cup Transports \cup Emergency \cup Presentation \cup
  {"RestartListener", "Update", "CheckUpdates", "ReadSelectionKey", "RecordF5",
   "HistoryCopy", "HistoryNavigate", "CancelDownload", "DownloadRecognizer",
   "RequestDelete", "ConfirmDelete", "Quit"}

Capturing(x) == x.phase \in {"opening", "open", "paused"}
Unfinished(x) == x.phase # "none" \/ x.older \/ x.queued \/ x.historyBusy
Speech(x) == x.playback \in {"playing", "paused", "previous", "preparing"}
Mode(x) == IF x.reported # "derived" THEN x.reported
  ELSE IF ~x.connected THEN "disconnected"
  ELSE IF Capturing(x) THEN "recording"
  ELSE IF Unfinished(x) THEN "transcribing"
  ELSE IF Speech(x) THEN "speaking" ELSE "idle"
Capture(x) == <<x.phase, x.older, x.queued, x.agentAsk, x.historyBusy>>
DrawerAllowed(x) == ~x.hidden /\ ~x.modal /\ ~x.agentAsk /\ ~Speech(x)

Base == [connected |-> TRUE, gate |-> "open", phase |-> "none", older |-> FALSE,
  queued |-> FALSE, capable |-> TRUE, agentAsk |-> FALSE, historyBusy |-> FALSE, playback |-> "none",
  hidden |-> FALSE, drawer |-> "settings", tab |-> "TabGeneral", modal |-> FALSE,
  transition |-> FALSE, choice |-> "other", assets |-> TRUE, resident |-> TRUE,
  downloading |-> FALSE, clone |-> "running", foreign |-> FALSE, pending |-> FALSE,
  previous |-> FALSE, next |-> FALSE, audio |-> TRUE, micEligible |-> TRUE,
  micRevision |-> 0, gesture |-> FALSE, reported |-> "derived"]

\* Exhaustive within each factor below; NOT the Cartesian product of all axes.
CoreSeeds == {[Base EXCEPT !.connected = cn, !.gate = g, !.phase = p,
  !.older = o, !.agentAsk = a, !.playback = b] :
  cn \in BOOLEAN, g \in {"open", "closed"}, p \in Phases,
  o \in BOOLEAN, a \in BOOLEAN, b \in Playback}
PresentationSeeds == {[Base EXCEPT !.phase = p, !.older = o, !.agentAsk = a,
  !.hidden = h, !.modal = m, !.drawer = d, !.playback = b] :
  p \in Phases, o \in BOOLEAN, a \in BOOLEAN, h \in BOOLEAN,
  m \in BOOLEAN, d \in {"none", "history", "settings"}, b \in {"none", "paused", "playing"}}
RecognizerSeeds == {[Base EXCEPT !.phase = p, !.older = o, !.transition = t,
  !.choice = c, !.assets = a, !.resident = r, !.connected = cn, !.gate = g] :
  p \in Phases, o \in BOOLEAN, t \in BOOLEAN, c \in {"same", "other", "retry"},
  a \in BOOLEAN, r \in BOOLEAN, cn \in BOOLEAN, g \in {"open", "closed"}}
CloneSeeds == {[Base EXCEPT !.phase = p, !.playback = b, !.clone = l,
  !.foreign = f, !.pending = n] : p \in Phases, b \in Playback,
  l \in {"stopped", "running", "transition"}, f \in BOOLEAN, n \in BOOLEAN}
OverlaySeeds ==
  {[Base EXCEPT !.historyBusy = TRUE, !.connected = cn, !.gate = g, !.phase = p, !.older = o] :
     cn \in BOOLEAN, g \in {"open", "closed"}, p \in Phases, o \in BOOLEAN} \cup
  {[Base EXCEPT !.phase = p, !.queued = q, !.capable = c, !.older = TRUE] :
     p \in Phases, q \in BOOLEAN, c \in BOOLEAN} \cup
  {[Base EXCEPT !.phase = p, !.micEligible = e, !.downloading = d] :
     p \in Phases, e \in BOOLEAN, d \in BOOLEAN} \cup
  {[Base EXCEPT !.playback = b, !.previous = p, !.next = n] :
     b \in Playback, p \in BOOLEAN, n \in BOOLEAN} \cup
  {[Base EXCEPT !.reported = r, !.gesture = g, !.pending = n, !.audio = a] :
     r \in {"derived", "error", "disconnected"}, g \in BOOLEAN, n \in BOOLEAN, a \in BOOLEAN}
Seeds == CoreSeeds \cup PresentationSeeds \cup RecognizerSeeds \cup CloneSeeds \cup OverlaySeeds

Fixture == CASE Scenario = "archive-drawer" -> [Base EXCEPT !.phase = "transcribing", !.drawer = "history"]
  [] Scenario = "archive-window" -> [Base EXCEPT !.playback = "playing"]
  [] Scenario = "archive-latest" -> [Base EXCEPT !.phase = "open"]
  [] Scenario = "gate" -> [Base EXCEPT !.gate = "closed"]
  [] Scenario = "selected" -> [Base EXCEPT !.choice = "same"]
  [] Scenario = "previous" -> [Base EXCEPT !.playback = "playing"]
  [] Scenario = "capture" -> [Base EXCEPT !.phase = "open"]
  [] Scenario = "playback-capture" -> [Base EXCEPT !.phase = "open", !.playback = "paused"]
  [] Scenario = "clone-start" -> [Base EXCEPT !.phase = "open", !.clone = "stopped"]
  [] Scenario = "hidden" -> [Base EXCEPT !.hidden = TRUE]
  [] Scenario = "overlap" -> [Base EXCEPT !.older = TRUE]
  [] Scenario = "drain" -> [Base EXCEPT !.phase = "draining", !.older = TRUE]
  [] OTHER -> Base

Visible(c,x) == CASE c = "ArchiveDrawer" -> x.audio /\ x.drawer = "history" /\ DrawerAllowed(x)
  [] c \in {"ArchiveWindow", "ArchiveLatest", "HistoryPlay"} -> x.audio /\ ~x.modal
  [] c \in Emergency -> Unfinished(x)
  [] c = "Hide" -> ~x.hidden /\ ~x.modal
  [] c = "Show" -> x.hidden
  [] c \in Tabs -> x.drawer = "settings" /\ DrawerAllowed(x)
  [] c = "CloseDrawer" -> x.drawer # "none" /\ ~x.hidden
  [] c \in {"OpenHistory", "OpenSettings"} -> DrawerAllowed(x)
  [] c = "CloneStart" -> x.clone = "stopped" /\ ~x.modal
  [] c \in {"CloneRestart", "CloneStop"} -> x.clone = "running" /\ ~x.modal
  [] c = "CancelDownload" -> x.downloading /\ ~x.modal
  [] c = "DownloadRecognizer" -> ~x.assets /\ ~x.modal
  [] c = "LoadRecognizer" -> x.assets /\ ~x.resident /\ ~x.modal
  [] c = "UnloadRecognizer" -> x.assets /\ x.resident /\ ~x.modal
  [] c = "RequestDelete" -> x.assets /\ ~x.modal
  [] c = "ConfirmDelete" -> x.assets /\ ~x.modal
  [] c \in Transports -> x.playback # "none" /\ ~x.hidden /\ ~x.modal
  [] c \in {"RecordF5", "ReadSelectionKey"} -> TRUE
  [] OTHER -> ~x.modal

\* UI policy: independent of the separately written handler/owner admission.
UIReason(c,x) == CASE c \in Emergency -> IF Unfinished(x) THEN "" ELSE "No unfinished take"
  [] c = "ReadSelectionKey" -> ""
  [] c \in {"CheckUpdates", "HistoryCopy", "HistoryNavigate", "RequestDelete"} -> ""
  [] c \in Presentation ->
    IF c = "Hide" /\ Unfinished(x) THEN "Finish or cancel this take before hiding VoiceBar"
    ELSE IF c \in Tabs /\ x.drawer # "settings" THEN "Open Settings first" ELSE ""
  [] c \in Microphones ->
    IF Capturing(x) THEN "Finish recording to change microphones"
    ELSE IF ~x.micEligible THEN "No microphone move is available" ELSE ""
  [] c = "RestartListener" ->
    IF Capturing(x) \/ x.gesture THEN "Finish recording or release F5 before restarting the listener" ELSE ""
  [] c = "Update" ->
    IF x.pending THEN "An update operation is in progress"
    ELSE IF Unfinished(x) \/ Mode(x) # "idle" \/ x.gesture THEN "Finish the active operation before updating"
    ELSE IF x.gate = "closed" THEN "An update owns VoiceBar" ELSE ""
  [] c = "Quit" -> IF x.gate = "closed" THEN "An update owns VoiceBar" ELSE ""
  [] c = "RecordF5" ->
    IF ~x.connected THEN "VoiceLayer is disconnected"
    ELSE IF x.hidden THEN "Show VoiceBar before recording"
    ELSE IF x.gate = "closed" THEN "An update owns VoiceBar"
    ELSE IF x.agentAsk THEN "An agent Ask owns the microphone"
    ELSE IF x.queued THEN "The next recording is already queued"
    ELSE IF Capturing(x) THEN "A recording owns the microphone"
    ELSE IF Unfinished(x) /\ ~x.capable THEN "This connection cannot queue another recording" ELSE ""
  [] c = "CancelDownload" -> IF x.downloading THEN "" ELSE "No download is active"
  [] c \in Clones ->
    IF Capturing(x) THEN "Finish recording to change the clone engine"
    ELSE IF x.pending THEN "Waiting for the clone engine"
    ELSE IF c # "CloneStart" /\ x.foreign THEN "Another process owns this engine"
    ELSE IF Speech(x) THEN "Finish playback before changing the clone engine" ELSE ""
  [] c \in Archives ->
    IF ~x.connected THEN "VoiceLayer is disconnected"
    ELSE IF x.gate = "closed" THEN "An update owns VoiceBar"
    ELSE IF Unfinished(x) THEN "Finish or cancel the current take and re-transcription first"
    ELSE IF Speech(x) \/ x.agentAsk THEN "Finish speech or Ask before re-transcribing"
    ELSE IF Mode(x) # "idle" THEN "Recover VoiceBar before re-transcribing" ELSE ""
  [] c \in RecognizerMutations \cup {"DownloadRecognizer", "ConfirmDelete"} ->
    IF ~x.connected THEN "VoiceLayer is disconnected"
    ELSE IF x.gate = "closed" THEN "An update owns VoiceBar"
    ELSE IF Unfinished(x) THEN "Finish the current take before changing recognizers"
    ELSE IF x.transition THEN "Wait for the recognizer transition"
    ELSE IF c = "SelectRecognizer" /\ x.choice = "same" THEN "Already selected and healthy"
    ELSE IF c = "SelectRecognizer" /\ ~x.assets THEN "Download this recognizer first"
    ELSE IF c = "ConfirmDelete" /\ (x.choice # "other" \/ x.resident) THEN "Choose another recognizer and unload this model first" ELSE ""
  [] c \in MediaButtons ->
    IF ~x.connected /\ c # "HistoryPlay" THEN "VoiceLayer is disconnected"
    ELSE IF x.gate = "closed" THEN "An update owns VoiceBar"
    ELSE IF Unfinished(x) \/ x.agentAsk THEN "Finish capture or transcription before reading"
    ELSE IF c # "ReadClipboard" /\ Speech(x) THEN "Finish the current playback first" ELSE ""
  [] c \in Transports ->
    IF c # "PausePlayback" /\ Unfinished(x) THEN "Finish capture or transcription before playback"
    ELSE IF ~x.connected THEN "VoiceLayer is disconnected"
    ELSE IF c # "PausePlayback" /\ x.gate = "closed" THEN "An update owns VoiceBar"
    ELSE IF c = "Previous" /\ ~x.previous THEN "No previous read in this queue"
    ELSE IF c = "NextRead" /\ ~x.next THEN "Nothing queued"
    ELSE IF c = "ResumePlayback" /\ x.playback # "paused" THEN "Playback is not paused"
    ELSE IF c = "PausePlayback" /\ x.playback \notin {"playing", "previous", "preparing", "paused"} THEN "No live playback to pause"
    ELSE IF c = "Seek" /\ x.playback = "preparing" THEN "Preparing audio; seeking is not ready"
    ELSE IF c = "Seek" /\ x.playback = "paused" THEN "Paused. Press Play to seek" ELSE ""
  [] OTHER -> "Unknown control"

FixedEnabled(c,x) == Visible(c,x) /\ UIReason(c,x) = ""
OldEnabled(c,x) == Visible(c,x) /\
  CASE c = "ArchiveDrawer" -> TRUE
    [] c = "ArchiveWindow" -> ~Unfinished(x)
    [] c = "ArchiveLatest" -> ~Unfinished(x)
    [] c \in {"RestartListener", "Update", "ReadClipboard", "Hide"} -> TRUE
    [] c \in Microphones -> x.micEligible
    [] c = "SelectRecognizer" -> x.connected /\ ~Unfinished(x) /\ ~x.transition /\ x.assets
    [] c \in Clones -> ~x.pending /\ (c = "CloneStart" \/ ~x.foreign)
    [] c \in {"PreviewShort", "PreviewLong", "HistoryPlay"} -> ~Unfinished(x) /\ ~Speech(x)
    [] c = "RecordF5" -> TRUE
    [] c = "Quit" -> TRUE
    [] OTHER -> FixedEnabled(c,x)
OldControl == CASE Policy = "OldArchiveDrawer" -> "ArchiveDrawer"
  [] Policy = "OldArchiveWindow" -> "ArchiveWindow"
  [] Policy = "OldArchiveLatest" -> "ArchiveLatest"
  [] Policy = "OldRestart" -> "RestartListener"
  [] Policy = "OldUpdate" -> "Update"
  [] Policy = "OldClipboard" -> "ReadClipboard"
  [] Policy = "OldSelected" -> "SelectRecognizer"
  [] Policy = "OldHide" -> "Hide"
  [] Policy = "OldMicrophone" -> "MicDefault"
  [] Policy = "OldMicReorder" -> "MicReorder"
  [] Policy = "OldMicMove" -> "MicMove"
  [] Policy = "OldMicVisibleFirst" -> "MicVisibleFirst"
  [] Policy = "OldClone" -> "CloneRestart"
  [] Policy = "OldCloneStart" -> "CloneStart"
  [] Policy = "OldCloneStop" -> "CloneStop"
  [] Policy = "OldPreview" -> "PreviewShort"
  [] Policy = "OldHistoryPlay" -> "HistoryPlay"
  [] Policy = "OldRecord" -> "RecordF5"
  [] Policy = "OldQuit" -> "Quit"
  [] OTHER -> "none"
Enabled(c,x) == IF c = OldControl THEN OldEnabled(c,x)
  ELSE IF Policy = "MutDisableOverlap" /\ c = "RecordF5" /\ x.older THEN FALSE
  ELSE IF Policy = "MutDisableEmergency" /\ c = "F5Release" THEN FALSE
  ELSE IF Policy = "MutDisableTabs" /\ c \in Tabs /\ Capturing(x) THEN FALSE
  ELSE IF Policy = "MutRecognizer" /\ c = "SelectRecognizer" THEN Visible(c,x)
  ELSE IF Policy = "MutPlayback" /\ c = "ResumePlayback" THEN Visible(c,x)
  ELSE FixedEnabled(c,x)
Reason(c,x) == IF (Policy = "OldPrevious" /\ c = "Previous") \/
    (Policy = "OldArchiveLatest" /\ c = "ArchiveLatest") \/ Policy = "MutNoReason" THEN ""
  ELSE IF Policy = "MutDisableOverlap" /\ c = "RecordF5" THEN "Wait for older transcription"
  ELSE IF Policy = "MutDisableEmergency" /\ c = "F5Release" THEN "Busy"
  ELSE IF Policy = "MutDisableTabs" /\ c \in Tabs THEN "Recording" ELSE UIReason(c,x)
ReasonChannels(c,x) == IF Policy = "MutNoCloneHover" /\ c \in Clones THEN {"label"}
  ELSE {"label", "tooltip", "accessibility"}

\* Handlers are deliberately NOT aliases for Enabled/UIReason. Local validation
\* and owner admission are separate conjuncts, as Swift and daemon are today.
LocalGuard(c,x) == CASE c \in Emergency -> Unfinished(x)
  [] c = "Hide" -> IF Policy = "OldHide" THEN TRUE ELSE ~Unfinished(x)
  [] c \in Microphones -> x.micEligible /\ (c = OldControl \/ ~Capturing(x))
  [] c = "RestartListener" -> ~Capturing(x) /\ ~x.gesture
  [] c = "Update" -> Mode(x) = "idle" /\ ~x.gesture /\ ~x.pending /\ ~Unfinished(x)
  [] c \in Archives -> c # "ArchiveDrawer" \/ Mode(x) = "idle"
  [] c = "RecordF5" -> ~x.hidden /\ ~x.agentAsk /\ ~Capturing(x) /\ ~x.queued /\ (x.capable \/ ~Unfinished(x))
  [] c = "ReadSelectionKey" -> TRUE
  [] c \in Tabs -> x.drawer = "settings" /\ DrawerAllowed(x)
  [] c \in {"OpenHistory", "OpenSettings"} -> DrawerAllowed(x)
  [] c = "CloseDrawer" -> x.drawer # "none"
  [] c = "Show" -> x.hidden
  [] c = "SelectRecognizer" /\ Policy = "MutRecognizer" -> TRUE
  [] c \in RecognizerMutations -> ~Unfinished(x) /\ ~x.transition /\ x.assets /\
       (c # "SelectRecognizer" \/ x.choice # "same")
  [] c = "DownloadRecognizer" -> ~Unfinished(x) /\ ~x.transition /\ ~x.assets
  [] c = "CancelDownload" -> x.downloading
  [] c = "ConfirmDelete" -> ~Unfinished(x) /\ ~x.transition /\ x.choice = "other" /\ ~x.resident
  [] c \in Clones -> ~x.pending /\ (c = OldControl \/ (~Capturing(x) /\ ~Speech(x))) /\
       (IF c = "CloneStart" THEN x.clone = "stopped" ELSE x.clone = "running" /\ ~x.foreign)
  [] c \in MediaButtons -> ~Unfinished(x) /\ ~x.agentAsk /\ (c = "ReadClipboard" \/ ~Speech(x))
  [] c \in Transports ->
       (c = "PausePlayback" \/ ~Unfinished(x) \/ Policy = "MutPlayback") /\
       (c # "Previous" \/ x.previous) /\ (c # "NextRead" \/ x.next) /\
       (c # "ResumePlayback" \/ x.playback = "paused") /\
       (c # "PausePlayback" \/ Speech(x)) /\ (c # "Seek" \/ x.playback \notin {"preparing", "paused"})
  [] OTHER -> TRUE
DaemonGuard(c,x) == CASE c \in Archives -> x.connected /\ x.gate = "open" /\
       ~Unfinished(x) /\ ~Speech(x) /\ ~x.agentAsk /\ Mode(x) = "idle"
  [] c \in RecognizerMutations \cup {"DownloadRecognizer", "ConfirmDelete", "RecordF5"} -> x.connected /\ x.gate = "open"
  [] c \in MediaButtons -> x.gate = "open" /\ (c = "HistoryPlay" \/ x.connected)
  [] c \in Transports -> x.connected /\ (c = "PausePlayback" \/ x.gate = "open")
  [] c \in {"Update", "Quit"} -> x.gate = "open"
  [] c = "ReadSelectionKey" /\ Policy = "OldSelectionGate" -> x.gate = "open"
  [] OTHER -> TRUE
Handler(c,x) == Visible(c,x) /\ LocalGuard(c,x) /\ DaemonGuard(c,x)
SelectionCanRead(x) == x.connected /\ x.gate = "open" /\ ~Unfinished(x) /\ ~x.agentAsk
SelectionReason(x) == IF ~x.connected THEN "VoiceLayer is disconnected"
  ELSE IF x.gate = "closed" THEN "An update owns VoiceBar" ELSE "Finish capture or transcription before reading"

Effect(c,x) == CASE c = "RecordF5" ->
    IF x.phase = "draining" THEN [x EXCEPT !.queued = Policy # "MutDropDrain"]
    ELSE [x EXCEPT !.phase = "opening", !.playback = IF Speech(x) THEN "paused" ELSE @,
      !.older = IF Policy = "MutCancelOlder" THEN FALSE ELSE @ \/ x.phase = "transcribing"]
  [] c \in {"Stop", "F5Release"} ->
    IF Capturing(x) THEN [x EXCEPT !.phase = "draining"] ELSE x
  [] c = "Cancel" ->
    IF x.queued THEN [x EXCEPT !.queued = FALSE]
    ELSE IF x.phase # "none" THEN [x EXCEPT !.phase = "none", !.historyBusy = FALSE]
    ELSE IF x.older THEN [x EXCEPT !.older = FALSE] ELSE [x EXCEPT !.historyBusy = FALSE]
  [] c = "Hide" -> IF Policy = "OldHide" THEN
       [x EXCEPT !.hidden = TRUE, !.phase = "none", !.older = FALSE, !.queued = FALSE, !.historyBusy = FALSE]
       ELSE [x EXCEPT !.hidden = TRUE, !.drawer = "none"]
  [] c = "Show" -> [x EXCEPT !.hidden = FALSE, !.drawer = "none"]
  [] c = "OpenHistory" -> [x EXCEPT !.drawer = "history"]
  [] c = "OpenSettings" -> [x EXCEPT !.drawer = "settings"]
  [] c = "CloseDrawer" -> [x EXCEPT !.drawer = "none"]
  [] c \in Tabs -> [x EXCEPT !.tab = c, !.phase = IF Policy = "MutDrawerCuts" THEN "none" ELSE @]
  [] c \in Microphones -> [x EXCEPT !.micRevision = 1]
  [] c \in Archives -> [x EXCEPT !.phase = "transcribing", !.historyBusy = TRUE]
  [] c \in RecognizerMutations -> [x EXCEPT !.transition = TRUE]
  [] c = "DownloadRecognizer" -> [x EXCEPT !.downloading = TRUE]
  [] c = "CancelDownload" -> [x EXCEPT !.downloading = FALSE]
  [] c = "ConfirmDelete" -> [x EXCEPT !.assets = FALSE]
  [] c \in Clones -> [x EXCEPT !.clone = IF c = "CloneStop" THEN "stopped" ELSE "transition"]
  [] c = "PausePlayback" -> [x EXCEPT !.playback = "paused"]
  [] c = "Previous" -> [x EXCEPT !.playback = "previous"]
  [] c \in {"ResumePlayback", "NextRead", "Replay"} \cup MediaButtons -> [x EXCEPT !.playback = "playing"]
  [] c = "ReadSelectionKey" /\ SelectionCanRead(x) -> [x EXCEPT !.playback = "playing"]
  [] c = "Update" -> [x EXCEPT !.pending = TRUE]
  [] OTHER -> x

Invoke(c) == /\ Enabled(c,s) /\ Handler(c,s)
  /\ prior' = s /\ s' = Effect(c,s) /\ last' = c /\ dispatched' = TRUE
  /\ outcome' = (IF c = "ReadSelectionKey" /\ ~SelectionCanRead(s) THEN "explained"
                ELSE IF c = "RequestDelete" THEN "explain-or-confirm" ELSE "accepted")
  /\ feedback' = (IF c = "ReadSelectionKey" /\ ~SelectionCanRead(s) THEN
                  IF Policy = "MutSilentKey" THEN "" ELSE SelectionReason(s) ELSE "")
Init == /\ s \in (IF Scenario = "all" THEN Seeds ELSE {Fixture})
  /\ prior = s /\ last = "Init" /\ outcome = "none" /\ feedback = "" /\ dispatched = FALSE
Next == ~dispatched /\ (\E c \in Controls: Invoke(c))
Spec == Init /\ [][Next]_vars

EnabledMeansAccepted == \A c \in Controls: Enabled(c,s) => Handler(c,s)
DisabledHasReason == \A c \in Controls: Visible(c,s) /\ ~Enabled(c,s) => Reason(c,s) # ""
StopAlwaysReachable == Unfinished(s) => \A c \in Emergency: Enabled(c,s) /\ Handler(c,s)
HideNeverCancelsATake == last = "Hide" => Capture(s) = Capture(prior)
PresentationNeverCutsCapture == last \in Presentation => Capture(s) = Capture(prior)
MicrophoneLockedDuringCapture == ~(last \in Microphones /\ Capturing(prior))
RecognizerMutationSafe == last \in RecognizerMutations => ~Unfinished(prior) /\ ~prior.transition
CloneCaptureProtected ==
  /\ ~(last \in Clones /\ Capturing(prior))
  /\ (\A c \in Clones: Visible(c,s) /\ ~Enabled(c,s) =>
       "tooltip" \in ReasonChannels(c,s) /\ "accessibility" \in ReasonChannels(c,s))
PlaybackNeverResumesOverCapture == ~(last \in {"ResumePlayback", "Previous", "NextRead", "Replay"} /\ Capturing(prior))
SelectionRefusalAccessible == last = "ReadSelectionKey" /\ ~SelectionCanRead(prior) =>
  outcome = "explained" /\ feedback # "" /\ s = prior
HistorySurfacesAgree == \A a,b \in Archives:
  Visible(a,s) /\ Visible(b,s) => Enabled(a,s) = Enabled(b,s)
LocalNavigationAvailable ==
  /\ (\A c \in Tabs: Visible(c,s) => Enabled(c,s) /\ Handler(c,s))
  /\ (\A c \in {"HistoryCopy", "HistoryNavigate", "CheckUpdates"}: Visible(c,s) => Enabled(c,s) /\ Handler(c,s))
RequiredOverlap(x) == x.connected /\ x.gate = "open" /\ ~x.hidden /\
  ~x.agentAsk /\ x.capable /\ ~x.queued /\ (x.older \/ x.phase = "transcribing") /\
  x.phase \in {"none", "transcribing"}
RecordingDuringOlderProcessing == RequiredOverlap(s) =>
  /\ Enabled("RecordF5",s) /\ Handler("RecordF5",s)
  /\ ENABLED Invoke("RecordF5")
  /\ ~ENABLED (Invoke("RecordF5") /\ (s'.phase # "opening" \/ ~s'.older))
DrainQueuesSuccessor == s.connected /\ s.gate = "open" /\ ~s.hidden /\
  ~s.agentAsk /\ s.capable /\ ~s.queued /\ s.phase = "draining" =>
  /\ ENABLED Invoke("RecordF5")
  /\ ~ENABLED (Invoke("RecordF5") /\ (~s'.queued \/ s'.phase # "draining"))
WitnessOverlap == ~(last = "RecordF5" /\ prior.older /\ s.older /\ s.phase = "opening")
WitnessDrawerDuringCapture == ~(last = "TabSpeech" /\ Capturing(prior) /\ Capture(s) = Capture(prior))
WitnessKeyRefusal == ~(last = "ReadSelectionKey" /\ outcome = "explained" /\ feedback # "")
=============================================================================
