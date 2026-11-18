#!/usr/bin/env python3
"""Offline integrity/structure validator for the SecureMesh brief.

This verifies document bytes, not any app implementation or security property.
"""
from __future__ import annotations

import csv
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "MANIFEST_SHA256.txt"


def main() -> int:
    if not MANIFEST.is_file():
        print(f"ERROR: missing {MANIFEST}", file=sys.stderr)
        return 2
    errors: list[str] = []
    checked: list[str] = []
    for lineno, line in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            errors.append(f"manifest line {lineno}: invalid format")
            continue
        expected, rel = match.groups()
        path = (ROOT / rel).resolve()
        if not path.is_relative_to(ROOT.resolve()):
            errors.append(f"path traversal blocked: {rel}")
            continue
        if not path.is_file():
            errors.append(f"missing: {rel}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            errors.append(f"checksum mismatch: {rel}")
        checked.append(rel)
    if "PROMPT_CODEX_START_RU.txt" not in checked or "AGENTS.md" not in checked:
        errors.append("missing crucial prompt or AGENTS.md in manifest")
    matrix = ROOT / "checks" / "ACCEPTANCE_MATRIX.csv"
    try:
        with matrix.open(newline="", encoding="utf-8") as file:
            rows = list(csv.DictReader(file))
        actual_ids = {row["id"] for row in rows}
        expected_ids = {f"AT-{x:03}" for x in range(1, 41)}
        if actual_ids != expected_ids or len(rows) != 40:
            errors.append(f"acceptance matrix expected AT-001..AT-040; actual {len(rows)} rows")
        for row in rows:
            if row.get("status") != "NOT_RUN":
                # The bundle itself never includes test results or fake PASS.
                errors.append(f"bundle test status should be NOT_RUN: {row['id']}")
    except (OSError, KeyError, csv.Error) as exc:
        errors.append(f"matrix parse error: {exc}")
    try:
        profiles = json.loads((ROOT / "checks" / "NETWORK_PROFILES.json").read_text(encoding="utf-8"))
        if len(profiles["profiles"]) < 5:
            errors.append("network profiles missing")
    except (OSError, KeyError, ValueError) as exc:
        errors.append(f"network profiles parse error: {exc}")
    if errors:
        print("SecureMesh brief verification FAILED")
        for msg in errors:
            print(f"- {msg}")
        return 1
    print(f"SecureMesh brief verification OK — {len(checked)} files SHA-256 verified; 40 acceptance tests initialized NOT_RUN.")
    print("NOTE: This verifies DOCUMENT INTEGRITY ONLY; app and security tests not performed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
