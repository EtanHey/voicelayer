#!/usr/bin/env python3
"""Text-only post-STT corrector evaluation for local heldout JSONL."""

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

EVAL_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = EVAL_DIR.parent

sys.path.insert(0, str(EVAL_DIR))

from metrics import (  # noqa: E402
    TranscriptionResult,
    aggregate_metrics,
    compute_correction_deltas,
    compute_metrics,
)


REQUIRED_FIELDS = {
    "id",
    "source",
    "source_ref",
    "split",
    "language",
    "app",
    "audio_ref",
    "audio_path",
    "asr_text",
    "formatted_text",
    "edited_text",
    "input_text",
    "input_source",
    "target_text",
    "target_source",
    "should_change",
    "protected_terms",
    "dictionary_terms",
    "num_words",
    "speech_duration",
    "num_dictionary_replacements",
    "num_words_corrected",
    "average_log_prob",
    "tags",
    "notes",
}


@dataclass(frozen=True)
class CorrectorRow:
    id: str
    input_text: str
    target_text: str
    language: str
    tags: list[str]
    raw: dict


def load_corrector_manifest(path: str | Path) -> list[CorrectorRow]:
    """Load and validate Phase 1 heldout-corrector JSONL rows."""
    manifest_path = Path(path)
    rows: list[CorrectorRow] = []

    with manifest_path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            if not line.strip():
                continue
            data = json.loads(line)
            missing = REQUIRED_FIELDS.difference(data)
            if missing:
                missing_list = ", ".join(sorted(missing))
                raise ValueError(
                    f"{manifest_path}:{line_no} missing required fields: {missing_list}"
                )
            rows.append(
                CorrectorRow(
                    id=str(data["id"]),
                    input_text=str(data["input_text"] or ""),
                    target_text=str(data["target_text"] or ""),
                    language=str(data["language"] or "unknown"),
                    tags=list(data.get("tags") or []),
                    raw=data,
                )
            )

    return rows


def _run_identity(rows: Sequence[CorrectorRow]) -> dict[str, dict]:
    return {
        row.id: {
            "text": row.input_text,
            "latency_ms": 0.0,
            "changed": False,
            "mode": "identity",
        }
        for row in rows
    }


def _run_rules(rows: Sequence[CorrectorRow]) -> dict[str, dict]:
    payload = {
        "backend": "rules",
        "items": [{"id": row.id, "text": row.input_text} for row in rows],
    }
    proc = subprocess.run(
        ["bun", "run", str(EVAL_DIR / "corrector_runner.ts")],
        input=json.dumps(payload, ensure_ascii=False),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=PROJECT_ROOT,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"rules corrector failed: {proc.stderr.strip()}")
    data = json.loads(proc.stdout)
    return {item["id"]: item for item in data["results"]}


def _run_backend(backend: str, rows: Sequence[CorrectorRow]) -> dict[str, dict]:
    if backend == "identity":
        return _run_identity(rows)
    if backend == "rules":
        return _run_rules(rows)
    raise ValueError(f"Unsupported corrector backend: {backend}")


def _write_json(path: Path, payload: dict):
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
        f.write("\n")


def _markdown_cell(value: str) -> str:
    return (
        value.replace("\n", "<br>")
        .replace("|", "\\|")
        .replace("\r", "")
    )


