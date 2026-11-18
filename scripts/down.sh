#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os,signal
from pathlib import Path
p=Path('.local/demo-api.pid')
if p.exists():
    pid=int(p.read_text())
    process=Path('/proc')/str(pid)
    if process.exists():
        command=(process/'cmdline').read_bytes()
        if (process/'cwd').resolve()==Path.cwd() and b'dotnet' in command and b'SecureMesh.Api' in command:
            os.kill(pid,signal.SIGTERM)
    p.unlink()
PY
docker compose -f docker-compose.yml -f compose.chaos.yml --profile mail down
