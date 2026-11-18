#!/usr/bin/env python3
"""Retain actual hosted Pub license files; do not infer SPDX clearance from text presence."""
import datetime
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
graph = ROOT / 'reports/evidence/v2-pub-deps.json'
lock = ROOT / 'apps/client_flutter/pubspec.lock'
locked = {}
for match in re.finditer(r'^  ([a-zA-Z0-9_]+):\n(.*?)(?=^  [a-zA-Z0-9_]+:|^sdks:|\Z)', lock.read_text(), re.M | re.S):
    if re.search(r'^    source: hosted$', match[2], re.M):
        if 'url: "https://pub.dev"' not in match[2]:
            raise SystemExit('Unsupported hosted source; inventory incomplete')
        version = re.search(r'^    version: "([^"]+)"$', match[2], re.M)[1]
        digest = re.search(r'^      sha256: "?([0-9a-f]{64})"?$', match[2], re.M)[1]
        locked[match[1]] = (version, digest)
cache = (ROOT / '.local/pub-cache/hosted/pub.dev').resolve()
target = ROOT / 'third_party/licenses/pub'
target.mkdir(parents=True, exist_ok=True)
packages = []
missing = []
for package in json.loads(graph.read_text())['packages']:
    if package['source'] != 'hosted':
        continue
    name, version = package['name'], package['version']
    if name not in locked or locked[name][0] != version:
        raise SystemExit('Dependency graph and lock differ; inventory incomplete')
    directory = cache / f'{name}-{version}'
    license = next((directory / n for n in ('LICENSE', 'LICENSE.md', 'COPYING') if (directory / n).is_file()), None)
    record = {'name': name, 'version': version, 'locked_archive_sha256': locked[name][1], 'source': f'https://pub.dev/packages/{name}/versions/{version}', 'spdx_expression': 'NOASSERTION'}
    if license is None:
        missing.append(name)
    else:
        license.resolve().relative_to(cache)
        data = license.read_bytes()
        if len(data) > 1_048_576:
            raise SystemExit('License exceeds bounded inventory size')
        retained = target / f'{name}-{version}.txt'
        retained.write_bytes(data)
        record.update(license_text_sha256=hashlib.sha256(data).hexdigest(), retained_license=str(retained.relative_to(ROOT)))
    packages.append(record)
if len(packages) != len(locked):
    raise SystemExit('Hosted package inventory count differs from lock')
output = {'generated_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'lock_sha256': hashlib.sha256(lock.read_bytes()).hexdigest(), 'graph_sha256': hashlib.sha256(graph.read_bytes()).hexdigest(), 'packages': packages, 'missing_license_text': missing, 'spdx_review_complete': False, 'scope': 'Hosted Pub text retention only. SDK, native bundled libraries, other ecosystems and compatibility review are separate. Archive hashes are lock declarations; this is not a build provenance attestation.'}
(ROOT / 'reports/PUB_LICENSE_INVENTORY.json').write_text(json.dumps(output, indent=2) + '\n')
print(f'Retained actual license text for {len(packages) - len(missing)}/{len(packages)} hosted Pub packages. SPDX/legal compatibility review remains incomplete.')
for name in missing:
    print('MISSING LICENSE TEXT:', name)
raise SystemExit(bool(missing))
