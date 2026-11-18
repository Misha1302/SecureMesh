#!/usr/bin/env bash
# Optional bounded unattended multi-session Codex runner for this *dedicated* workspace.
# NOT a promise of full completion: stopping depends on actual gates, quota and available SDKs.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f '00_START_HERE_RU.md' || ! -f 'PROMPT_CODEX_START_RU.txt' || ! -f 'AGENTS.md' ]]; then
  echo 'ERROR: Run only from an extracted SecureMesh brief workspace.' >&2
  exit 2
fi
if [[ "$ROOT" == '/' || "$ROOT" == "$HOME" || "$ROOT" == '/mnt/data' ]]; then
  echo 'ERROR: Workspace is not a dedicated directory.' >&2
  exit 2
fi
if ! command -v codex >/dev/null 2>&1; then
  echo 'ERROR: Codex CLI is not installed or not on PATH.' >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERROR: Python3 is required.' >&2
  exit 2
fi
python3 tools/verify_bundle.py

MAX_RUNS="${MAX_CODEX_RUNS:-12}"
if ! [[ "$MAX_RUNS" =~ ^[1-9][0-9]*$ ]] || (( MAX_RUNS > 100 )); then
  echo 'ERROR: MAX_CODEX_RUNS must be 1..100' >&2
  exit 2
fi
LOG_DIR="$ROOT/.codex-runner/logs"
mkdir -p "$LOG_DIR"
STATUS_FILE="$ROOT/.codex-runner/session-counter.txt"
if [[ -f "$STATUS_FILE" ]]; then
  seqno="$(cat "$STATUS_FILE")"
  [[ "$seqno" =~ ^[0-9]+$ ]] || seqno=0
else
  seqno=0
fi

# IMPORTANT: This script doesn't override the selected Codex sandbox and never launches --yolo.
for (( run=1; run<=MAX_RUNS; run++ )); do
  ((seqno+=1))
  printf '%s\n' "$seqno" > "$STATUS_FILE"
  logfile="$LOG_DIR/session_$(printf '%04d' "$seqno").log"
  prompt='PROMPT_CODEX_RESUME_RU.txt'
  if [[ "$seqno" -eq 1 ]]; then prompt='PROMPT_CODEX_START_RU.txt'; fi
  echo "Codex session $run/$MAX_RUNS (global #$seqno); log: $logfile"
  set +e
  codex exec --sandbox workspace-write - < "$prompt" 2>&1 | tee "$logfile"
  codex_status=${PIPESTATUS[0]}
  set -e
  echo "Session exit code: $codex_status" | tee -a "$logfile"
  # Never claim completion based solely on the agent's prose or a flag file.
  if [[ -f Makefile && -f reports/ACCEPTANCE_MATRIX.csv ]]; then
    if python3 tools/check_completion.py && make verify; then
      echo 'All recorded P0/P1 gates PASS and make verify succeeded. Local handoff candidate only; production requires independent audit.'
      exit 0
    fi
  fi
  # Login/quota/runtime failures should not cause a blind expensive infinite loop.
  if [[ "$codex_status" -ne 0 ]]; then
    echo 'Codex CLI returned an error; stopping runner rather than blindly retrying. See log.' >&2
    exit "$codex_status"
  fi
done

echo 'Reached MAX_CODEX_RUNS: work may be PARTIAL. Inspect STATUS.md / reports, then explicitly resume if appropriate.'
exit 1
