#!/usr/bin/env python3
"""Read-only KG evidence snippets for the VoiceReview conversation endpoint."""

from __future__ import annotations

import argparse
import json
import os
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
    args = parser.parse_args(argv)

    db_path = resolve_db_path(args.db)
    members = parse_members(args.members_json)
    per_member = max(1, min(args.per_member, 10))
    snippet_chars = max(80, min(args.snippet_chars, 2000))

    con = sqlite3.connect(readonly_uri(db_path), uri=True, timeout=2.0)
    try:
        con.execute("PRAGMA query_only = ON")
        payload = {
            "members": [
                fetch_member_snippets(
                    con,
                    member,
                    per_member=per_member,
                    snippet_chars=snippet_chars,
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
