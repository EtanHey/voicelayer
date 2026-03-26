"""
Report generation for Hebrew STT evaluation.

Outputs markdown comparison tables and baseline report.
"""

import json
from datetime import datetime, timezone
from typing import Optional

from metrics import AggregateMetrics, MetricResult


BIAS_WARNING = (
    "> **LIMITATION — Synthetic TTS Bias:** This evaluation uses macOS Carmit TTS "
    "to generate Hebrew audio samples. Synthetic TTS audio overestimates real-world "
    "STT accuracy by approximately 2x because it has perfect pronunciation, zero "
    "disfluencies, no background noise, and consistent speaking rate. These baselines "
    "represent **best-case** performance. Real conversational Hebrew speech will yield "
    "significantly higher WER/CER values."
)


def format_comparison_table(aggregates: list[AggregateMetrics]) -> str:
    """Generate a markdown comparison table from aggregate metrics."""
    if not aggregates:
        return "_No results to display._"

    lines = [
        "| Backend | Samples | Mean WER | Mean CER | Median WER | Median CER | Mean Latency | Mean RTF |",
        "|---------|---------|----------|----------|------------|------------|--------------|----------|",
    ]

    for agg in aggregates:
        lines.append(
            f"| {agg.backend} | {agg.num_samples} "
            f"| {agg.mean_wer:.1%} | {agg.mean_cer:.1%} "
            f"| {agg.median_wer:.1%} | {agg.median_cer:.1%} "
            f"| {agg.mean_latency_ms:.0f}ms | {agg.mean_rtf:.2f}x |"
        )

    return "\n".join(lines)


def format_per_sample_table(results: list[MetricResult]) -> str:
    """Generate a per-sample breakdown table."""
    if not results:
        return "_No per-sample results._"

    lines = [
        "| Sample | WER | CER | Latency | Reference | Hypothesis |",
        "|--------|-----|-----|---------|-----------|------------|",
    ]

    for r in results:
        ref_short = r.reference[:40] + ("..." if len(r.reference) > 40 else "")
        hyp_short = r.hypothesis[:40] + ("..." if len(r.hypothesis) > 40 else "")
        lines.append(
            f"| {r.sample_id} | {r.wer:.1%} | {r.cer:.1%} "
            f"| {r.latency_ms:.0f}ms | {ref_short} | {hyp_short} |"
        )

    return "\n".join(lines)


def generate_baseline_report(
    aggregates: list[AggregateMetrics],
    dataset_info: dict,
    model_info: Optional[str] = None,
) -> str:
    """Generate the full baseline evaluation report as markdown."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    sections = [
        f"# Hebrew STT Evaluation — Baseline Report",
        f"",
        f"**Generated:** {now}",
        f"**Framework:** VoiceLayer eval v1.0",
        f"**Metrics:** WER (jiwer), CER (jiwer), Latency, RTF",
    ]

    if model_info:
        sections.append(f"**Primary model:** {model_info}")

    sections.extend([
        "",
        "---",
        "",
        "## Bias Disclaimer",
        "",
        BIAS_WARNING,
        "",
        "---",
        "",
        "## Summary Comparison",
        "",
        format_comparison_table(aggregates),
        "",
    ])

    for agg in aggregates:
        if agg.per_sample:
            he_samples = [s for s in agg.per_sample if s.language == "he"]
            en_samples = [s for s in agg.per_sample if s.language == "en"]

            sections.extend([
                f"### {agg.backend} — Per-Sample Breakdown",
                "",
            ])

            if he_samples:
                sections.extend([
                    "#### Hebrew Samples",
                    "",
                    format_per_sample_table(he_samples),
                    "",
                ])

            if en_samples:
                sections.extend([
                    "#### English Samples (baseline comparison)",
                    "",
                    format_per_sample_table(en_samples),
                    "",
                ])

    sections.extend([
        "---",
        "",
        "## Dataset",
        "",
        f"- **Total samples:** {dataset_info.get('total', 0)}",
        f"- **Hebrew samples:** {dataset_info.get('hebrew', 0)}",
        f"- **English samples:** {dataset_info.get('english', 0)}",
        f"- **Sources:** {', '.join(dataset_info.get('sources', []))}",
        "",
        "### Source Descriptions",
        "",
        "| Source | Description | Bias |",
        "|--------|-------------|------|",
        "| synthetic | macOS Carmit TTS (Hebrew) / Samantha (English) | ~2x overestimate vs real speech |",
        "| ivrit-ai | ivrit-ai Hebrew ASR dataset samples | Real speech, representative |",
        "| whisperkit | WhisperKit test samples from HuggingFace | Clean recorded speech |",
        "| real | Real recordings from repo | Closest to production |",
        "",
        "---",
        "",
        "## Methodology",
        "",
        "### Metrics",
        "",
        "- **WER (Word Error Rate):** `(S + D + I) / N` — standard ASR metric via `jiwer`",
        "- **CER (Character Error Rate):** WER at character level — important for Hebrew ",
        "  where word boundaries differ from English",
        "- **Latency:** Wall-clock time from audio file submission to transcription return",
        "- **RTF (Real-Time Factor):** `latency / audio_duration` — <1.0 means faster than real-time",
        "",
        "### Dropped Metrics",
        "",
        "- ~~**PolyWER**~~ — Arabic-English only (EMNLP 2024), needs 2-4h adaptation for Hebrew",
        "- ~~**PIER**~~ — Point-of-Interest Error Rate (ICASSP 2025), code-switching specific",
        "",
        "### Tools",
        "",
        "- `jiwer` — community standard WER/CER, used by ivrit-ai",
        "- `whisper.cpp` — local inference via GGML models",
        "- macOS `say -v Carmit` — synthetic Hebrew audio generation",
        "",
        "---",
        "",
        "## Next Steps",
        "",
        "1. Collect real Hebrew speech recordings for more representative baselines",
        "2. Evaluate Whisper fine-tuned on ivrit-ai corpus (when available)",
        "3. A/B test VoiceLayer post-processing rules on real transcriptions",
        "4. Track WER/CER trends over time as the pipeline improves",
    ])

    return "\n".join(sections) + "\n"


def generate_json_results(
    aggregates: list[AggregateMetrics],
    dataset_info: dict,
) -> str:
    """Generate JSON results for programmatic consumption."""
    results = {
        "version": "1.0.0",
        "generated": datetime.now(timezone.utc).isoformat(),
        "bias_warning": "Synthetic TTS overestimates accuracy ~2x vs real speech",
        "dataset": dataset_info,
        "backends": [],
    }

    for agg in aggregates:
        backend_data = {
            "name": agg.backend,
            "num_samples": agg.num_samples,
            "mean_wer": round(agg.mean_wer, 4),
            "mean_cer": round(agg.mean_cer, 4),
            "median_wer": round(agg.median_wer, 4),
            "median_cer": round(agg.median_cer, 4),
            "mean_latency_ms": round(agg.mean_latency_ms, 1),
            "mean_rtf": round(agg.mean_rtf, 3),
            "per_sample": [
                {
                    "sample_id": r.sample_id,
                    "wer": round(r.wer, 4),
                    "cer": round(r.cer, 4),
                    "latency_ms": round(r.latency_ms, 1),
                    "reference": r.reference,
                    "hypothesis": r.hypothesis,
                }
                for r in agg.per_sample
            ],
        }
        results["backends"].append(backend_data)

    return json.dumps(results, ensure_ascii=False, indent=2)
