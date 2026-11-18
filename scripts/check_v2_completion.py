#!/usr/bin/env python3
"""Additional V2 functional register gate; independent audit remains a separate public-launch gate."""
import csv
import subprocess
from pathlib import Path

rows=list(csv.DictReader(Path('reports/V2_ACCEPTANCE_MATRIX.csv').open(newline='')))
assert {r['id'] for r in rows}=={f'V2-{i:02}' for i in range(1,21)} and len(rows)==20
for row in rows:
    assert row['status'] in {'PASS','FAIL','NOT_RUN','BLOCKED'}
    if row['status']=='PASS':
        assert row['evidence'] and Path(row['evidence']).is_file() and row['exit_code']=='0' and row['command'] and row['environment'] and row['date']
        subprocess.run(['git','cat-file','-e',row['commit']+'^{commit}'],check=True)
pending=[f"{r['id']}:{r['status']}" for r in rows if r['id']!='V2-20' and r['status']!='PASS']
audit=next(r for r in rows if r['id']=='V2-20')
print(f"V2 functional scenarios not PASS: {len(pending)}; {', '.join(pending)}")
print(f"Independent audit/owner public launch gate: {audit['status']}. PRODUCTION_APPROVED=false.")
raise SystemExit(1 if pending else 0)
