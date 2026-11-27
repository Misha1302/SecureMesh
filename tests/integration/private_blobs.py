#!/usr/bin/env python3
"""Two real CLI clients exchange sealed files using signed MLS and the HTTPS relay."""
import base64
import hashlib
import json
import socket
import os
import subprocess
from contextlib import contextmanager
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import delivery as d
from directory import establish
from process_spike import PersistentDevice


def blob(route, token, method, expected, data=None, mime='application/octet-stream', extra=None):
    headers = {'Content-Type': mime, **(extra or {})}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(d.BASE + route, data=data, method=method, headers=headers)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, context=d.TLS, timeout=30) as response:
                status, body = response.status, response.read()
                if method == 'GET' and not route.endswith('/parts'):
                    assert response.headers.get_content_type() == 'application/octet-stream'
                    assert 'Content-Disposition' not in response.headers
        except urllib.error.HTTPError as error:
            status, body = error.code, error.read()
        if status != 429 or expected == 429 or attempt == 3:
            break
        time.sleep(10)
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


CHUNK = 32768


def resumable_upload(route, owner, member, outsider, sealed, server, source):
    status = route + '/parts'
    digest = hashlib.sha256(sealed).hexdigest()
    headers = {'X-Blob-Length': str(len(sealed)), 'X-Blob-SHA256': digest}

    def put(offset, code=200, content=None):
        part = sealed[offset:offset+CHUNK] if content is None else content
        raw = blob(f'{status}?offset={offset}', owner, 'PUT', code, part, extra=headers)
        if code == 200:
            return json.loads(raw)

    def position(token, code=200):
        raw = blob(status, token, 'GET', code)
        if code == 200:
            return json.loads(raw)

    position(owner, 404)
    put(CHUNK, 409)
    assert put(0) == dict(offset=CHUNK, complete=False, digest=digest)
    assert put(0)['offset'] == CHUNK
    put(0, 409, bytes(CHUNK))
    position(member, 404)
    position(outsider, 403)
    blob(route, member, 'GET', 404)
    blob(route, member, 'DELETE', 404)
    # A stage reserves the full declared size and one slot against legacy and new writes.
    group = route.split('/')[3]
    fill = f"""INSERT INTO private_blobs
        SELECT conversation_id,gen_random_uuid(),owner_id,decode(repeat('00',17),'hex'),digest
        FROM private_blob_uploads CROSS JOIN generate_series(1,1023) WHERE conversation_id='{group}'"""
    postgres('psql', '-U','securemesh','-d',source,'-qc',fill)
    extra = f'/v1/conversations/{group}/blobs/{uuid.uuid4()}'
    blob(extra, owner, 'PUT', 507, sealed[:17])
    blob(extra+'/parts?offset=0',owner,'PUT',507,sealed[:CHUNK],extra=headers)
    postgres('psql', '-U','securemesh','-d',source,'-qc',f"DELETE FROM private_blobs WHERE conversation_id='{group}'")

    # Fifteen reserved objects consume 60 MiB + tag bytes despite having tiny prefixes.
    reserve = f"""INSERT INTO private_blob_uploads
        SELECT conversation_id,gen_random_uuid(),owner_id,4194304,digest,prefix,expires_at
        FROM private_blob_uploads CROSS JOIN generate_series(1,14) WHERE conversation_id='{group}'"""
    postgres('psql','-U','securemesh','-d',source,'-qc',reserve)
    blob(extra+'/parts?offset=0',owner,'PUT',507,sealed[:CHUNK],extra=headers)
    expire = f"""UPDATE private_blob_uploads SET expires_at=now()-interval '1 second'
        WHERE conversation_id='{group}' AND blob_id<>'{route.split('/')[-1]}'"""
    postgres('psql','-U','securemesh','-d',source,'-qc',expire)
    blob(extra+'/parts?offset=0',owner,'PUT',200,sealed[:CHUNK],extra=headers)
    blob(extra,owner,'DELETE',204)
    blob(extra+'/parts',owner,'GET',404)
    # Terminate a real TLS request halfway through a chunk. No partial body is accepted.
    with socket.create_connection(('127.0.0.1', 5102)) as sock, d.TLS.wrap_socket(sock, server_hostname='127.0.0.1') as tls:
        request = (f'PUT {status}?offset={CHUNK} HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                   f'Authorization: Bearer {owner}\r\nContent-Type: application/octet-stream\r\n'
                   f'Content-Length: {CHUNK}\r\nX-Blob-Length: {len(sealed)}\r\nX-Blob-SHA256: {digest}\r\n\r\n')
        tls.sendall(request.encode() + sealed[CHUNK:CHUNK+71])
    server.restart()
    assert position(owner)['offset'] == CHUNK
    for offset in range(CHUNK, len(sealed), CHUNK):
        if offset + CHUNK >= len(sealed):
            put(offset,409, bytes([sealed[offset] ^ 1]) + sealed[offset+1:])
        ack = put(offset)
        assert ack['offset'] == min(offset+CHUNK,len(sealed))
    assert ack['complete'] and position(owner) == ack
    assert put(0) == ack


