#!/usr/bin/env python3
"""Non-disruptive V2 pg_dump/isolated restore, real routed DM and original MLS recipient."""
import base64
import subprocess
import tempfile
import uuid
from pathlib import Path

import delivery as d
from directory import establish
from private_blobs import database, postgres
from delivery_recovery_serialization import scalar


def main():
    d.BASE = 'https://127.0.0.1:5099'
    with database() as source_db, database() as restored, \
            d.Server(database=source_db, legacy_bootstrap=False) as server, \
            tempfile.TemporaryDirectory(prefix='securemesh-restore-v2-', dir=d.ROOT / '.local') as tmp:
        root = Path(tmp)
        a, b = [d.account(root) for _ in range(2)]
        a['device'].pin(b['device']); b['device'].pin(a['device'])
        group = establish(a, b)
        sentinel = 'private-restore-fixture-' + uuid.uuid4().hex
        message = a['device'].call('queue', group=group, id=str(uuid.uuid4()), text=sentinel)
        saved = d.request('/v1/messages', d.envelope(message, group), token=a['session']['accessToken'])
        assert saved['durable'] and saved['serverSequence'] == 1
        assert not b['device'].call('history', group=group)['events']
        owner = a['session']['accessToken']
        peer = b['session']['accessToken']
        owner_profile = '/v1/users/me/profile-text'
        private_bio = {'bio': 'Backup visibility fixture', 'status': None, 'revision': 0, 'visibleToPeers': False}
        d.request(owner_profile+'/with-visibility', private_bio, token=owner, method='PUT')
        d.request('/v1/contact-blocks/'+b['username'], token=owner, method='PUT', expected=204)
        room = str(uuid.uuid4())
        base = '/v1/public-channels'
        d.request(base+'/invite-only', {'id': room, 'slug': 'room_'+room[:8], 'title':'Restore fixture'}, token=owner, expected=201)
        posts = base+'/'+room+'/posts'
        post = {'requestId': str(uuid.uuid4()), 'body': 'Retained post'}
        sequence = d.request(posts, post, token=owner, expected=201)['seq']
        comments = posts+'/'+str(sequence)+'/comments'
        comment = {'requestId': str(uuid.uuid4()), 'body': 'Retained comment'}
        comment_id = d.request(comments, comment, token=owner, expected=201)['id']
        migrations = """SELECT string_agg("MigrationId", ',' ORDER BY "MigrationId") FROM "__EFMigrationsHistory" """
        source_migrations = scalar(source_db, migrations)
        assert source_migrations
        backup = root / 'backup.dump'
        with backup.open('wb') as output:
            postgres('pg_dump', '-U', 'securemesh', '-d', source_db, '-Fc', stdout=output)
        # Scan decoded table data, since a compressed archive alone would hide
        # plaintext too. Never copy the SQL or credentials into test logs.
        marker = sentinel.encode('ascii')
        with backup.open('rb') as source:
            exported = postgres('pg_restore', '--data-only', '--file=-', stdin=source, stdout=subprocess.PIPE).stdout
        for representation in (marker, marker.hex().encode('ascii'), base64.b64encode(marker)):
            assert representation not in exported, 'Private fixture found in server table data'
        ciphertext_hex = base64.b64decode(message['ciphertext'], validate=True).hex()
        assert ciphertext_hex.encode('ascii') in exported, 'Dump missing original MLS ciphertext'
        with backup.open('rb') as source:
            postgres('pg_restore', '-U', 'securemesh', '-d', restored, '--no-owner', '--exit-on-error', stdin=source)
        assert scalar(restored, migrations) == source_migrations
        assert scalar(restored, f"SELECT count(*) FROM messages WHERE conversation_id='{group}'") == '1'
        assert scalar(restored, f"SELECT count(*) FROM outbox o JOIN messages m ON m.id=o.message_id WHERE m.conversation_id='{group}'") == '1'
        server.env['ConnectionStrings__Database'] = server.env['ConnectionStrings__Database'].replace('Database=' + source_db + ';', 'Database=' + restored + ';')
        server.restart()
        assert d.request(owner_profile, token=owner) == {**private_bio, 'revision': 1}
        assert d.request('/v1/contact-blocks', token=owner) == {'items': [b['username']]}
        peer_fields = f"/v1/conversations/{group}/profile-text/{a['device'].identity}"
        assert d.request(peer_fields, token=peer) == {'bio':None, 'status':None}
        assert d.request(posts, post, token=owner)['seq'] == sequence
        assert d.request(comments, comment, token=owner)['id'] == comment_id
        assert [row['body'] for row in d.request(comments, token=owner)['items']] == [comment['body']]
        d.request(comments, token=peer, expected=404)
        conversations = d.request('/v1/conversations', token=b['session']['accessToken'])
        assert any(c['id'] == group for c in conversations)
        restored_session = d.login(b['username'], b['password'], b['device'])
        assert restored_session['trustState'] == 'DEVICE_TRUSTED'
        d.sync(b['device'], restored_session['accessToken'], group, limit=1)
        events = b['device'].call('history', group=group)['events']
        assert len(events) == 1 and events[0]['id'] == message['id'] and events[0]['text'] == sentinel
        assert b['device'].call('cursor', group=group)['seq'] == 1
        assert scalar(restored, f"SELECT seq FROM cursors WHERE conversation_id='{group}' AND device_id='{b['device'].identity}'") == '1'
        print('PASS: complete migration history, consented KeyPackage/Welcome DM and durable message/outbox restored into an isolated database; API login/session/DM listing and original SQLCipher/OpenMLS recipient decrypt/cursor/receipt work. Restored profile privacy and block settings, restricted channel post/comment access and retry identities; original source was an isolated fixture.')


if __name__ == '__main__':
    main()
