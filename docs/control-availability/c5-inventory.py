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
    # A cell is SURVIVING only while its own defect line is still in C5. Fixing that line makes this
    # generator fail, which forces a relabel; a family with no anchor cannot be labelled SURVIVING.
    defects = {
        "G04": requires(UI + "SettingsView.swift", '.disabled(fix == .checkF5 && shortcutCheckRunning)'),
        "G13": requires(UI + "SettingsView.swift", '.disabled(onReadClipboard == nil)'),
        "G17": requires(UI + "VoiceBarUpdates.swift", 'availableVersion != nil && phase != .updating && phase != .checking && launcher.isAvailable',
                        'guard !isDictating() else'),
        "T01": requires(UI + "RecognizerPickerView.swift", '.disabled(state.isSelectionDisabled || !state.assetsPresent(for: engine) || onSelect == nil)'),
        "N15": requires(UI + "BarView.swift", 'accessibilityHint: "Replay the read before this one in the queue"',
                        '.disabled(!state.previousReadAvailable)'),
        "S13": requires(UI + "SpeechSettingsView.swift", '.disabled(busy || !pending.isEmpty || onPreview == nil)'),
        "F22": requires(UI + "SettingsView.swift", 'if action == .play, isRecording || isTranscribing || isVoiceBusy {'),
        "N01": requires(APP + "VoiceBarCommandRouter.swift", 'guard canStartRecording else { return }'),
    }
    defects["S14"] = defects["S13"]
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
                # Physical intents need read-or-explain/source-route refinement;
                # Quit's terminate-versus-explain policy is an unresolved proposal.
                if family in {"K01", "K03", "K05", "K07", "C09"}:
                    status = "UNKNOWN_REFINEMENT"
                elif family in renderers:
                    status = "REMOVED"
                    layers = {"renderedPredicate": renderers[family], "localHandler": local, "finalOwner": owner}
                else:
                    assert family in defects, f"{family}: bad historical cell without a C5 source check"
                    status = "SURVIVING"
                    layers = {"defectAnchor": defects[family]}
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
        ("hold-ack", "SOURCE_UNCHECKED", "N04"),
        ("pause-ack", "SOURCE_UNCHECKED", "PTT-pause"),
        ("neighbors", "SURVIVING", "N15,N17"),
        ("playback-generation", "UNKNOWN", "N16,N19,N23,N24"),
        ("timed-word-ax", "UNKNOWN", "N23,N24"),
        ("parked-read", "UNKNOWN", "N16-N18"),
        ("legacy-capture", "SURVIVING", "K01,K03,K07,N01"),
        ("queued-successor", "SURVIVING", "K01,K03,K07"),
        ("microphone-capture", "SOURCE_UNCHECKED", "G07-G10"),
        ("microphone-ax-endpoint", "SOURCE_UNCHECKED", "G07-G10"),
        ("recognizer-selected-assets", "SURVIVING", "T01-T14"),
        ("download-reason", "UNKNOWN", "T01-T06"),
        ("delete-explain", "ACCEPTED_EXPLANATION", "T09-T13"),
        ("setting-pending", "UNKNOWN", "S07,S09-S14,T15-T18"),
        ("clone-foreign-pending-hover", "SOURCE_UNCHECKED", "S01-S05"),
        ("dictionary-readonly-ax", "SOURCE_UNCHECKED", "D09,D10"),
        ("dictionary-disconnected-ack", "UNKNOWN", "D17"),
        ("missing-history-data", "UNKNOWN", "F19-F24"),
        ("empty-transcript", "SOURCE_UNCHECKED", "C01,C06,C07,C11,K06"),
        ("optional-callbacks", "NOT_REACHABLE", "G11,G12,G20,T21"),
        ("modal-ime-escape", "UNKNOWN", "K09,K10,D12-D17"),
    ]
    # Overlay verdicts other than UNKNOWN/SOURCE_UNCHECKED cite the family anchors checked above.
    overlay_anchors = {"neighbors": defects["N15"], "recognizer-selected-assets": defects["T01"],
                       "legacy-capture": defects["N01"], "queued-successor": defects["N01"]}
    for name, status, _ in overlays:
        if status in ("SURVIVING", "REMOVED"):
            assert name in overlay_anchors, f"overlay {name}: {status} without a C5 source check"
    return {"sourceBaseline": C5, "reconBaseline": recon["baseline"], "proof": "SOURCE_ONLY",
            "native": "NOT_RUN", "counts": dict(collections.Counter(c["c5"] for c in cells)),
            "sourceHashes": {p: hashlib.sha256(t.encode()).hexdigest() for p, t in sorted(sources.items())},
            "cells": cells, "overlays": [dict({"id": "overlay:" + name, "c5": status, "families": families},
                                              **({"defectAnchor": overlay_anchors[name]} if name in overlay_anchors else {}))
                                         for name, status, families in overlays]}


if __name__ == "__main__":
    result = generate()
    cells = result.pop("cells")
    print(json.dumps(result, indent=2)[:-2] + ',\n  "cells": [\n' +
          ",\n".join("    " + json.dumps(cell) for cell in cells) + '\n  ]\n}')