def _write_markdown(path: Path, payload: dict):
    lines = [
        "# Corrector Evaluation Report",
        "",
        f"**Generated:** {payload['generated']}",
        f"**Manifest:** `{payload['manifest']}`",
        f"**Samples:** {payload['dataset']['total']}",
        "",
        "| Backend | Samples | Mean WER | Mean CER | Mean Latency | Changed |",
        "|---------|---------|----------|----------|--------------|---------|",
    ]
    for backend in payload["backends"]:
        lines.append(
            f"| {backend['name']} | {backend['num_samples']} | "
            f"{backend['mean_wer']:.1%} | {backend['mean_cer']:.1%} | "
            f"{backend['mean_latency_ms']:.2f}ms | {backend['changed_count']} |"
        )

    lines.extend(
        [
            "",
            "## Per-Category Aggregates",
            "",
            "| Backend | Category | Samples | Mean WER | Mean CER | Mean Latency |",
            "|---------|----------|---------|----------|----------|--------------|",
        ]
    )
    for backend in payload["backends"]:
        for category, metrics in sorted(backend["categories"].items()):
            lines.append(
                f"| {backend['name']} | {category} | {metrics['num_samples']} | "
                f"{metrics['mean_wer']:.1%} | {metrics['mean_cer']:.1%} | "
                f"{metrics['mean_latency_ms']:.2f}ms |"
            )

    lines.extend(
        [
            "",
            "## Per-Row Breakdown",
            "",
            "| Backend | Sample | Categories | WER | CER | Latency | Changed | Input Words | Target Words |",
            "|---------|--------|------------|-----|-----|---------|---------|-------------|--------------|",
        ]
    )
    for backend in payload["backends"]:
        for row in backend["per_sample"]:
            lines.append(
                f"| {backend['name']} | {row['sample_id']} | "
                f"{', '.join(row['tags'])} | {row['wer']:.1%} | {row['cer']:.1%} | "
                f"{row['latency_ms']:.2f}ms | {row['changed']} | "
                f"{row['input_words']} | {row['target_words']} |"
            )

    lines.extend(
        [
            "",
            "## Layer-Isolated Breakdown",
            "",
            "| Sample | Categories | Raw ASR | Cleanup | Rules | Target | Raw WER | Cleanup WER | Rules WER |",
            "|--------|------------|---------|---------|-------|--------|---------|-------------|-----------|",
        ]
    )
    for trace in payload.get("layer_traces", []):
        metrics = trace["metrics"]
        lines.append(
            f"| {trace['sample_id']} | {', '.join(trace['tags'])} | "
            f"{_markdown_cell(trace['raw_asr_text'])} | "
            f"{_markdown_cell(trace['cleanup_text'])} | "
            f"{_markdown_cell(trace['rules_text'])} | "
            f"{_markdown_cell(trace['target_text'])} | "
            f"{metrics['raw_asr']['wer']:.1%} | "
            f"{metrics['cleanup']['wer']:.1%} | "
            f"{metrics['rules']['wer']:.1%} |"
        )

    sanity = payload.get("sanity_row")
    if sanity:
        lines.extend(
            [
                "",
                "## Sanity Row",
                "",
                f"- **Sample:** `{sanity['sample_id']}`",
                f"- **Categories:** {', '.join(sanity['tags'])}",
                f"- **Input source:** {sanity['input_source']}",
                f"- **Input:** {sanity['input_text']}",
                f"- **Rules output:** {sanity['rules_output']}",
                f"- **Reference:** {sanity['target_text']}",
            ]
        )

    lines.extend(["", "## Deltas", ""])
    for delta in payload["deltas"]:
        lines.append(
            f"- `{delta['backend']}` vs identity: "
            f"WER {delta['wer_delta']:+.1%}, CER {delta['cer_delta']:+.1%}"
        )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _metric_payload(reference: str, hypothesis: str, sample_id: str, language: str) -> dict:
    metric = compute_metrics(
        TranscriptionResult(
            reference=reference,
            hypothesis=hypothesis,
            backend="layer-trace",
            sample_id=sample_id,
            latency_ms=0.0,
            audio_duration_ms=0.0,
            language=language,
        )
    )
    return {
        "wer": metric.wer,
        "cer": metric.cer,
    }


def _build_layer_traces(
    rows: Sequence[CorrectorRow],
    backend_results_by_name: dict[str, dict[str, dict]],
) -> list[dict]:
    traces = []
    rules_results = backend_results_by_name.get("rules", {})

    for row in rows:
        raw_asr_text = str(row.raw.get("asr_text") or row.input_text)
        # The current cleanup stage is implemented by the existing rules backend.
        # PR 1 only makes that layer visible; it does not alter production routing.
        cleanup_text = str(rules_results.get(row.id, {}).get("text", raw_asr_text))
        rules_text = str(rules_results.get(row.id, {}).get("text", cleanup_text))
        target_text = row.target_text

        traces.append(
            {
                "sample_id": row.id,
                "tags": row.tags,
                "input_source": row.raw.get("input_source"),
                "raw_asr_text": raw_asr_text,
                "cleanup_text": cleanup_text,
                "rules_text": rules_text,
                "target_text": target_text,
                "metrics": {
                    "raw_asr": _metric_payload(
                        target_text, raw_asr_text, row.id, row.language
                    ),
                    "cleanup": _metric_payload(
                        target_text, cleanup_text, row.id, row.language
                    ),
                    "rules": _metric_payload(
                        target_text, rules_text, row.id, row.language
                    ),
                },
            }
        )

    return traces


