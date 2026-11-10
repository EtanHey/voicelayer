#!/usr/bin/env python3
"""Regenerate the C5 source ledger, never an installed-app verdict."""
import collections
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
C5 = "40d704bc88cd7247597726e79015da3a472b1a01"
UI = "flow-bar/Sources/VoiceBarUI/"
APP = "flow-bar/Sources/VoiceBar/"


def generate():
    recon = json.loads((HERE / "recon-cells.json").read_text())
    sources = {}

    def source(path):
        if path not in sources:
            sources[path] = subprocess.check_output(["git", "show", f"{C5}:{path}"], cwd=ROOT).decode()
        return sources[path]

    def requires(path, *anchors):
        text = source(path)
        for anchor in anchors:
            assert anchor in text, (path, anchor)
        return path

    # Separate renderer, local handler and final-owner evidence. These are source
    # assertions, not UI execution. A changed policy requires a new source replay.
    owner = requires("src/socket-handlers.ts", 'case "retranscribe_recording":',
                     'isSpeaking || hasActiveVoiceOperation()', 'withFreshDeferredVoiceAdmission')
    local = requires(UI + "VoiceState.swift", 'guard historyRetranscriptionAvailability.isEnabled else { return }',
                     'nativeUpdateGate?.permitsNewVoice() == false', 'if mode != .idle',
                     'isHistoryRetranscriptionPending')
    renderers = {
        "H03": requires(UI + "NotchHistoryPanel.swift", '.disabled(action.kind == .retranscribe && !retranscriptionAvailability().isEnabled)',
                        '.accessibilityHint(action.kind == .retranscribe ? retranscriptionAvailability().reason'),
        "F23": requires(UI + "SettingsView.swift", 'return archiveAdmission.isEnabled',
                        'archiveAdmission.reason.map', 'archiveAdmission: historyRetranscriptionAvailability()'),
        "C01": requires(UI + "PillContextMenuController.swift", '.isEnabled = canRetranscribeLatestProvider()',
                        '.toolTip = retranscribeLatestDisabledReasonProvider()', '.setAccessibilityHelp(retranscribeLatestDisabledReasonProvider())'),
    }
    requires(APP + "VoiceBarApp.swift", 'retranscribeLatestDisabledReasonProvider =', 'voiceState.historyRetranscriptionAvailability.reason')
    requires(UI + "VoiceBarUpdates.swift", 'availableVersion != nil && phase != .updating && phase != .checking && launcher.isAvailable',
             'guard !isDictating() else')
    requires(UI + "RecognizerPickerView.swift", '.disabled(state.isSelectionDisabled || !state.assetsPresent(for: engine) || onSelect == nil)')
    for path in ["BarView.swift", "VoiceBarPresentation.swift", "SpeechSettingsView.swift", "SettingsAudioPlayback.swift",
                 "RecognizerPickerState.swift", "CloneEngineControl.swift", "CloneEngineSectionView.swift",
                 "DictionaryAddSheetView.swift", "NotchDrawerDismissal.swift", "NativeUpdateGate.swift"]:
        source(UI + path)
    for path in [APP + "HotkeyManager.swift", APP + "VoiceBarCommandRouter.swift", "src/update-gate-admission.ts"]:
        source(path)
    cells = []
    for family, projections in recon["families"].items():
        for state, old in projections.items():
            status = "UNKNOWN" if old == "?" else "NOT_REPLAYED"
            layers = None
            if old in ("X", "D"):
                status = "REMOVED" if family in renderers else "SURVIVING"
                # Physical intents need read-or-explain/source-route refinement;
                # Quit's terminate-versus-explain policy is an unresolved proposal.
                if family in {"K01", "K03", "K05", "K07", "C09"}:
                    status = "UNKNOWN_REFINEMENT"
                if family in renderers:
                    layers = {"renderedPredicate": renderers[family], "localHandler": local, "finalOwner": owner}
            # True PTT pause is present on C5. Historical Z=N is obsolete;
            # do not invent 165 passing paused-state cells from that fact.
            if state == "Z":
                status = "UNKNOWN_NEWLY_REACHABLE"
            cell = {"id": f"{family}:{state}", "historical": old, "c5": status}
            if layers:
                cell["sourceLayers"] = layers
            cells.append(cell)
    overlays = [
        ("drawer-lifecycle", "UNKNOWN", "N05-N14,TAB1-TAB5,H01-H04"),
        ("post-drag", "UNKNOWN", "H02,H04"),
        ("native-hit-routing", "UNKNOWN", "all-notch-controls"),
        ("hold-ack", "SURVIVING", "N04"),
        ("pause-ack", "SURVIVING", "PTT-pause"),
        ("neighbors", "SURVIVING", "N15,N17"),
        ("playback-generation", "UNKNOWN", "N16,N19,N23,N24"),
        ("timed-word-ax", "UNKNOWN", "N23,N24"),
        ("parked-read", "UNKNOWN", "N16-N18"),
        ("legacy-capture", "SURVIVING", "K01,K03,K07,N01"),
        ("queued-successor", "SURVIVING", "K01,K03,K07"),
        ("microphone-capture", "REMOVED", "G07-G10"),
        ("microphone-ax-endpoint", "SURVIVING", "G07-G10"),
        ("recognizer-selected-assets", "SURVIVING", "T01-T14"),
        ("download-reason", "UNKNOWN", "T01-T06"),
        ("delete-explain", "ACCEPTED_EXPLANATION", "T09-T13"),
        ("setting-pending", "UNKNOWN", "S07,S09-S14,T15-T18"),
        ("clone-foreign-pending-hover", "SURVIVING", "S01-S05"),
        ("dictionary-readonly-ax", "SURVIVING", "D09,D10"),
        ("dictionary-disconnected-ack", "UNKNOWN", "D17"),
        ("missing-history-data", "UNKNOWN", "F19-F24"),
        ("empty-transcript", "SURVIVING", "C01,C06,C07,C11,K06"),
        ("optional-callbacks", "NOT_REACHABLE", "G11,G12,G20,T21"),
        ("modal-ime-escape", "UNKNOWN", "K09,K10,D12-D17"),
    ]
    return {"sourceBaseline": C5, "reconBaseline": recon["baseline"], "proof": "SOURCE_ONLY",
            "native": "NOT_RUN", "counts": dict(collections.Counter(c["c5"] for c in cells)),
            "sourceHashes": {p: hashlib.sha256(t.encode()).hexdigest() for p, t in sorted(sources.items())},
            "cells": cells, "overlays": [{"id": "overlay:" + name, "c5": status, "families": families}
                                            for name, status, families in overlays]}


if __name__ == "__main__":
    result = generate()
    cells = result.pop("cells")
    print(json.dumps(result, indent=2)[:-2] + ',\n  "cells": [\n' +
          ",\n".join("    " + json.dumps(cell) for cell in cells) + '\n  ]\n}')
