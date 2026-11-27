#!/usr/bin/env python3
"""Two real CLI clients exchange sealed files using signed MLS and the HTTPS relay."""
import base64
import os
import subprocess
from contextlib import contextmanager
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import delivery as d
from directory import establish


def blob(route, token, method, expected, data=None, mime='application/octet-stream'):
    headers = {'Content-Type': mime}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(d.BASE + route, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=d.TLS, timeout=30) as response:
            status, body = response.status, response.read()
            if method == 'GET':
                assert response.headers.get_content_type() == 'application/octet-stream'
                assert 'Content-Disposition' not in response.headers
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read()
    assert status == expected, f'{method} expected {expected}, got {status}'
    return body


def postgres(tool, *args, **kwargs):
    # CI uses Compose. A dedicated native PostgreSQL fixture may supply its bin
    # directory and PGHOST/PGPORT using the ordinary libpq environment.
    pg_bin = os.environ.get('SECUREMESH_TEST_PG_BIN')
    cmd = [str(Path(pg_bin) / tool)] if pg_bin else ['docker', 'compose', 'exec', '-T', 'db', tool]
    return subprocess.run([*cmd, *args], cwd=d.ROOT, check=True, **kwargs)


@contextmanager
def database():
    name = 'securemesh_blob_' + uuid.uuid4().hex
    postgres('createdb', '-U', 'securemesh', name)
    try:
        yield name
    finally:
        postgres('dropdb', '-U', 'securemesh', name)


def restore(server, source, restored, sealed, envelope, sentinels):
    with tempfile.TemporaryFile(dir=d.ROOT / '.local') as dump:
        postgres('pg_dump', '-U', 'securemesh', '-d', source, '-Fc', stdout=dump)
        dump.seek(0)
        exported = postgres('pg_restore', '--data-only', '--file=-', stdin=dump, stdout=subprocess.PIPE).stdout
        for raw in sentinels:
            assert all(form not in exported for form in (raw, raw.hex().encode(), base64.b64encode(raw)))
        for ciphertext in (sealed, base64.b64decode(envelope['ciphertext'])):
            assert ciphertext.hex().encode() in exported
        dump.seek(0)
        postgres('pg_restore', '-U', 'securemesh', '-d', restored, '--no-owner', '--exit-on-error', stdin=dump)
    connection = server.env['ConnectionStrings__Database']
    server.env['ConnectionStrings__Database'] = connection.replace('Database=' + source + ';', 'Database=' + restored + ';')
    server.restart()


def quota(group, route, token, sealed, db):
    # Exercise the production quota boundary with small fixture rows in this
    # test's isolated database. An existing upload stays retryable at the cap.
    insert = f"""INSERT INTO private_blobs
        SELECT conversation_id, gen_random_uuid(), owner_id, decode(repeat('00',17),'hex'), digest
        FROM private_blobs CROSS JOIN generate_series(1,1023) WHERE conversation_id='{group}'"""
    postgres('psql', '-U', 'securemesh', '-d', db, '-v', 'ON_ERROR_STOP=1', '-qc', insert)
    extra = f'/v1/conversations/{group}/blobs/{uuid.uuid4()}'
    blob(extra, token, 'PUT', 507, sealed[:17])
    blob(route, token, 'PUT', 204, sealed)
    cleanup = f"DELETE FROM private_blobs WHERE conversation_id='{group}' AND blob_id<>'{route.split('/')[-1]}'"
    postgres('psql', '-U', 'securemesh', '-d', db, '-v', 'ON_ERROR_STOP=1', '-qc', cleanup)
    blob(extra, token, 'PUT', 201, sealed[:17])
    blob(extra, token, 'DELETE', 204)


