#!/usr/bin/env python3
"""Check actual make-demo startup path, not only health or the test Server helper."""
import tempfile
import time
import uuid
from pathlib import Path
import delivery as d
from directory import establish

d.BASE = 'https://127.0.0.1:5088'
for attempt in range(60):
    try:
        d.request('/health/ready')
        break
    except OSError:
        time.sleep(.5)
else:
    raise RuntimeError('Actual make-demo TLS readiness timed out')
with tempfile.TemporaryDirectory(prefix='securemesh-demo-check-', dir=d.ROOT / '.local') as tmp:
    a, b = [d.account(Path(tmp)) for _ in range(2)]
    a['device'].pin(b['device']); b['device'].pin(a['device'])
    group = establish(a, b)
    message = a['device'].call('queue', group=group, id=str(uuid.uuid4()), text='Actual make-demo routed MLS fixture')
    saved = d.request('/v1/messages', d.envelope(message, group), token=a['session']['accessToken'])
    assert saved['durable']
    d.sync(b['device'], b['session']['accessToken'], group)
    history = b['device'].call('history', group=group)['events']
    assert len(history) == 1 and history[0]['id'] == message['id'] and history[0]['text'] == 'Actual make-demo routed MLS fixture'
    print('PASS: actual make demo process validates real KeyPackage, routes signed Welcome, commits encrypted message and original recipient decrypts via TLS/PG; no test Server cwd assumption.')
