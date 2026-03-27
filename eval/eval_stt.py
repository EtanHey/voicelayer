#!/usr/bin/env python3
"""
Hebrew STT Evaluation Framework — Multi-Backend Comparison.

Compares STT backends on Hebrew (and English baseline) audio samples.
Metrics: WER (Word Error Rate), CER (Character Error Rate), Latency, RTF.

Usage:
    python3 eval/eval_stt.py                    # Run full eval
    python3 eval/eval_stt.py --backend whisper   # Single backend
    python3 eval/eval_stt.py --regenerate        # Regenerate audio samples
    python3 eval/eval_stt.py --dry-run           # Show dataset without transcribing

Results:
    eval/results/baseline-results.json
    docs.local/research/hebrew-stt-eval-baseline.md

LIMITATION: Synthetic TTS corpus (Carmit) introduces systematic bias.
Models will appear ~2x more accurate than on real conversational speech.
"""

import argparse
import json
import os
import sys
from pathlib import Path

EVAL_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(EVAL_DIR)

sys.path.insert(0, EVAL_DIR)

from backends import WhisperCppBackend, VoiceLayerBackend, WisprFlowBackend, get_available_backends
from datasets import load_dataset, load_real_recordings, save_dataset_manifest
from metrics import TranscriptionResult, compute_metrics, aggregate_metrics, LatencyTimer
from report import generate_baseline_report, generate_json_results


def run_evaluation(
    backend_filter: str | None = None,
    regenerate: bool = False,
    dry_run: bool = False,
    output_dir: str | None = None,
    hebrew_only: bool = False,
) -> dict:
    """
    Run the full STT evaluation pipeline.

    Returns dict with aggregate results per backend.
    """
    audio_dir = os.path.join(EVAL_DIR, "datasets", "audio")
    results_dir = output_dir or os.path.join(EVAL_DIR, "results")
    os.makedirs(results_dir, exist_ok=True)

    print("[eval] Loading dataset...")
    samples = load_dataset(
        output_dir=audio_dir,
        include_english=not hebrew_only,
        regenerate=regenerate,
    )

    real_dir = os.path.join(EVAL_DIR, "datasets", "real")
    real_samples = load_real_recordings(real_dir)
    samples.extend(real_samples)

    if not samples:
        print("[eval] ERROR: No samples loaded. Is Carmit TTS voice installed?")
        return {}

    print(f"[eval] Loaded {len(samples)} samples ({sum(1 for s in samples if s.language == 'he')} Hebrew, {sum(1 for s in samples if s.language == 'en')} English)")

    manifest_path = os.path.join(results_dir, "dataset-manifest.json")
    save_dataset_manifest(samples, manifest_path)

    if dry_run:
        print("\n[eval] DRY RUN — dataset loaded, skipping transcription.")
        for s in samples:
            print(f"  {s.id}: [{s.language}] {s.reference_text[:60]}...")
        return {}

    backends = get_available_backends(project_root=PROJECT_ROOT)
    if backend_filter:
        backends = [b for b in backends if backend_filter.lower() in b.name.lower()]

    if not backends:
        print("[eval] ERROR: No STT backends available.")
        print("[eval] Install whisper-cpp: brew install whisper-cpp")
        print("[eval] Download model: curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\")
        print("[eval]   https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
        return {}

    print(f"[eval] Available backends: {', '.join(b.name for b in backends)}")

    all_aggregates = []

    for backend in backends:
        print(f"\n[eval] === {backend.name} ===")
        metric_results = []

        for sample in samples:
            if not sample.audio_path or not os.path.exists(sample.audio_path):
                print(f"  SKIP {sample.id}: no audio file")
                continue

            print(f"  {sample.id}...", end=" ", flush=True)
            try:
                text, latency_ms = backend.transcribe(sample.audio_path, sample.language)

                tr = TranscriptionResult(
                    reference=sample.reference_text,
                    hypothesis=text,
                    backend=backend.name,
                    sample_id=sample.id,
                    latency_ms=latency_ms,
                    audio_duration_ms=sample.duration_ms,
                    language=sample.language,
                )
                mr = compute_metrics(tr)
                metric_results.append(mr)
                print(f"WER={mr.wer:.1%} CER={mr.cer:.1%} {latency_ms:.0f}ms")

            except Exception as e:
                print(f"ERROR: {e}")
                continue

        if metric_results:
            agg = aggregate_metrics(metric_results, backend.name)
            all_aggregates.append(agg)
            print(f"\n  [{backend.name}] Mean WER={agg.mean_wer:.1%} CER={agg.mean_cer:.1%} Latency={agg.mean_latency_ms:.0f}ms")

    if not all_aggregates:
        print("\n[eval] No results collected.")
        return {}

    dataset_info = {
        "total": len(samples),
        "hebrew": sum(1 for s in samples if s.language == "he"),
        "english": sum(1 for s in samples if s.language == "en"),
        "sources": list(set(s.source for s in samples)),
    }

    model_info = None
    for b in backends:
        if hasattr(b, "get_model_name"):
            model_info = b.get_model_name()
            break

    json_results = generate_json_results(all_aggregates, dataset_info)
    json_path = os.path.join(results_dir, "baseline-results.json")
    with open(json_path, "w", encoding="utf-8") as f:
        f.write(json_results)
    print(f"\n[eval] JSON results: {json_path}")

    report = generate_baseline_report(all_aggregates, dataset_info, model_info=model_info)
    report_dir = os.path.join(PROJECT_ROOT, "docs.local", "research")
    os.makedirs(report_dir, exist_ok=True)
    report_path = os.path.join(report_dir, "hebrew-stt-eval-baseline.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)
    print(f"[eval] Report: {report_path}")

    return {
        "aggregates": [
            {
                "backend": agg.backend,
                "mean_wer": agg.mean_wer,
                "mean_cer": agg.mean_cer,
                "num_samples": agg.num_samples,
            }
            for agg in all_aggregates
        ],
        "dataset_info": dataset_info,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Hebrew STT Evaluation — multi-backend comparison"
    )
    parser.add_argument(
        "--backend",
        type=str,
        default=None,
        help="Filter to a specific backend (whisper, voicelayer, wispr)",
    )
    parser.add_argument(
        "--regenerate",
        action="store_true",
        help="Regenerate synthetic audio samples",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Load dataset and show samples without transcribing",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=None,
        help="Custom output directory for results",
    )
    parser.add_argument(
        "--hebrew-only",
        action="store_true",
        help="Only evaluate Hebrew samples (skip English baseline)",
    )
    args = parser.parse_args()

    results = run_evaluation(
        backend_filter=args.backend,
        regenerate=args.regenerate,
        dry_run=args.dry_run,
        output_dir=args.output_dir,
        hebrew_only=args.hebrew_only,
    )

    if results:
        print("\n[eval] === DONE ===")
        for agg in results.get("aggregates", []):
            print(f"  {agg['backend']}: WER={agg['mean_wer']:.1%} CER={agg['mean_cer']:.1%} ({agg['num_samples']} samples)")


if __name__ == "__main__":
    main()
