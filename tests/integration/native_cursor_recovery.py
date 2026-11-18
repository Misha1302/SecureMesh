#!/usr/bin/env python3
"""Real 60-second both-transport blackout, 1000 MLS events, production Dart recovery."""
import hashlib
import json
import os
import selectors
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

import delivery as d
from directory import establish
from native_transport import FaultProxy
from process_spike import PersistentDevice
from recovery import scalar


def main():
    d.BASE = 'https://127.0.0.1:5095'
    with d.Server(legacy_bootstrap=False), tempfile.TemporaryDirectory(prefix='securemesh-native-cursor-', dir=d.ROOT / '.local') as tmp:
        root = Path(tmp)
        a, b = [d.account(root) for _ in range(2)]
        a['device'].pin(b['device']); b['device'].pin(a['device'])
        group = establish(a, b)
        mode = root / 'mode'; mode.write_text('pass')
        proxy = FaultProxy(mode)
        output = d.ROOT / 'reports/evidence/native-cursor-recovery.json'
        ids = [str(uuid.uuid4()) for _ in range(1000)]
        fixture = root / 'fixture.json'
        fixture.write_text(json.dumps(dict(endpoint=f'https://127.0.0.1:{proxy.port}', group=group, mode=str(mode), output=str(output), cert=str(d.ROOT / '.local/tls.pem'), library=str(d.ROOT / 'src/crypto_core/target/debug/libsecuremesh_crypto.so'), device=b['device'].identity, path=str(b['device'].path), passphrase=b['device'].password, session=b['session'], ids=ids)))
        fixture.chmod(0o600)
        process = None
        sender = PersistentDevice.wrap(a['device'])
        stream = d.Stream(a['session']['accessToken'], a['device'])
        try:
            with (root / 'dart.stderr').open('w') as errors:
                process = subprocess.Popen([str(d.ROOT / '.local/flutter/bin/dart'), 'run', 'tool/cursor_recovery.dart', str(fixture)], cwd=d.ROOT / 'apps/client_flutter', env={**os.environ, 'PUB_CACHE': str(d.ROOT / '.local/pub-cache')}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
                ready = selectors.DefaultSelector(); ready.register(process.stdout, selectors.EVENT_READ)
                if not ready.select(timeout=60) or process.stdout.readline().strip() != 'WARM_READY':
                    raise RuntimeError('Native cursor startup failed: ' + (root / 'dart.stderr').read_text())
                mode.write_text('offline'); started = time.monotonic()
                process.stdin.write('RUN\n'); process.stdin.flush()
                for index, identity in enumerate(ids):
                    message = sender.call('queue', group=group, id=identity, text=f'Cursor recovery fixture {index}')
                    ack = stream.send(message, group)
                    assert ack.kind == d.wire.DURABLE_ACK
                    sender.call('saved', group=group, id=identity, seq=ack.durable_ack.server_sequence)
                offered = time.monotonic() - started
                if offered >= 60:
                    raise RuntimeError(f'1000-event setup exceeded blackout window: {offered:.3f}s')
                time.sleep(max(0, 60 - offered))
                duration = time.monotonic() - started
                mode.write_text('pass')
                stdout, _ = process.communicate(timeout=300)
                if stdout: print(stdout.strip(), flush=True)
                if process.returncode:
                    raise RuntimeError(f'Native cursor recovery failed {process.returncode}: ' + (root / 'dart.stderr').read_text())
                assert proxy.dropped > 0, 'No network outage was injected'
                recovered = json.loads(output.read_text())
                assert recovered['ids'] == ids and recovered['received_during_blackout'] == 0
                # Verify independently after closing/reopening the native store.
                assert b['device'].call('cursor', group=group)['seq'] == 1000
                assert [e['id'] for e in b['device'].call('history', group=group)['events']] == ids
                # Receipt can only follow local durable ingest; it must reach the real DB.
                recipient_id, conversation_id = str(uuid.UUID(b['device'].identity)), str(uuid.UUID(group))
                receipt = scalar(f"SELECT seq FROM cursors WHERE device_id='{recipient_id}' AND conversation_id='{conversation_id}'")
                assert receipt == '1000', f'Actual persisted processed receipt mismatch: {receipt}'
                recovered.update(blackout_seconds=duration, sender_finished_seconds=offered, dropped_transport_bytes=proxy.dropped, source_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=d.ROOT, text=True).strip(), source_sha256={name: hashlib.sha256((d.ROOT / name).read_bytes()).hexdigest() for name in ['apps/client_flutter/lib/delivery_client.dart', 'apps/client_flutter/lib/transport.dart', 'apps/client_flutter/tool/cursor_recovery.dart']})
                output.write_text(json.dumps(recovered, indent=2) + '\n')
                print(f'PASS: actual {duration:.3f}s blackout blocked WSS and HTTPS, all 1000 ordered IDs recovered, cursor/receipt=1000 and reopened SQLCipher state verified.', flush=True)
        finally:
            if process and process.poll() is None:
                process.terminate(); process.wait(timeout=10)
            stream.close(); sender.close(); proxy.close()


if __name__ == '__main__':
    main()
