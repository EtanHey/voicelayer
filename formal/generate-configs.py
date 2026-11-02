"""Author the explicit model configs and exact-property mutant manifests."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def generate(name, module, base, current, invariants, temporal, historical, mutants, witnesses=(), positives=()):
    if len(sys.argv) > 1 and name not in sys.argv[1:]:
        return
    directory = ROOT / name
    old = json.loads((directory / "checks.json").read_text())
    checks = {}
    def config(label, changes, inv=(), props=(), role="positive", target=None):
        constants = {**base, **changes}
        text = "SPECIFICATION Spec\nCONSTANTS\n" + "\n".join(f'  {key} = {json.dumps(value)}' for key, value in constants.items())
        text += "\nCHECK_DEADLOCK FALSE\n"
        if inv: text += "INVARIANTS " + " ".join(inv) + "\n"
        if props: text += "PROPERTIES " + " ".join(props) + "\n"
        (directory / (label + ".cfg")).write_text(text)
        checks[label] = dict(role=role, target=target, kind="temporal" if props and target else "invariant" if target else "pass")
    config("Current", current, invariants["current"], temporal["current"])
    config("Fixed", {}, invariants["fixed"], temporal["fixed"])
    for label, changes, inv, props in positives:
        config(label, changes, inv, props)
    for label, target, changes in historical:
        config(label, {**current, **changes}, [target], role="historical", target=target)
    for label, target, fault, changes in mutants:
        is_temporal = target in temporal["fixed"]
        config(label, {"Fault": fault, **changes}, [] if is_temporal else [target], [target] if is_temporal else [], role="mutant", target=target)
    for row in witnesses:
        label, target, *changes = row
        config(label, changes[0] if changes else {}, [target], role="witness", target=target)
    for file in directory.glob("*.cfg"):
        if file.stem not in checks: file.unlink()
    acceptance = set(invariants["fixed"]) | set(temporal["fixed"])
    covered = {row["target"] for row in checks.values() if row["role"] == "mutant"}
    assert acceptance <= covered, acceptance - covered
    old.update(module=module, checks=checks, acceptance=sorted(acceptance))
    (directory / "checks.json").write_text(json.dumps(old, indent=2) + "\n")

ni = ["TypeOK", "VisibleHasShell", "N1CompactNote", "N2NoProcessingBand", "N3GrowsDown", "N4NoSubstitute", "N5InlineHistory", "NoteHasCause"]
generate("notch-presentation", "NotchPresentation", dict(Variant="fixed", Fault="none"), dict(Variant="current"),
         dict(current=["TypeOK", "VisibleHasShell"], fixed=ni), dict(current=["NoteNeverStuck"], fixed=["NoteNeverStuck"]),
         [("OldWing","N1CompactNote",{}),("OldProcessingNote","N2NoProcessingBand",{}),
          ("OldSubstitute","N4NoSubstitute",{}),("OldBusyHistory","N5InlineHistory",{}),("OldQuitCause","NoteHasCause",{})],
         [("MutType","TypeOK","type",{}),("MutNoShell","VisibleHasShell","no-shell",{}),
          ("MutWideWing","N1CompactNote","wide-wing",{}),("MutCoreWing","N1CompactNote","core-wing",{}),("MutTextWing","N1CompactNote","text-wing",{}),
          ("MutProcessingNote","N2NoProcessingBand","processing-note",{}),("MutTruncate","N3GrowsDown","truncate",{}),("MutOutsideBand","N3GrowsDown","outside-band",{}),
          ("MutErrorSubstitute","N4NoSubstitute","error-substitute",{}),("MutDetailsSubstitute","N4NoSubstitute","details-substitute",{}),
          ("MutBusyHistory","N5InlineHistory","busy-history",{}),("MutErrorHistory","N5InlineHistory","error-history",{}),
          ("MutStaleNote","NoteHasCause","stale-note",{}),("MutNeverExpire","NoteNeverStuck","never-expire",{}),
          ("MutantNoShell","VisibleHasShell","no-collapsed-shell",{}),
          ("MutantType","TypeOK","timer-range",{}),
          ("MutantStuck","NoteNeverStuck","timer-reset",{})])

ri = ["TypeOK","OneMic","OneDecoder","NoDuplicatePaste","NoCancelledPaste","N7CooldownRing","D3EveryTakeKept",
      "N6Admissible","N6StartsB","N6PreservesA","N7ScopedCancel","N7GuardedClick","N7Identity","N8ImmediatePaste","N8FinalNotSuperseded","NoTimeoutWhileTalking","N8DecodeAdmissible","SpeechRenewsDeadline","NoEarlySilenceTimeout","RecurringSpeechNeverTimesOut","EscapeTargetsNewest"]
rt = ["ProcessingSettles","OverlapPastes","EventuallyIdle","SilenceTimesOut","NoStaleGuard"]
generate("record-while-processing", "RecordWhileProcessing",
         dict(Admission="fixed",CancelPolicy="scoped",PastePolicy="immediate",RetentionPolicy="keep",Ingress="both",Fault="none",SilenceLimit=2,ObservationLimit=20,Scenario="pipeline"),
         dict(Admission="current",CancelPolicy="global",PastePolicy="current"),
         dict(current=["TypeOK","OneMic","OneDecoder","NoDuplicatePaste","N7CooldownRing","D3EveryTakeKept"],fixed=ri),
         dict(current=["ProcessingSettles"],fixed=rt),
         [("OldSocketBusy","N6StartsB",dict(Ingress="socket")),("OldF5CancelsA","N6PreservesA",{}),
          ("OldUnguardedCancel","N7GuardedClick",{}),("OldDisplayFloor","N8ImmediatePaste",{}),
          ("OldDeferredFinalDrop","N8FinalNotSuperseded",dict(Ingress="socket")),("OldSpeechTimeout","NoTimeoutWhileTalking",{})],
         [("MutType","TypeOK","type",{}),("MutTwoMics","OneMic","two-mics",{}),
          ("MutTwoDecoders","OneDecoder","two-decoders",{}),("MutDuplicatePaste","NoDuplicatePaste","duplicate",{}),
          ("MutPasteAfterCancel","NoCancelledPaste","paste-after-cancel",{}),("MutRing","N7CooldownRing","ring",{}),
          ("MutDropTimeout","D3EveryTakeKept","drop-timeout",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),("MutStallRecord","N6Admissible","stall-record",{}),
          ("MutRejectRecord","N6StartsB","reject-record",{}),("MutDisableRecordStart","N6StartsB","stall-record",{}),
          ("MutRecordCancels","N6PreservesA","record-cancels",{}),("MutDisableRecordPreserve","N6PreservesA","stall-record",{}),
          ("MutWrongVictim","N7ScopedCancel","wrong-victim",{}),("MutUnscopedSignal","N7ScopedCancel","unscoped-signal",{}),("MutDisableCancelB","N7ScopedCancel","stall-cancel",{}),
          ("MutUnguardedClick","N7GuardedClick","unguarded",{}),("MutDisableCancelBGuard","N7GuardedClick","stall-cancel",{}),("MutDisableClick","N7GuardedClick","stall-click",{}),
          ("MutIgnoreIdentity","N7Identity","ignore-id",{}),("MutHoldResult","N8ImmediatePaste","hold-result",{}),("MutResultStopsB","N8ImmediatePaste","result-stops-mic",{}),
          ("MutDelayedPaste","N8ImmediatePaste","none",dict(PastePolicy="current")),
          ("MutSupersede","N8FinalNotSuperseded","supersede",dict(PastePolicy="current")),
          ("MutSpeechTimeout","NoTimeoutWhileTalking","timeout-speaking",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),
          ("MutUnfairProcessing","ProcessingSettles","unfair",{}),("MutNoOverlapProgress","OverlapPastes","hold-result",{}),
          ("MutNoIdle","EventuallyIdle","unfair",{}),
          ("MutHeldDecode","N8DecodeAdmissible","hold-decode",{}),
          ("MutHeldDecodeImmediate","N8ImmediatePaste","hold-decode",{}),
          ("MutHeldDecodeOverlap","OverlapPastes","hold-decode",{}),
          ("MutNoDecodeFairness","EventuallyIdle","unfair-decode",{}),
          ("MutSpeechNoRenew","SpeechRenewsDeadline","no-renew",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),
          ("MutSpeechDisabled","SpeechRenewsDeadline","no-speech",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),
          ("MutEarlyTimeout","NoEarlySilenceTimeout","early-timeout",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),
          ("MutTimeoutNeverFires","SilenceTimesOut","no-timeout",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),
          ("MutReintroducedCap","RecurringSpeechNeverTimesOut","reintroduced-cap",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20)),
          ("MutEscapeMic","EscapeTargetsNewest","escape-mic",{}),
          ("MutEscapeOlder","EscapeTargetsNewest","escape-older",{}),
          ("MutStaleGuard","NoStaleGuard","stale-guard",{}),
          ("ConcurrentGlobalCancel","N7ScopedCancel","unscoped-signal",{}),
          ("DropCancelledMutant","D3EveryTakeKept","none",dict(RetentionPolicy="dropCancel"))],
         [("WitnessOverlapPaste","NoOverlapPaste"),("WitnessScopedCancel","NoScopedCancelDuringDecode"),("WitnessDecodeOverlap","NoDecodeDuringRecording"),("WitnessSpeechSilenceTimeout","NoSpeechSilenceTimeout",dict(Scenario="clock",SilenceLimit=10)),("WitnessSpeechPastFormerCap","NoSpeakingPastFormerCap",dict(Scenario="clock",SilenceLimit=10))],
         [("ProductClock",dict(Scenario="clock",SilenceLimit=10,ObservationLimit=20),
           ["TypeOK","D3EveryTakeKept","NoTimeoutWhileTalking","NoEarlySilenceTimeout","SpeechRenewsDeadline","RecurringSpeechNeverTimesOut"],
           ["SilenceTimesOut"]),
          ("N8Fixed",dict(Admission="current",CancelPolicy="current"),
           ["TypeOK","OneMic","OneDecoder","NoDuplicatePaste","NoCancelledPaste","N7CooldownRing","D3EveryTakeKept","N8ImmediatePaste","N8FinalNotSuperseded"],
           ["ProcessingSettles"])])
