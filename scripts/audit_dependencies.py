#!/usr/bin/env python3
"""Query OSV for public Cargo package names/versions; no source or secrets are sent."""
import json
import subprocess
import tomllib
import urllib.request
from pathlib import Path

def main():
    lock=tomllib.loads(Path('src/crypto_core/Cargo.lock').read_text())
    packages=[p for p in lock['package'] if p.get('source','').startswith('registry+')]
    queries=[dict(package=dict(name=p['name'],ecosystem='crates.io'),version=p['version']) for p in packages]
    req=urllib.request.Request('https://api.osv.dev/v1/querybatch',data=json.dumps(dict(queries=queries)).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=60) as r: result=json.load(r)
    findings=[dict(name=p['name'],version=p['version'],vulnerabilities=r['vulns']) for p,r in zip(packages,result['results'],strict=True) if r.get('vulns')]
    Path('reports/evidence/osv-cargo.json').write_text(json.dumps(dict(packages_checked=len(packages),source='https://api.osv.dev/v1/querybatch',findings=findings),indent=2)+'\n')
    metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--manifest-path','src/crypto_core/Cargo.toml']))
    inventory=[{k:p.get(k) for k in ['name','version','license','source']} for p in metadata['packages']]
    Path('reports/evidence/cargo-licenses.json').write_text(json.dumps(inventory,indent=2)+'\n')
    print(f'OSV checked {len(packages)} Cargo packages: {len(findings)} findings. License metadata saved; this is not a legal or independent security review.')
    for f in findings: print(f['name'],f['version'],[v['id'] for v in f['vulnerabilities']])
    return 1 if findings else 0

if __name__=='__main__':raise SystemExit(main())
