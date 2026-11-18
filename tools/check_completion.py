#!/usr/bin/env python3
"""Conservative, non-authoritative gate for the optional bounded runner.

This only checks recorded statuses; 'make verify' must separately run actual tests.
"""
import csv
from pathlib import Path

root = Path(__file__).resolve().parent.parent
matrix = root / "reports" / "ACCEPTANCE_MATRIX.csv"
with matrix.open(encoding="utf-8", newline="") as file:
    rows = list(csv.DictReader(file))
incomplete = [f"{row['id']}:{row['status']}" for row in rows
              if row.get('priority') in ('P0', 'P1') and row.get('status') != 'PASS']
if incomplete:
    print(f"Completion NOT REACHED: {len(incomplete)} P0/P1 tests not PASS; examples: {', '.join(incomplete[:8])}")
    raise SystemExit(1)
print('All P0/P1 recorded PASS; actual make verify still required.')
