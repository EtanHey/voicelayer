#!/usr/bin/env python3
"""Read-only KG evidence snippets for the VoiceReview conversation endpoint."""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from urllib.parse import quote


DEFAULT_DB_PATH = Path.home() / ".local" / "share" / "brainlayer" / "brainlayer.db"


def resolve_db_path(raw: str | None) -> Path:
    if raw:
        return Path(raw).expanduser()
    env = os.environ.get("BRAINLAYER_DB")
    if env:
        return Path(env).expanduser()
    return DEFAULT_DB_PATH


def readonly_uri(path: Path) -> str:
    return f"file:{quote(str(path), safe='/:')}?mode=ro"


def clean_text(value: object, max_chars: int) -> str:
    text = " ".join(str(value or "").split())
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3].rstrip() + "..."


STOP_WORDS = {
    "about",
    "actual",
    "around",
    "chunk",
    "chunks",
    "context",
    "does",
    "have",
    "into",
    "that",
    "the",
    "their",
    "them",
    "this",
    "what",
    "when",
    "where",
    "which",
    "with",
}


def tokenize(value: object) -> list[str]:
    text = str(value or "").lower()
    return [
        token
        for token in re.findall(r"[a-z0-9\u0590-\u05ff]{3,}", text)
        if token not in STOP_WORDS
    ]


def search_terms(question: str | None, member: dict) -> list[str]:
    terms = tokenize(question) + tokenize(member.get("name", "")) + tokenize(member.get("type", ""))
    deduped: list[str] = []
    seen: set[str] = set()
    for term in terms:
        if term in seen:
            continue
        seen.add(term)
        deduped.append(term)
    return deduped[:24]


def match_score(row: sqlite3.Row, terms: list[str]) -> int:
    haystack = " ".join(
        str(row[key] or "")
        for key in ["content", "summary", "project", "content_type", "source", "context"]
    ).lower()
    return sum(haystack.count(term) for term in terms)


def fetch_member_snippets(
    con: sqlite3.Connection,
    member: dict,
    *,
    per_member: int,
    snippet_chars: int,
) -> dict:
    rows = con.execute(
        """
        SELECT
          c.id,
          COALESCE(NULLIF(c.summary, ''), c.content) AS snippet_text,
          c.project,
          c.content_type,
          c.source,
          c.created_at,
          ec.relevance,
          ec.context
        FROM kg_entity_chunks ec
        JOIN chunks c ON c.id = ec.chunk_id
        WHERE ec.entity_id = ?
          AND COALESCE(c.archived, 0) = 0
          AND COALESCE(c.status, 'active') = 'active'
        ORDER BY
          COALESCE(ec.relevance, 0) DESC,
          COALESCE(c.importance, 0) DESC,
          COALESCE(c.created_at, '') DESC,
          c.id
        LIMIT ?
        """,
        (member["id"], per_member),
    ).fetchall()

    snippets = [
        {
            "chunk_id": row[0],
            "project": row[2],
            "content_type": row[3],
            "source": row[4],
            "created_at": row[5],
            "relevance": row[6],
            "context": row[7],
            "text": clean_text(row[1], snippet_chars),
        }
        for row in rows
    ]
    return {
        "id": member["id"],
        "name": member.get("name", ""),
        "type": member.get("type", ""),
        "chunks": member.get("chunks", 0),
        "snippets": snippets,
    }


def fetch_deep_member_snippets(
    con: sqlite3.Connection,
    member: dict,
    *,
    question: str | None,
    per_member: int,
    snippet_chars: int,
) -> dict:
    terms = search_terms(question, member)
    rows = con.execute(
        """
        SELECT
          c.id,
          c.content,
          c.summary,
          c.project,
          c.content_type,
          c.source,
          c.created_at,
          ec.relevance,
          ec.context,
          COALESCE(c.importance, 0) AS importance
        FROM kg_entity_chunks ec
        JOIN chunks c ON c.id = ec.chunk_id
        WHERE ec.entity_id = ?
          AND COALESCE(c.archived, 0) = 0
          AND COALESCE(c.status, 'active') = 'active'
        ORDER BY
          COALESCE(ec.relevance, 0) DESC,
          COALESCE(c.importance, 0) DESC,
          COALESCE(c.created_at, '') DESC,
          c.id
        LIMIT 160
        """,
        (member["id"],),
    ).fetchall()

    ranked = sorted(
        rows,
        key=lambda row: (
            match_score(row, terms),
            float(row["relevance"] or 0),
            float(row["importance"] or 0),
            str(row["created_at"] or ""),
        ),
        reverse=True,
    )
    if terms:
        matched = [row for row in ranked if match_score(row, terms) > 0]
        if matched:
            ranked = matched

    snippets = [
        {
            "chunk_id": row["id"],
            "project": row["project"],
            "content_type": row["content_type"],
            "source": row["source"],
            "created_at": row["created_at"],
            "relevance": row["relevance"],
            "context": row["context"],
            "text": clean_text(row["content"] or row["summary"], snippet_chars),
        }
        for row in ranked[:per_member]
    ]
    return {
        "id": member["id"],
        "name": member.get("name", ""),
        "type": member.get("type", ""),
        "chunks": member.get("chunks", 0),
        "snippets": snippets,
    }


def parse_members(raw: str) -> list[dict]:
    parsed = json.loads(raw)
    if not isinstance(parsed, list):
        raise ValueError("--members-json must be a JSON array")
    members: list[dict] = []
    for item in parsed:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            continue
        members.append(item)
    return members


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=None, help="BrainLayer SQLite DB path")
    parser.add_argument("--members-json", required=True, help="JSON array of cluster members")
    parser.add_argument("--per-member", type=int, default=3)
    parser.add_argument("--snippet-chars", type=int, default=700)
    parser.add_argument("--question", default=None, help="Question text for deeper ranked retrieval")
    parser.add_argument("--deep", action="store_true", help="Rank fuller chunks by question/member terms")
    args = parser.parse_args(argv)

    db_path = resolve_db_path(args.db)
    members = parse_members(args.members_json)
    per_member = max(1, min(args.per_member, 10))
    snippet_chars = max(80, min(args.snippet_chars, 6000))

    con = sqlite3.connect(readonly_uri(db_path), uri=True, timeout=2.0)
    con.row_factory = sqlite3.Row
    try:
        con.execute("PRAGMA query_only = ON")
        payload = {
            "members": [
                (
                    fetch_deep_member_snippets(
                        con,
                        member,
                        question=args.question,
                        per_member=per_member,
                        snippet_chars=snippet_chars,
                    )
                    if args.deep
                    else fetch_member_snippets(
                        con,
                        member,
                        per_member=per_member,
                        snippet_chars=snippet_chars,
                    )
                )
                for member in members
            ]
        }
    finally:
        con.close()

    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
