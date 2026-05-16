#!/usr/bin/env python3
"""Materialize the private Phase 4 heldout corrector JSONL from Wispr Flow."""

import json
import os
import sqlite3
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DB = Path("/tmp/wispr-flow-readonly.sqlite")
DEFAULT_OUTPUT = PROJECT_ROOT / "eval" / "heldout-corrector.jsonl"

HEBREW_CHARS = "אבגדהוזחטיכלמנסעפצקרשת"


def _connect_readonly(db_path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)


def _active_dictionary(conn: sqlite3.Connection) -> list[tuple[str, str | None]]:
    return conn.execute(
        """
        SELECT phrase, replacement
        FROM Dictionary
        WHERE isDeleted = 0
          AND isSnippet = 0
          AND phrase IS NOT NULL
          AND trim(phrase) != ''
        ORDER BY frequencyUsed DESC, createdAt DESC
        """
    ).fetchall()


def _word_count(text: str | None) -> int:
    return len((text or "").split())


def _comparable_words(source: str | None, target: str | None) -> bool:
    source_words = _word_count(source)
    target_words = _word_count(target)
    if source_words < 3 or target_words < 3:
        return False
    ratio = target_words / max(source_words, 1)
    return 0.5 <= ratio <= 2.0


def _rows(
    conn: sqlite3.Connection,
    where: str,
    limit: int,
    exclude: set[str],
    predicate=None,
) -> list[dict]:
    sql = f"""
        SELECT transcriptEntityId, asrText, formattedText, editedText, timestamp,
               detectedLanguage, language, app, speechDuration, averageLogProb,
               numWords, numDictionaryReplacements, numWordsCorrected
        FROM History
        WHERE {where}
        ORDER BY timestamp DESC
        LIMIT 400
    """
    selected: list[dict] = []
    conn.row_factory = sqlite3.Row
    for row in conn.execute(sql):
        entity_id = row["transcriptEntityId"]
        if entity_id in exclude:
            continue
        candidate = dict(row)
        if predicate and not predicate(candidate):
            continue
        selected.append(candidate)
        exclude.add(entity_id)
        if len(selected) == limit:
            break
    return selected


def _has_hebrew(row: dict) -> bool:
    text = " ".join(
        str(row.get(key) or "") for key in ("asrText", "formattedText", "editedText")
    )
    return any(ch in text for ch in HEBREW_CHARS)


def _dictionary_terms(row: dict, dictionary: list[tuple[str, str | None]]) -> list[str]:
    haystack = " ".join(
        str(row.get(key) or "").lower()
        for key in ("asrText", "formattedText", "editedText")
    )
    terms: list[str] = []
    for phrase, replacement in dictionary:
        candidates = [phrase, replacement]
        if any(candidate and candidate.lower() in haystack for candidate in candidates):
            terms.append(replacement or phrase)
        if len(terms) >= 12:
            break
    return sorted(set(terms))


