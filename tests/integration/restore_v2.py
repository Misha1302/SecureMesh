#!/usr/bin/env python3
"""Non-disruptive V2 pg_dump/isolated restore, real routed DM and original MLS recipient."""
import base64
import subprocess
import tempfile
import uuid
from pathlib import Path

import delivery as d
from directory import establish
from recovery import compose, scalar


def main():
    d.BASE = 'https://127.0.0.1:5099'
    restored = 'securemesh_restore_v2_' + uuid.uuid4().hex[:12]
    created = False
    try:
        with d.Server(legacy_bootstrap=False) as server, tempfile.TemporaryDirectory(prefix='securemesh-restore-v2-', dir=d.ROOT / '.local') as tmp:
            root = Path(tmp)
            a, b = [d.account(root) for _ in range(2)]
            a['device'].pin(b['device']); b['device'].pin(a['device'])
            group = establish(a, b)
            sentinel = 'private-restore-fixture-' + uuid.uuid4().hex
            message = a['device'].call('queue', group=group, id=str(uuid.uuid4()), text=sentinel)
            saved = d.request('/v1/messages', d.envelope(message, group), token=a['session']['accessToken'])
            assert saved['durable'] and saved['serverSequence'] == 1
            assert not b['device'].call('history', group=group)['events']
            backup = root / 'backup.dump'
            with backup.open('wb') as output:
                subprocess.run(['docker', 'compose', 'exec', '-T', 'db', 'pg_dump', '-U', 'securemesh', '-d', 'securemesh', '-Fc'], cwd=d.ROOT, stdout=output, check=True)
            # Scan decoded table data, since a compressed archive alone would hide
            # plaintext too. Never copy the SQL or credentials into test logs.
            marker = sentinel.encode('ascii')
            with backup.open('rb') as source:
                exported = compose('exec', '-T', 'db', 'pg_restore', '--data-only',
                                   '--file=-', stdin=source).stdout
            for representation in (marker, marker.hex().encode('ascii'), base64.b64encode(marker)):
                assert representation not in exported, 'Private fixture found in server table data'
            ciphertext_hex = base64.b64decode(message['ciphertext'], validate=True).hex()
            assert ciphertext_hex.encode('ascii') in exported, 'Dump missing original MLS ciphertext'
            compose('exec', '-T', 'db', 'createdb', '-U', 'securemesh', restored); created = True
            with backup.open('rb') as source:
                subprocess.run(['docker', 'compose', 'exec', '-T', 'db', 'pg_restore', '-U', 'securemesh', '-d', restored, '--no-owner', '--exit-on-error'], cwd=d.ROOT, stdin=source, check=True)
            assert scalar('SELECT count(*) FROM "__EFMigrationsHistory"', restored) == '7'
            assert scalar(f"SELECT count(*) FROM messages WHERE conversation_id='{group}'", restored) == '1'
            assert scalar(f"SELECT count(*) FROM outbox o JOIN messages m ON m.id=o.message_id WHERE m.conversation_id='{group}'", restored) == '1'
            server.env['ConnectionStrings__Database'] = server.env['ConnectionStrings__Database'].replace('Database=securemesh;', 'Database=' + restored + ';')
            server.restart()
            conversations = d.request('/v1/conversations', token=b['session']['accessToken'])
            assert any(c['id'] == group for c in conversations)
            restored_session = d.login(b['username'], b['password'], b['device'])
            assert restored_session['trustState'] == 'DEVICE_TRUSTED'
            d.sync(b['device'], restored_session['accessToken'], group, limit=1)
            events = b['device'].call('history', group=group)['events']
            assert len(events) == 1 and events[0]['id'] == message['id'] and events[0]['text'] == sentinel
            assert b['device'].call('cursor', group=group)['seq'] == 1
            assert scalar(f"SELECT seq FROM cursors WHERE conversation_id='{group}' AND device_id='{b['device'].identity}'", restored) == '1'
            print('PASS: actual V2 schema with seven migrations, consented KeyPackage/Welcome DM and durable message/outbox restored into an isolated database; API login/session/DM listing and original SQLCipher/OpenMLS recipient decrypt/cursor/receipt work. Source DB remained available. Object/media restore not covered.')
    finally:
        if created:
            compose('exec', '-T', 'db', 'dropdb', '-U', 'securemesh', restored)


if __name__ == '__main__':
    main()