def resumable_download(receiver, group, mid, route, token, sealed):
    args = dict(group=group,id=mid)
    assert receiver.call('attachment_download_prefix',**args)['ciphertext'] == ''
    session = PersistentDevice.wrap(receiver)
    try:
        for offset in range(0,len(sealed),CHUNK):
            end = min(len(sealed),offset+CHUNK)
            part = blob(route,token,'GET',206,extra={'Range':f'bytes={offset}-{end-1}'})
            assert part == sealed[offset:end]
            checkpoint = session.call('attachment_download_part', **args,offset=offset,ciphertext=base64.b64encode(part).decode())
            assert checkpoint['offset'] == end
            if end == CHUNK:
                session.close()
                session = PersistentDevice.wrap(receiver)
                prefix = session.call('attachment_download_prefix',**args)
                assert base64.b64decode(prefix['ciphertext']) == sealed[:end]
        return base64.b64decode(session.call('attachment_download_prefix',**args)['ciphertext'])
    finally:
        session.close()


def dart_transfer(receiver, group, mid, blob_id, route, token, sealed, clear):
    dart = Path(os.environ.get('SECUREMESH_TEST_DART', d.ROOT / '.local/flutter/bin/dart'))
    if not dart.is_file():
        print('Dart transfer trial skipped: local Dart SDK unavailable.')
        return
    library = d.ROOT / 'src/crypto_core/target/debug/libsecuremesh_crypto.so'
    extra = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(dir=d.ROOT / '.local') as tmp:
        folder = Path(tmp)
        binary = folder / 'opaque.bin'
        binary.write_bytes(sealed)
        fixture = folder / 'trial.json'
        fixture.write_text(json.dumps(dict(library=str(library), database=str(receiver.path),
            passphrase=receiver.password, endpoint=d.BASE, token=token, group=group, message=mid,
            extra=extra, blob=blob_id, sealed=str(binary), clearDigest=hashlib.sha256(clear).hexdigest())))
        fixture.chmod(0o600)
        for phase in ('interrupt','resume'):
            subprocess.run([str(dart),'run','tool/attachment_resume_trial.dart',str(fixture),phase],
                cwd=d.ROOT / 'apps/client_flutter', check=True, timeout=150,
                env={**os.environ, 'SECUREMESH_CERT_FILE':str(d.ROOT / '.local/tls.pem'),
                     'FLUTTER_SUPPRESS_ANALYTICS':'true', 'DART_SUPPRESS_ANALYTICS':'true'})
    blob(route.rsplit('/',1)[0]+'/'+extra,token,'DELETE',204)
    print('PASS: two separate Dart VMs used SessionBlobs, native SQLCipher FFI and HTTPS; restarted both transfers at 32768; original plaintext digest verified.')


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
        if media == 'file':
            resumable_upload(route, at, bt, ot, sealed, server, source)
        else:
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
        if media == 'file':
            dart_transfer(receiver, group, mid, staged['blobId'], route, bt, sealed, plain)
        received = (resumable_download(receiver, group, mid, route, bt, sealed)
                    if media == 'file' else blob(route, bt, 'GET', 200))
        assert received == sealed
        receiver.call('attachment_open', reject=True, group=group, id=mid, ciphertext=base64.b64encode(corrupt).decode())
        opened = receiver.call('attachment_open', group=group, id=mid, ciphertext=base64.b64encode(received).decode())
        assert receiver.call('attachment_download_prefix',group=group,id=mid)['ciphertext'] == ''
        assert opened['name'] == name and base64.b64decode(opened['data']) == plain
        blob(route, at, 'DELETE', 204)
        blob(route, bt, 'GET', 404)
    args = dict(group=group, id=str(uuid.uuid4()), name='cancelled.bin', media='file')
    sender.call('attachment_prepare', reject=True, data='', **args)
    sender.call('attachment_prepare', reject=True, data=base64.b64encode(bytes(4194305)).decode(), **args)
    sender.call('attachment_prepare', data='YQ==', **args)
    assert sender.call('attachment_cancel', group=group, id=args['id'])['cancelled']
    sender.call('attachment_queue', reject=True, group=group, id=args['id'])
    print('PASS: independent SQLCipher clients; signed MLS conversation; 4 MiB file and PNG; TLS mid-chunk disconnect + server restart, resumed upload and range download across client restart, staged quota, dedup/conflict, membership, sender removal; actual pg_dump/restore and original recipient decryption; restart/crash recovery; altered ciphertext rejected; plaintext restored exactly.')


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