def verify(a, b, outsider, group, server, source, restored):
    sender, receiver = a['device'], b['device']
    at, bt, ot = [user['session']['accessToken'] for user in (a, b, outsider)]
    tiny_png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP8z/CfgYEBAAoEAgDdrjB4AAAAAElFTkSuQmCC')
    marker = b'SecureMesh private attachment control'
    content = marker + os.urandom(4 * 1024 * 1024 - len(marker))
    for name, media, plain in [('private-control-12345.txt', 'file', content), ('portrait-secret.png', 'photo', tiny_png)]:
        mid = str(uuid.uuid4())
        args = dict(group=group, id=mid, data=base64.b64encode(plain).decode(), name=name, media=media)
        sender.call('attachment_prepare', reject=True, **{**args, 'name': '../escape'})
        staged = sender.call('attachment_prepare', **args)
        assert sender.call('attachment_prepare', **args) == staged
        sender.call('attachment_prepare', reject=True, **{**args, 'name': 'changed'})
        assert staged in sender.call('attachment_pending', group=group)['uploads']
        sealed = base64.b64decode(sender.call('attachment_ciphertext', group=group, id=mid)['ciphertext'])
        assert len(sealed) == len(plain) + 16 == staged['ciphertextBytes']
        assert name.encode() not in sealed and marker not in sealed
        route = f"/v1/conversations/{group}/blobs/{staged['blobId']}"
        blob(route, ot, 'PUT', 403, sealed[:17])
        blob(route, at, 'PUT', 415, sealed[:17], 'text/plain')
        blob(route, at, 'PUT', 201, sealed)
        blob(route, at, 'PUT', 204, sealed)
        corrupt = sealed[:-1] + bytes([sealed[-1] ^ 1])
        blob(route, at, 'PUT', 409, corrupt)
        blob(route, None, 'GET', 401)
        blob(route, ot, 'GET', 403)
        blob(route, bt, 'DELETE', 404)
        sender.call('attachment_queue', reject=True, group=group, id=mid, crash_before_commit=True)
        assert staged in sender.call('attachment_pending', group=group)['uploads']
        envelope = sender.call('attachment_queue', group=group, id=mid)
        assert sender.call('attachment_queue', group=group, id=mid) == envelope
        assert not sender.call('attachment_pending', group=group)['uploads']
        assert name.encode() not in base64.b64decode(envelope['ciphertext'])
        saved = d.request('/v1/messages', d.envelope(envelope, group), token=at)
        sender.call('saved', group=group, id=mid, seq=saved['serverSequence'])
        if media == 'file':
            quota(group, route, at, sealed, source)
            restore(server, source, restored, sealed, envelope, [marker, name.encode()])
        else:
            server.restart()
        d.sync(receiver, bt, group)
        event = next(e for e in receiver.call('timeline', group=group)['messages'] if e['id'] == mid)
        assert event['attachment'] == dict(name=name, media=media, size=len(plain), blobId=staged['blobId'])
        received = blob(route, bt, 'GET', 200)
        assert received == sealed
        receiver.call('attachment_open', reject=True, group=group, id=mid, ciphertext=base64.b64encode(corrupt).decode())
        opened = receiver.call('attachment_open', group=group, id=mid, ciphertext=base64.b64encode(received).decode())
        assert opened['name'] == name and base64.b64decode(opened['data']) == plain
        blob(route, at, 'DELETE', 204)
        blob(route, bt, 'GET', 404)
    args = dict(group=group, id=str(uuid.uuid4()), name='cancelled.bin', media='file')
    sender.call('attachment_prepare', reject=True, data='', **args)
    sender.call('attachment_prepare', reject=True, data=base64.b64encode(bytes(4194305)).decode(), **args)
    sender.call('attachment_prepare', data='YQ==', **args)
    assert sender.call('attachment_cancel', group=group, id=args['id'])['cancelled']
    sender.call('attachment_queue', reject=True, group=group, id=args['id'])
    print('PASS: independent SQLCipher clients; signed MLS conversation; 4 MiB file and PNG; opaque HTTPS upload, quota, dedup/conflict, membership, sender removal; actual pg_dump/restore and original recipient decryption; restart/crash recovery; altered ciphertext rejected; plaintext restored exactly.')


def main():
    d.BASE = 'https://127.0.0.1:5102'
    with database() as source, database() as restored:
        with d.Server(database=source, legacy_bootstrap=False) as server, tempfile.TemporaryDirectory(dir=d.ROOT / '.local') as tmp:
            a, b, outsider = [d.account(Path(tmp)) for _ in range(3)]
            a['device'].pin(b['device'])
            b['device'].pin(a['device'])
            verify(a, b, outsider, establish(a, b), server, source, restored)


if __name__ == '__main__':
    main()