def _row_to_manifest(row: dict, tags: list[str], dictionary: list[tuple[str, str | None]]) -> dict:
    asr_text = (row.get("asrText") or "").strip()
    formatted_text = (row.get("formattedText") or "").strip()
    edited_text = row.get("editedText")
    if isinstance(edited_text, str):
        edited_text = edited_text.strip()
    should_change = "no-op" not in tags
    if "no-op" in tags:
        input_text = formatted_text
        input_source = "formatted_text"
        target_text = formatted_text
        target_source = "formatted_text"
    elif "content-edit" in tags:
        input_text = formatted_text
        input_source = "formatted_text"
        target_text = edited_text if edited_text is not None and edited_text.strip() else formatted_text
        target_source = "edited_text"
    else:
        input_text = asr_text or formatted_text
        input_source = "asr_text" if asr_text else "formatted_text"
        target_text = edited_text if edited_text is not None and edited_text.strip() else formatted_text
        target_source = "edited_text" if edited_text and edited_text.strip() else "formatted_text"
    terms = _dictionary_terms(row, dictionary)
    language = row.get("detectedLanguage") or row.get("language")
    if not language:
        language = "he" if _has_hebrew(row) else "en"

    return {
        "id": f"wispr-{row['transcriptEntityId']}",
        "source": "wispr-flow-history",
        "source_ref": row["transcriptEntityId"],
        "split": "heldout",
        "language": language,
        "app": row.get("app"),
        "audio_ref": None,
        "audio_path": None,
        "asr_text": asr_text,
        "formatted_text": formatted_text,
        "edited_text": edited_text,
        "input_text": input_text,
        "input_source": input_source,
        "target_text": target_text or "",
        "target_source": target_source,
        "should_change": should_change,
        "protected_terms": terms,
        "dictionary_terms": terms,
        "num_words": row.get("numWords"),
        "speech_duration": row.get("speechDuration"),
        "num_dictionary_replacements": row.get("numDictionaryReplacements") or 0,
        "num_words_corrected": row.get("numWordsCorrected") or 0,
        "average_log_prob": row.get("averageLogProb"),
        "tags": tags,
        "notes": "Private local heldout row materialized from read-only Wispr Flow SQLite.",
    }


def materialize(db_path: Path = DEFAULT_DB, output_path: Path = DEFAULT_OUTPUT) -> list[dict]:
    conn = _connect_readonly(db_path)
    dictionary = _active_dictionary(conn)
    exclude: set[str] = set()
    manifest: list[dict] = []

    selections = [
        (
            10,
            "content-edit",
            """
            editedText IS NOT NULL
            AND formattedText IS NOT NULL
            AND trim(editedText) != ''
            AND trim(formattedText) != ''
            AND trim(editedText) != trim(formattedText)
            """,
        ),
        (
            5,
            "no-op",
            """
            formattedText IS NOT NULL
            AND trim(formattedText) != ''
            AND (editedText IS NULL OR trim(editedText) = trim(formattedText))
            """,
        ),
        (
            5,
            "dictionary-heavy",
            """
            coalesce(numDictionaryReplacements, 0) > 0
            AND formattedText IS NOT NULL
            AND trim(formattedText) != ''
            """,
        ),
        (
            3,
            "hebrew-mixed",
            """
            (detectedLanguage = 'he' OR language = 'he'
             OR asrText GLOB '*[אבגדהוזחטיכלמנסעפצקרשת]*'
             OR formattedText GLOB '*[אבגדהוזחטיכלמנסעפצקרשת]*')
            AND formattedText IS NOT NULL
            AND trim(formattedText) != ''
            """,
        ),
        (
            1,
            "long-form-4m35s",
            """
            speechDuration BETWEEN 250 AND 320
            AND formattedText IS NOT NULL
            AND trim(formattedText) != ''
            """,
        ),
        (
            1,
            "non-speech-hallucination",
            """
            formattedText IS NOT NULL
            AND (
              lower(coalesce(asrText, formattedText, '')) LIKE '%thank you%'
              OR lower(coalesce(asrText, formattedText, '')) LIKE '%music%'
              OR lower(coalesce(asrText, formattedText, '')) LIKE '%subtitle%'
            )
            """,
        ),
    ]

    predicates = {
        "content-edit": lambda row: _comparable_words(
            row.get("formattedText"), row.get("editedText")
        ),
    }

    for limit, tag, where in selections:
        for row in _rows(conn, where, limit, exclude, predicates.get(tag)):
            manifest.append(_row_to_manifest(row, [tag], dictionary))

    if len(manifest) != 25:
        raise RuntimeError(f"Expected 25 heldout rows, selected {len(manifest)}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        for row in manifest:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    os.chmod(output_path, 0o600)
    return manifest


if __name__ == "__main__":
    rows = materialize()
    counts: dict[str, int] = {}
    for row in rows:
        for tag in row["tags"]:
            counts[tag] = counts.get(tag, 0) + 1
    print(json.dumps({"path": str(DEFAULT_OUTPUT), "rows": len(rows), "tags": counts}, indent=2))
