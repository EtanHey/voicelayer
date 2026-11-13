--------------------------- MODULE UIModeSwitch ---------------------------
\* Pre-implementation contract. No product-source conformance is claimed.
EXTENDS Naturals
CONSTANT Variant
VARIABLES mode, pref, swiftUI, runeChild, app, launchMode, runeCrashSeen
vars == <<mode, pref, swiftUI, runeChild, app, launchMode, runeCrashSeen>>

Init == /\ mode = "unset" /\ pref \in {"rune", "swift"}
        /\ swiftUI = "none" /\ runeChild = "none" /\ app = "down"
        /\ launchMode = "unset" /\ runeCrashSeen = FALSE

\* Launch and Relaunch are the same transition from down. The launch snapshot
\* is a ghost witness: comparing it with mode catches any mid-launch change.
Launch == /\ app = "down" /\ runeChild = "none"
          /\ app' = "launching" /\ mode' = pref /\ launchMode' = pref
          /\ UNCHANGED <<pref, swiftUI, runeChild, runeCrashSeen>>
Relaunch == Launch
Active == app \in {"launching", "running"}

CreateSwiftUI ==
    /\ Active /\ swiftUI = "none"
    /\ (mode = "swift" \/ Variant = "SwiftAlwaysCreated")
    /\ swiftUI' = "live"
    /\ UNCHANGED <<mode, pref, runeChild, app, launchMode, runeCrashSeen>>

StartRuneChild ==
    /\ Active /\ mode = "rune" /\ runeChild = "none"
    /\ runeChild' = "starting"
    /\ UNCHANGED <<mode, pref, swiftUI, app, launchMode, runeCrashSeen>>

RuneChildReady ==
    /\ Active /\ runeChild = "starting" /\ runeChild' = "live"
    /\ UNCHANGED <<mode, pref, swiftUI, app, launchMode, runeCrashSeen>>

FinishLaunch ==
    /\ app = "launching"
    /\ ((mode = "swift" /\ swiftUI = "live") \/
        (mode = "rune" /\ runeChild = "live"))
    /\ app' = "running"
    /\ UNCHANGED <<mode, pref, swiftUI, runeChild, launchMode, runeCrashSeen>>

\* Unexpected exit 0 and a crash both require supervision (no disable flag).
RuneChildCrash ==
    /\ Active /\ runeChild = "live" /\ runeChild' = "crashed"
    /\ runeCrashSeen' = TRUE
    /\ swiftUI' = IF Variant = "LazySwiftFallback" THEN "live" ELSE swiftUI
    /\ UNCHANGED <<mode, pref, app, launchMode>>
RuneChildCleanExit == RuneChildCrash

\* The fallback mutant replaces recovery with drawing: no restart is pending.
RestartRuneChild ==
    /\ Active /\ mode = "rune" /\ runeChild = "crashed"
    /\ Variant # "LazySwiftFallback"
    /\ runeChild' = "starting"
    /\ UNCHANGED <<mode, pref, swiftUI, app, launchMode, runeCrashSeen>>

ChangePreference ==
    /\ pref' = IF pref = "rune" THEN "swift" ELSE "rune"
    /\ mode' = IF Variant = "HotSwitch" /\ app = "running" THEN pref' ELSE mode
    /\ UNCHANGED <<swiftUI, runeChild, app, launchMode, runeCrashSeen>>

\* Quitting closes admission first. A queued ready/restart cannot run after it.
Quit == /\ Active /\ app' = "quitting"
        /\ UNCHANGED <<mode, pref, swiftUI, runeChild, launchMode, runeCrashSeen>>
StopRuneChild ==
    /\ app = "quitting" /\ runeChild # "none"
    /\ Variant # "NoStopOnQuit" /\ runeChild' = "none"
    /\ UNCHANGED <<mode, pref, swiftUI, app, launchMode, runeCrashSeen>>
FinishQuit ==
    /\ app = "quitting"
    /\ (runeChild = "none" \/ Variant = "NoStopOnQuit")
    /\ app' = "down" /\ mode' = "unset" /\ launchMode' = "unset"
    /\ swiftUI' = "none" /\ runeCrashSeen' = FALSE
    /\ UNCHANGED <<pref, runeChild>>

Next == Launch \/ CreateSwiftUI \/ StartRuneChild \/ RuneChildReady
        \/ FinishLaunch \/ RuneChildCrash \/ RuneChildCleanExit
        \/ RestartRuneChild \/ ChangePreference \/ Quit \/ StopRuneChild \/ FinishQuit
Spec == Init /\ [][Next]_vars
        /\ WF_vars(RestartRuneChild) /\ WF_vars(RuneChildReady)
        /\ WF_vars(StopRuneChild) /\ WF_vars(FinishQuit)

\* Five safety acceptance properties; the snapshot and crash bit are ghosts.
NeverBoth == ~(swiftUI = "live" /\ runeChild \in {"starting", "live"})
InactiveNeverExists == /\ (mode = "rune" => swiftUI = "none")
                       /\ (mode = "swift" => runeChild = "none")
ModeSetOnce == app = "down" \/ mode = launchMode
NoOrphanChild == app = "down" => runeChild = "none"
NoFallbackDrawing == (mode = "rune" /\ runeCrashSeen) => swiftUI = "none"
CrashRecovers == (mode = "rune" /\ runeChild = "crashed") ~>
                (runeChild = "live" \/ app = "down")
=============================================================================
