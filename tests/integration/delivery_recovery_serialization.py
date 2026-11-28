#!/usr/bin/env python3
"""Check deterministic HTTP and WSS delivery ordering against a real account reset."""
import concurrent.futures
import hashlib
import json
import os
import subprocess
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

import delivery as d
from account_recovery import mail_token
from directory import establish
from private_blobs import blob, database, postgres


def scalar(db, query):
    return postgres('psql', '-XAtq', '-v', 'ON_ERROR_STOP=1', '-U', 'securemesh',
                    '-d', db, '-c', query, capture_output=True, text=True).stdout.strip()


def wait_for(db, condition, minimum=1):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        count = scalar(db, f'SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND {condition}')
        if int(count) >= minimum:
            return
        time.sleep(.05)
    raise AssertionError(f'PostgreSQL did not report {minimum} matching operations: {condition}')


@contextmanager
def hold_row(db, lock):
    marker = 'securemesh_delivery_' + uuid.uuid4().hex
    local_bin = os.environ.get('SECUREMESH_TEST_PG_BIN')
    command = [str(Path(local_bin)/'psql')] if local_bin else ['docker', 'compose', 'exec', '-T', 'db', 'psql']
    locker = subprocess.Popen(
        [*command, '-XAtq', '-v', 'ON_ERROR_STOP=1', '-U', 'securemesh', '-d', db,
         '-c', f"SET application_name='{marker}'; BEGIN; {lock}; SELECT pg_sleep(25)"],
        cwd=d.ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        wait_for(db, f"application_name='{marker}' AND wait_event='PgSleep'")
        yield
    finally:
        if locker.poll() is None:
            scalar(db, f"""SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                           WHERE datname=current_database() AND application_name='{marker}'""")
        locker.wait(timeout=5)


def newest_code(email, previous=None):
    d.request('/v1/auth/recovery/request', dict(email=email), expected=202)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        code = mail_token(email)
        if code != previous:
            return code
        time.sleep(.1)
    raise AssertionError('New recovery email did not arrive')


def run(db, root):
    sender, receiver = [d.account(root) for _ in range(2)]
    device = sender['device']
    device.pin(receiver['device'])
    receiver['device'].pin(device)
    group = establish(sender, receiver)
    email = sender['username'] + '@securemesh.test'
    first_code = newest_code(email)
    password = 'reset-password-' + uuid.uuid4().hex

    def complete(code, changed_password):
        return d.request('/v1/auth/recovery/complete', dict(token=code, password=changed_password, username=sender['username']), expected=204)

    # Delivery obtains a shared account lock, then waits on the conversation. Reset must wait behind it.
    old_access = sender['session']['accessToken']
    first_message = device.call('queue', group=group, id=str(uuid.uuid4()), text='Delivery linearized before recovery')
    first_stream = d.Stream(old_access, device)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        try:
            with hold_row(db, f"SELECT id FROM conversations WHERE id='{uuid.UUID(group)}' FOR UPDATE"):
                send = pool.submit(first_stream.send, first_message, group)
                wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT epoch,next_seq%'")
                reset = pool.submit(complete, first_code, password)
                wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=$1 FOR UPDATE%'")
            assert send.result(timeout=10).kind == d.wire.DURABLE_ACK
            reset.result(timeout=10)
            ping = first_stream.exchange(d.wire.Frame(protocol_version=1, kind=d.wire.PING))
            assert ping.kind == d.wire.SERVER_ERROR and ping.server_error.code == 401
        finally:
            first_stream.close()

    # Reset holds the account lock while blocked on the old session. HTTP and WSS authenticate
    # against the still-visible old session, then wait on the in-transaction share lock.
    access = d.login(sender['username'], password, device)['accessToken']
    blob_path = f"/v1/conversations/{group}/blobs/{uuid.uuid4()}"
    ciphertext = os.urandom(37)
    blob(blob_path, access, 'PUT', 201, ciphertext)
    assert blob(blob_path, access, 'GET', 200) == ciphertext
    assert blob(blob_path, access, 'GET', 206, extra={'Range':'bytes=2-6'}) == ciphertext[2:7]
    next_code = newest_code(email, previous=first_code)
    message = device.call('queue', group=group, id=str(uuid.uuid4()), text='Recovery won before delivery')
    streams = [d.Stream(access, device) for _ in range(3)]
    sync_frame = d.wire.Frame(protocol_version=1, kind=d.wire.SYNC_REQUEST)
    sync_frame.sync_request.conversation_id = uuid.UUID(group).bytes
    ack_frame = d.wire.Frame(protocol_version=1, kind=d.wire.PROCESSED_ACK)
    ack_frame.processed_ack.conversation_id = uuid.UUID(group).bytes
    ack_frame.processed_ack.highest_contiguous_persisted_sequence = 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=13) as pool:
        try:
            with hold_row(db, f"SELECT id FROM sessions WHERE device_id='{uuid.UUID(device.identity)}' AND NOT revoked FOR UPDATE"):
                reset = pool.submit(complete, next_code, password + '-again')
                wait_for(db, "wait_event_type='Lock' AND query LIKE 'UPDATE sessions SET revoked=true%'")
                http = [
                    pool.submit(d.request, '/v1/messages', d.envelope(message, group), token=access, expected=401),
                    pool.submit(d.request, f'/v1/sync?conversationId={group}', token=access, expected=401),
                    pool.submit(d.request, '/v1/acks', dict(conversationId=group, sequence=1), token=access, expected=401),
                ]
                reads = [pool.submit(blob, blob_path, access, 'GET', 401, extra=headers)
                         for headers in ({}, {'Range': 'bytes=2-6'})]
                upload_path = f"/v1/conversations/{group}/blobs/{uuid.uuid4()}"
                uploads = [
                    pool.submit(blob, upload_path, access, 'PUT', 401, ciphertext),
                    pool.submit(blob, blob_path, access, 'DELETE', 401),
                    pool.submit(blob, blob_path+'/parts', access, 'GET', 401),
                    pool.submit(blob, upload_path+'/parts?offset=0', access, 'PUT', 401, ciphertext,
                                extra={'X-Blob-Length': str(len(ciphertext)), 'X-Blob-SHA256': hashlib.sha256(ciphertext).hexdigest()}),
                ]
                websocket = [
                    pool.submit(streams[0].send, message, group),
                    pool.submit(streams[1].exchange, sync_frame),
                    pool.submit(streams[2].exchange, ack_frame),
                ]
                wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=$1 FOR SHARE%'", 12)
                # The transaction locks only the recovering account. Its peer can still read the group.
                peer = d.request(f'/v1/sync?conversationId={group}', token=receiver['session']['accessToken'])
                assert len(peer['messages']) == 1
            reset.result(timeout=10)
            assert all(operation.result(timeout=10) == {'code': 'AUTH_REQUIRED'} for operation in http)
            for operation in [*reads, *uploads]:
                assert json.loads(operation.result(timeout=10)) == {'code': 'AUTH_REQUIRED'}
            for operation in websocket:
                frame = operation.result(timeout=10)
                assert frame.kind == d.wire.SERVER_ERROR and frame.server_error.code == 401
                assert frame.server_error.stable_code == 'AUTH_REQUIRED'
        finally:
            for stream in streams:
                stream.close()

    assert blob(blob_path, receiver['session']['accessToken'], 'GET', 200) == ciphertext
    blob(upload_path, receiver['session']['accessToken'], 'GET', 404)
    assert scalar(db, f"SELECT count(*) FROM messages WHERE conversation_id='{uuid.UUID(group)}'") == '1'
    assert scalar(db, f"SELECT count(*) FROM cursors WHERE device_id='{uuid.UUID(device.identity)}'") == '0'
    d.sync(receiver['device'], receiver['session']['accessToken'], group)
    assert receiver['device'].call('history', group=group)['events'][0]['id'] == first_message['id']


def main():
    d.BASE = 'https://127.0.0.1:5194'
    mail = {'VerificationEmail__Provider': 'Mailpit', 'VerificationEmail__MailpitPort': '51028'}
    with patch.dict(os.environ, mail), database() as db:
        with d.Server(database=db, legacy_bootstrap=False), tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as scratch:
            run(db, Path(scratch))
    print('PASS delivery-before-reset, reset-before-HTTP/WSS send/sync/ack, and no invalid delivery writes.')


if __name__ == '__main__':
    main()
