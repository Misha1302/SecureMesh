#!/usr/bin/env python3
"""Query public locked Pub packages against OSV; unavailable/incomplete is not PASS."""
import hashlib
import json
import re
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
lock = ROOT / 'apps/client_flutter/pubspec.lock'
queries = []
for match in re.finditer(r'^  ([a-zA-Z0-9_]+):\n(.*?)(?=^  [a-zA-Z0-9_]+:|^sdks:|\Z)', lock.read_text(), re.M | re.S):
    name, body = match.groups()
    if not re.search(r'^    source: hosted$', body, re.M):
        continue
    if 'url: "https://pub.dev"' not in body:
        raise SystemExit('Unsupported hosted source; audit incomplete')
    version = re.search(r'^    version: "([^"]+)"$', body, re.M)
    if not version:
        raise SystemExit('Missing locked version; audit incomplete')
    queries.append({'package': {'name': name, 'ecosystem': 'Pub'}, 'version': version[1]})
if not queries:
    raise SystemExit('No hosted packages parsed; audit incomplete')
control = {'package': {'name': 'archive', 'ecosystem': 'Pub'}, 'version': '3.3.6'}
query_set = [*queries, control]
results = [{'package': q['package'], 'version': q['version'], 'vulnerabilities': []} for q in query_set]
pending = list(enumerate(query_set))

def request_batch(items):
    for attempt in range(3):
        retry_delay = 1 << attempt
        request = urllib.request.Request('https://api.osv.dev/v1/querybatch', data=json.dumps({'queries': items}).encode(), headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return json.loads(response.read(2_000_001))
        except urllib.error.HTTPError as error:
            if error.code not in (429, 502, 503, 504) or attempt == 2:
                raise
            if error.headers.get('Retry-After'):
                try:
                    requested_delay = int(error.headers['Retry-After'])
                except ValueError:
                    raise error
                if requested_delay < 0 or requested_delay > 10:
                    raise error
                retry_delay = max(retry_delay, requested_delay)
        except urllib.error.URLError:
            if attempt == 2:
                raise
        print(f'OSV transient network/server failure; bounded retry {attempt + 1}/2.')
        time.sleep(retry_delay)

try:
    for page in range(10):
        payload = request_batch([q for _, q in pending])
        batch = payload.get('results')
        if not isinstance(batch, list) or len(batch) != len(pending):
            raise ValueError('OSV result count mismatch')
        following = []
        for (index, query), result in zip(pending, batch):
            if 'error' in result:
                raise ValueError('OSV query failed')
            results[index]['vulnerabilities'].extend(v['id'] for v in result.get('vulns', []))
            if result.get('next_page_token'):
                following.append((index, {**query, 'page_token': result['next_page_token']}))
        pending = following
        if not pending:
            break
    if pending:
        raise ValueError('OSV pagination incomplete')
except (OSError, ValueError) as error:
    print(f'BLOCKED: OSV Pub audit unavailable/incomplete ({type(error).__name__}); no clearance claimed.')
    raise SystemExit(2) from None
if 'GHSA-r285-q736-9v95' not in results[-1]['vulnerabilities']:
    raise SystemExit('BLOCKED: known-affected Pub positive control was not detected; audit incomplete')
findings = sum(bool(r['vulnerabilities']) for r in results[:-1])
output = {'endpoint': 'https://api.osv.dev/v1/querybatch', 'documentation': 'https://google.github.io/osv.dev/post-v1-querybatch/', 'lock_sha256': hashlib.sha256(lock.read_bytes()).hexdigest(), 'packages': results[:-1], 'positive_control': results[-1], 'packages_with_findings': findings, 'scope': 'OSV-reported known advisories for hosted Pub lock versions only; not a complete supply-chain audit'}
(ROOT / 'reports/evidence/v2-pub-osv.json').write_text(json.dumps(output, indent=2) + '\n')
print(f'Queried {len(queries)} locked public Pub packages; known-affected Pub positive control detected; packages with reported advisories: {findings}. This is feed scope, not security approval.')
raise SystemExit(bool(findings))
