#!/usr/bin/env python3
"""Record executed checks, never manufacture an outcome. Do not pass secrets in argv."""
import datetime
import subprocess
import sys
from pathlib import Path

label, *command = sys.argv[1:]
assert label.replace('-', '').replace('_', '').isalnum()
path = Path('reports/evidence') / (label + '.txt')
path.parent.mkdir(parents=True, exist_ok=True)
with path.open('w') as file:
    file.write(f'UTC: {datetime.datetime.now(datetime.timezone.utc).isoformat()}\nCommand: {command!r}\n')
    file.flush()
    process = subprocess.run(command, stdout=file, stderr=subprocess.STDOUT)
    file.write(f'\nExit code: {process.returncode}\n')
print(path.read_text())
raise SystemExit(process.returncode)
