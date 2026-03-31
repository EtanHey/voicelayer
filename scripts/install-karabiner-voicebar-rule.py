#!/usr/bin/env python3
"""
Merge the VoiceBar Karabiner complex modification into ~/.config/karabiner/karabiner.json

Requires Karabiner-Elements (config file must exist at least once).
Idempotent: skips if rule description is already present.
"""
from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path
from typing import Any

RULE: dict[str, Any] = {
    "description": "VoiceBar: F6 -> voicebar://start-recording",
    "manipulators": [
        {
            "type": "basic",
            "from": {
                "key_code": "f6",
                "modifiers": {
                    "optional": ["any"],
                },
            },
            "to": [{"shell_command": "open 'voicebar://start-recording'"}],
        }
    ],
}


def _selected_profile(data: dict[str, Any]) -> dict[str, Any]:
    profiles = data.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        raise ValueError("karabiner.json: missing or empty 'profiles'")
    for profile in profiles:
        if isinstance(profile, dict) and profile.get("selected") is True:
            return profile
    first = profiles[0]
    if not isinstance(first, dict):
        raise ValueError("karabiner.json: invalid profile entry")
    return first


def merge_voicebar_rule(data: dict[str, Any]) -> bool:
    profile = _selected_profile(data)
    complex_modifications = profile.setdefault("complex_modifications", {})
    if not isinstance(complex_modifications, dict):
        raise ValueError("profile.complex_modifications must be an object")
    rules = complex_modifications.setdefault("rules", [])
    if not isinstance(rules, list):
        raise ValueError("complex_modifications.rules must be an array")

    description = RULE["description"]
    if any(isinstance(rule, dict) and rule.get("description") == description for rule in rules):
        return False
    rules.append(json.loads(json.dumps(RULE)))
    return True


def main() -> int:
    config_path = Path.home() / ".config" / "karabiner" / "karabiner.json"
    if not config_path.is_file():
        print(
            f"ERROR: {config_path} not found.\n"
            "Install Karabiner-Elements from https://karabiner-elements.pqrs.org/ "
            "and open it once so the config file is created.",
            file=sys.stderr,
        )
        return 1

    raw = config_path.read_text(encoding="utf-8")
    data = json.loads(raw)

    if not merge_voicebar_rule(data):
        print(f"Rule already present — no change: {config_path}")
        return 0

    backup = config_path.with_suffix(config_path.suffix + ".bak-voicebar")
    shutil.copy2(config_path, backup)
    print(f"Backup: {backup}")

    config_path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Added VoiceBar rule to: {config_path}")
    print("If Karabiner is running, it may pick this up automatically; otherwise restart Karabiner Elements.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
