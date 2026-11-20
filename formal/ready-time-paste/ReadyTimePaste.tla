-------------------------- MODULE ReadyTimePaste --------------------------
EXTENDS Integers
CONSTANTS OldPolicy, DoubleDelivery, AllowSecure,
          Recover, KickOnly, RecoverAnyApp, CacheByBundle, SilentDecline
Targets == {"editor", "system", "voicebar", "secure", "none"}
Valid(t) == t \in Targets \ {"secure", "none"}
\* The inputs inside the target app: the one that can relaunch with its accessibility tree off.
InApp(t) == t \in {"editor", "secure"}
VARIABLES phase, focus, startFocus, readyFocus, selected, count, delivered,
          chromium, axOn, accepts, gen, enabledGen, kicked, touchedNative, readyReadable, outcome
vars == <<phase, focus, startFocus, readyFocus, selected, count, delivered,
          chromium, axOn, accepts, gen, enabledGen, kicked, touchedNative, readyReadable, outcome>>
app == <<chromium, axOn, accepts, gen, enabledGen, kicked, touchedNative>>
\* Focus outside the target app (system UI, VoiceBar's own field) is always readable.
Readable(t) == ~InApp(t) \/ axOn
\* The implementation may ask: only a Chromium-family app (mutant: any app), and (mutant) not
\* when it remembers an earlier set for this bundle, whatever process the bundle runs as now.
MayAsk == Recover /\ (chromium \/ RecoverAnyApp) /\ ~(CacheByBundle /\ enabledGen # -1)
\* AXManualAccessibility turns the tree on only in a Chromium app that honours it within the bound.
AskedAxOn == chromium /\ accepts
Init == /\ phase = "idle" /\ focus \in Targets
        /\ startFocus = "none" /\ readyFocus = "none" /\ selected = "none"
        /\ count = 0 /\ delivered = "none"
        /\ chromium \in BOOLEAN /\ axOn \in BOOLEAN /\ accepts \in BOOLEAN /\ gen = 0
        \* An earlier take (or Option+F5) may already have turned this process's tree on.
        /\ enabledGen \in {-1, 0} /\ (enabledGen = 0 => (axOn /\ chromium /\ accepts))
        /\ kicked = FALSE /\ touchedNative = FALSE /\ readyReadable = FALSE /\ outcome = "pending"
Record == /\ phase = "idle" /\ phase' = "recording" /\ startFocus' = focus
          /\ UNCHANGED <<focus, readyFocus, selected, count, delivered, app, readyReadable, outcome>>
\* Cycles allow arbitrarily many focus moves before text is ready.
Move == /\ phase \in {"recording", "written"} /\ focus' \in Targets
        /\ UNCHANGED <<phase, startFocus, readyFocus, selected, count, delivered, app, readyReadable, outcome>>
\* The target app quits and relaunches (T3 Code's update button): a new process whose
\* Chromium tree is off again. Before the take, or while it records.
Relaunch == /\ phase \in {"idle", "recording"} /\ gen = 0 /\ gen' = 1
            /\ axOn' = IF chromium THEN FALSE ELSE axOn
            /\ UNCHANGED <<phase, focus, startFocus, readyFocus, selected, count, delivered,
                           chromium, accepts, enabledGen, kicked, touchedNative, readyReadable, outcome>>
\* F5 key-down: one asynchronous recovery for whatever is frontmost when it runs. It never
\* gates the take; the take keeps recording whether it runs early, late, or not before Ready.
Kick == /\ phase = "recording" /\ ~kicked /\ kicked' = TRUE
        /\ IF Recover /\ InApp(focus) /\ ~axOn /\ MayAsk
           THEN /\ axOn' = AskedAxOn /\ enabledGen' = gen
                /\ touchedNative' = (touchedNative \/ ~chromium)
           ELSE UNCHANGED <<axOn, enabledGen, touchedNative>>
        /\ UNCHANGED <<phase, focus, startFocus, readyFocus, selected, count, delivered,
                       chromium, accepts, gen, readyReadable, outcome>>
\* Ready-time capture. With no readable focus, recover once (not in the KickOnly mutant), then
\* capture again; still unreadable means no target, which Deliver turns into the visible refusal.
Ready == /\ phase = "recording" /\ phase' = "ready" /\ readyFocus' = focus
         /\ LET asks == ~Readable(focus) /\ ~KickOnly /\ MayAsk
                axAfter == IF asks THEN AskedAxOn ELSE axOn
                readable == ~InApp(focus) \/ axAfter
            IN /\ axOn' = axAfter
               /\ enabledGen' = IF asks THEN gen ELSE enabledGen
               /\ touchedNative' = (touchedNative \/ (asks /\ ~chromium))
               /\ readyReadable' = readable
               /\ selected' = IF OldPolicy THEN startFocus ELSE IF readable THEN focus ELSE "none"
         /\ UNCHANGED <<focus, startFocus, count, delivered, chromium, accepts, gen, kicked, outcome>>
Deliver == /\ phase = "ready" /\ phase' = "written"
           /\ LET eligible == (Valid(selected) \/ (AllowSecure /\ selected = "secure"))
                              /\ (~OldPolicy \/ selected = readyFocus)
              IN /\ count' = IF eligible THEN 1 ELSE 0
                 /\ delivered' = IF eligible THEN selected ELSE "none"
                 \* A refusal keeps the transcript in History and says so on the notch.
                 /\ outcome' = IF eligible THEN "delivered" ELSE IF SilentDecline THEN "silent" ELSE "visible"
           /\ UNCHANGED <<focus, startFocus, readyFocus, selected, app, readyReadable>>
Complete == /\ phase = "written" /\ phase' = "done"
            /\ count' = IF DoubleDelivery /\ count = 1 THEN 2 ELSE count
            /\ UNCHANGED <<focus, startFocus, readyFocus, selected, delivered, app, readyReadable, outcome>>
Next == Record \/ Move \/ Relaunch \/ Kick \/ Ready \/ Deliver \/ Complete
Spec == Init /\ [][Next]_vars
Settled == phase \in {"written", "done"}
DeliveredAtMostOnce == count <= 1
NeverIntoSecureField == delivered # "secure"
\* A readable ready-time input gets the transcript (an unreadable one is the next two properties' case).
DeliversToReadyTimeFocus == (Settled /\ Valid(readyFocus) /\ readyReadable)
                          => (count >= 1 /\ delivered = readyFocus)
\* T23: a take aimed at a relaunched Chromium app (tree off) that honours AXManualAccessibility
\* still gets its transcript, whether the app relaunched before the take or during it.
RelaunchedTargetRecovered == (Settled /\ Valid(readyFocus) /\ InApp(readyFocus) /\ chromium /\ accepts)
                           => (count >= 1 /\ delivered = readyFocus)
\* Whatever the app does, a take aimed at it is delivered there or visibly refused, never dropped silently.
DeliveredOrVisiblyDeclined == (Settled /\ InApp(readyFocus))
                            => (delivered = readyFocus \/ outcome = "visible")
\* AXManualAccessibility is only ever set on a Chromium-family app.
NativeNeverTouched == ~touchedNative
=============================================================================
