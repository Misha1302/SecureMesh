#!/usr/bin/env python3
"""Abrupt native producer exit, then replay 1,000 local envelopes through the real API."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import uuid

import delivery as d
from directory import establish
from private_blobs import database, postgres
from process_spike import BIN, PersistentDevice


COUNT = 1000
DEADLINE_SECONDS = 180
DRIVER = 'apps/client_flutter/tool/offline_backlog.dart'
API = 'src/SecureMesh.Api/bin/Debug/net10.0/SecureMesh.Api.dll'
LIBRARY = 'src/crypto_core/target/debug/libsecuremesh_crypto.so'


def rows(db, group):
    statement = (
        "SELECT coalesce(json_agg(json_build_array(client_id,device_id,epoch,kind,seq) ORDER BY seq),'[]') "
        f"FROM messages WHERE conversation_id='{uuid.UUID(group)}'"
    )
    return json.loads(query(db, statement))


def query(db, statement):
    return postgres('psql', '-U', 'securemesh', '-d', db, '-v', 'ON_ERROR_STOP=1',
                    '-Atc', statement, capture_output=True, text=True).stdout.strip()


def fixture_text(ordinal):
    return f'Offline backlog №{ordinal} • Привет 🌍'


def verify_ids(expected, actual):
    missing = len(set(expected) - set(actual))
    unexpected = len(set(actual) - set(expected))
    duplicates = sum(count - 1 for count in Counter(actual).values())
    return dict(missing=missing, unexpected=unexpected, duplicates=duplicates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=d.ROOT/'reports/evidence/native-offline-backlog.json')
    args = parser.parse_args()
    d.BASE = os.environ.get('SECUREMESH_TEST_URLS', 'https://127.0.0.1:5295')
    with database() as db, d.Server(db, legacy_bootstrap=False), tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        sender, recipient = [d.account(root) for _ in range(2)]
        a, b = sender['device'], recipient['device']
        a.pin(b)
        b.pin(a)
        group = establish(sender, recipient)
        ids = [str(uuid.uuid4()) for _ in range(COUNT)]
        producer = PersistentDevice.wrap(a)
        samples = []
        start = time.monotonic()
        try:
            for ordinal, identity in enumerate(ids):
                message = producer.call('queue', group=group, id=identity, text=fixture_text(ordinal))
                assert message['id'] == identity and message['kind'] == 1
                if ordinal == 0:
                    epoch = message['epoch']
                assert message['epoch'] == epoch
                if ordinal in (0, COUNT//2, COUNT-1):
                    samples.append(message)
            queue_seconds = time.monotonic() - start
        finally:
            producer.process.kill()
            producer.process.wait(timeout=10)
            for stream in (producer.process.stdin, producer.process.stdout, producer.process.stderr):
                stream.close()
        assert producer.process.returncode == -signal.SIGKILL
        assert rows(db, group) == []
        assert b.call('cursor', group=group)['seq'] == 0

        result_path = root/'result.json'
        fixture = root/'fixture.json'
        fixture.touch(mode=0o600)
        fixture.write_text(json.dumps({
            'endpoint': d.BASE, 'group': group, 'epoch': epoch, 'ids': ids,
            'output': str(result_path), 'cert': str(d.ROOT/'.local/tls.pem'),
            'library': str(d.ROOT/LIBRARY),
            'devices': [
                {'id': user['device'].identity, 'path': str(user['device'].path),
                 'passphrase': user['device'].password, 'session': user['session']}
                for user in (sender, recipient)
            ],
        }))
        cli = d.ROOT/'.local/flutter/bin/dart'
        with (root/'dart.stderr').open('w+') as errors:
            replay = subprocess.run(
                [str(cli), 'run', 'tool/offline_backlog.dart', str(fixture)],
                cwd=d.ROOT/'apps/client_flutter',
                env={**os.environ, 'PUB_CACHE': str(d.ROOT/'.local/pub-cache')},
                stdout=subprocess.DEVNULL, stderr=errors, timeout=DEADLINE_SECONDS+30,
            )
            if replay.returncode:
                errors.seek(0)
                raise RuntimeError('Native replay failed: '+errors.read())
        result = json.loads(result_path.read_text())
        assert result['count'] == COUNT and result['elapsed_seconds'] <= DEADLINE_SECONDS
        assert len(result['recipient_committed_latencies_seconds']) == COUNT
        assert result['recipient_nonempty_sync_pages'] >= 2
        assert result['recipient_continued_sync_pages'] >= 1

        persisted = rows(db, group)
        server_counts = verify_ids(ids, [row[0] for row in persisted])
        assert not any(server_counts.values()), server_counts
        assert all(row[1:] == [a.identity, epoch, 1, index]
                   for index, row in enumerate(persisted, 1))
        seq_by_id = {row[0]: row[4] for row in persisted}
        retry = d.Stream(sender['session']['accessToken'], a)
        try:
            for sample in samples:
                ack = retry.send(sample, group)
                assert ack.kind == d.wire.DURABLE_ACK
                assert ack.durable_ack.server_sequence == seq_by_id[sample['id']]
        finally:
            retry.close()
        assert rows(db, group) == persisted

        events = b.call('history', group=group)['events']
        receiver_counts = verify_ids(ids, [event['id'] for event in events])
        assert not any(receiver_counts.values()), receiver_counts
        texts_by_id = {identity: fixture_text(index) for index, identity in enumerate(ids)}
        assert [event['id'] for event in events] == [row[0] for row in persisted]
        assert all(event['text'] == texts_by_id[event['id']] for event in events)
        assert a.call('outbox_pending')['pending'] is False
        assert b.call('cursor', group=group)['seq'] == COUNT
        receipt = query(db, f"SELECT seq FROM cursors WHERE device_id='{uuid.UUID(b.identity)}' "
                            f"AND conversation_id='{uuid.UUID(group)}'")
        assert receipt == str(COUNT)

        result.update(
            outcome='pass', platform='Linux native Dart / OpenMLS / SQLCipher',
            link='loopback TLS with no imposed rate, delay or loss', server_rows_before_replay=0,
            offline_queue_seconds=queue_seconds, producer_exit_code=producer.process.returncode,
            replay_exit_code=replay.returncode, sender_outbox_pending=False,
            server_ids=server_counts, recipient_ids=receiver_counts,
            recipient_cursor_sequence=COUNT, server_processed_receipt=int(receipt),
            repeated_immutable_sends=len(samples), duplicate_server_rows_after_resend=0,
            source_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=d.ROOT, text=True).strip(),
            sha256={str(path): hashlib.file_digest((d.ROOT/path).open('rb'), 'sha256').hexdigest()
                    for path in (API, LIBRARY, BIN.relative_to(d.ROOT), DRIVER,
                                 Path(__file__).relative_to(d.ROOT),
                                 'apps/client_flutter/lib/delivery_client.dart',
                                 'apps/client_flutter/lib/transport.dart')},
        )
        args.output.write_text(json.dumps(result, indent=2)+'\n')
        print(f"PASS native offline replay: {COUNT} IDs, {result['elapsed_seconds']:.3f}s, "
              f"p95 {result['recovery_p95_seconds']:.3f}s, "
              f"{result['recipient_nonempty_sync_pages']} pages, no missing or duplicate IDs")


if __name__ == '__main__':
    main()
