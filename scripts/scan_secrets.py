#!/usr/bin/env python3
import re
import subprocess
from pathlib import Path

paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z']).split(b'\0')
patterns=[rb'(?m)^-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',rb'\bAKIA[0-9A-Z]{16}\b',rb'\bghp_[A-Za-z0-9]{36}\b']
findings=[];checked=0
for value in paths:
    if not value:continue
    path=Path(value.decode())
    if not path.is_file():continue
    data=path.read_bytes()
    if b'\0' in data:continue
    checked+=1
    if any(re.search(pattern,data) for pattern in patterns): findings.append(str(path))
print(f'Scanned {checked} tracked/unignored text files for PEM private keys, AWS access-key IDs and GitHub PAT patterns. Findings: {len(findings)}. Scope is limited to these patterns.')
for path in findings:print(path)
raise SystemExit(1 if findings else 0)