def run_corrector_evaluation(
    manifest_path: str | Path = EVAL_DIR / "heldout-corrector.jsonl",
    output_dir: str | Path = EVAL_DIR / "reports",
    backends: Iterable[str] = ("identity", "rules"),
) -> dict:
    rows = load_corrector_manifest(manifest_path)
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    backends_payload = []
    backend_results_by_name = {}
    for backend in backends:
        backend_results = _run_backend(backend, rows)
        backend_results_by_name[backend] = backend_results
        metrics = []
        per_sample_payload = []
        changed_count = 0
        for row in rows:
            result = backend_results[row.id]
            changed_count += 1 if result.get("changed") else 0
            metric = compute_metrics(
                TranscriptionResult(
                    reference=row.target_text,
                    hypothesis=str(result["text"]),
                    backend=backend,
                    sample_id=row.id,
                    latency_ms=float(result.get("latency_ms") or 0.0),
                    audio_duration_ms=0.0,
                    language=row.language,
                )
            )
            metrics.append(metric)
            per_sample_payload.append(
                {
                    "sample_id": metric.sample_id,
                    "tags": row.tags,
                    "wer": metric.wer,
                    "cer": metric.cer,
                    "latency_ms": metric.latency_ms,
                    "changed": bool(result.get("changed")),
                    "input_words": len(row.input_text.split()),
                    "target_words": len(row.target_text.split()),
                }
            )
        aggregate = aggregate_metrics(metrics, backend)
        category_payload = {}
        for tag in sorted({tag for row in rows for tag in row.tags}):
            tagged_metrics = [
                metric
                for metric, row in zip(metrics, rows)
                if tag in row.tags
            ]
            tagged_aggregate = aggregate_metrics(tagged_metrics, backend)
            category_payload[tag] = {
                "num_samples": tagged_aggregate.num_samples,
                "mean_wer": tagged_aggregate.mean_wer,
                "mean_cer": tagged_aggregate.mean_cer,
                "median_wer": tagged_aggregate.median_wer,
                "median_cer": tagged_aggregate.median_cer,
                "mean_latency_ms": tagged_aggregate.mean_latency_ms,
            }

        backends_payload.append(
            {
                "name": backend,
                "num_samples": aggregate.num_samples,
                "mean_wer": aggregate.mean_wer,
                "mean_cer": aggregate.mean_cer,
                "median_wer": aggregate.median_wer,
                "median_cer": aggregate.median_cer,
                "mean_latency_ms": aggregate.mean_latency_ms,
                "changed_count": changed_count,
                "categories": category_payload,
                "per_sample": per_sample_payload,
            }
        )

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    json_path = output_path / f"corrector-{timestamp}.json"
    markdown_path = output_path / f"corrector-{timestamp}.md"
    rules_backend = next((b for b in backends_payload if b["name"] == "rules"), None)
    sanity_row = None
    if rules_backend:
        candidate = min(
            (row for row in rows if "content-edit" in row.tags),
            key=lambda row: (len(row.target_text.split()), row.id),
            default=rows[0] if rows else None,
        )
        if candidate:
            rules_outputs = backend_results_by_name["rules"]
            sanity_row = {
                "sample_id": candidate.id,
                "tags": candidate.tags,
                "input_source": candidate.raw.get("input_source"),
                "input_text": candidate.input_text,
                "rules_output": rules_outputs[candidate.id]["text"],
                "target_text": candidate.target_text,
            }

    result = {
        "version": "1.0.0",
        "generated": datetime.now(timezone.utc).isoformat(),
        "manifest": str(Path(manifest_path).resolve()),
        "dataset": {
            "total": len(rows),
            "languages": sorted({row.language for row in rows}),
            "tags": sorted({tag for row in rows for tag in row.tags}),
        },
        "layer_traces": _build_layer_traces(rows, backend_results_by_name),
        "backends": backends_payload,
        "deltas": compute_correction_deltas(backends_payload, baseline="identity"),
        "sanity_row": sanity_row,
        "json_path": json_path,
        "markdown_path": markdown_path,
    }

    serializable = {**result, "json_path": str(json_path), "markdown_path": str(markdown_path)}
    _write_json(json_path, serializable)
    _write_markdown(markdown_path, serializable)
    return result


def main():
    parser = argparse.ArgumentParser(description="Run text-only STT corrector eval")
    parser.add_argument("--manifest", default=str(EVAL_DIR / "heldout-corrector.jsonl"))
    parser.add_argument("--output-dir", default=str(EVAL_DIR / "reports"))
    parser.add_argument(
        "--backend",
        action="append",
        choices=("identity", "rules"),
        help="Backend to run; repeatable. Defaults to identity and rules.",
    )
    args = parser.parse_args()

    result = run_corrector_evaluation(
        manifest_path=args.manifest,
        output_dir=args.output_dir,
        backends=tuple(args.backend or ("identity", "rules")),
    )
    print(f"[eval] JSON report: {result['json_path']}")
    print(f"[eval] Markdown report: {result['markdown_path']}")
    for backend in result["backends"]:
        print(
            f"[eval] {backend['name']}: "
            f"WER={backend['mean_wer']:.1%} CER={backend['mean_cer']:.1%} "
            f"latency={backend['mean_latency_ms']:.2f}ms"
        )


if __name__ == "__main__":
    main()
