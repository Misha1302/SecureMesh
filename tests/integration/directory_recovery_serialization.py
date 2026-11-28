#!/usr/bin/env python3
"""Verify that requests admitted before a reset cannot change the MLS invitation lifecycle afterward."""
import concurrent.futures
import os
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch

import delivery as d
from delivery_recovery_serialization import hold_row, newest_code, scalar, wait_for
from private_blobs import database


def access(account):
    return account['session']['accessToken']


def invite(sender, recipient):
    invitation = str(uuid.uuid4())
    d.request('/v1/chat-requests', dict(id=invitation, username=recipient['username']),
              token=access(sender), expected=201)
    return invitation


def prepare(sender, recipient):
    invitation = invite(sender, recipient)
    sender_device, recipient_device = sender['device'], recipient['device']
    recipient_device.call('directory_consent', invitation=invitation, sender=sender_device.identity,
                          senderKey=sender_device.public, username=sender['username'], confirmed=True)
    package = recipient_device.call('directory_consent_package', invitation=invitation)
    d.request('/v1/crypto/keypackages', dict(payload=package['keypackage'], invitationId=invitation),
              token=access(recipient), expected=201)
    d.request(f'/v1/chat-requests/{invitation}/accept', {}, token=access(recipient), expected=204)
    lease = str(uuid.uuid4())
    allocated = d.request('/v1/crypto/keypackages/lease', dict(invitationId=invitation, requestId=lease),
                          token=access(sender))
    return sender_device.call('directory_prepare', invitation=invitation, lease=lease,
                              recipient=recipient_device.identity, reference=allocated['reference'],
                              keypackage=allocated['keypackage'])


def run(db, root):
    account, peer = [d.account(root) for _ in range(2)]
    account['device'].pin(peer['device'])
    peer['device'].pin(account['device'])
    waiting = prepare(account, peer)
    incoming = prepare(peer, account)
    d.request('/v1/conversations/establish', incoming, token=access(peer), expected=201)
    pending = invite(peer, account)
    dismissible = invite(peer, account)
    newest = str(uuid.uuid4())
    publication = account['device'].call('keypackage')['keypackage']
    device = uuid.UUID(account['device'].identity)
    packages_before = scalar(db, f"SELECT count(*) FROM key_packages WHERE device_id='{device}'")
    code = newest_code(account['username'] + '@securemesh.test')
    password = 'reset-password-' + uuid.uuid4().hex

    calls = [
        ('/v1/chat-requests', dict(id=newest, username=peer['username'])),
        (f'/v1/chat-requests/{pending}/accept', {}),
        (f'/v1/chat-requests/{dismissible}/dismiss', {}),
        ('/v1/crypto/keypackages', dict(payload=publication, invitationId=pending)),
        ('/v1/crypto/keypackages/lease', dict(invitationId=waiting['invitationId'], requestId=waiting['leaseId'])),
        ('/v1/conversations/establish', waiting),
        (f"/v1/crypto/welcomes/{incoming['id']}/ack", {}),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(calls)+1) as pool:
        with hold_row(db, f"SELECT id FROM sessions WHERE device_id='{device}' AND NOT revoked FOR UPDATE"):
            reset = pool.submit(d.request, '/v1/auth/recovery/complete',
                                dict(token=code, password=password, username=account['username']), expected=204)
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'UPDATE sessions SET revoked=true%'")
            old_calls = [pool.submit(d.request, path, payload, token=access(account), expected=401)
                         for path, payload in calls]
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=ANY($1) ORDER BY id FOR UPDATE%'")
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=$1 FOR SHARE%'", len(calls)-1)
        reset.result(timeout=10)
        assert all(operation.result(timeout=10) == {'code': 'AUTH_REQUIRED'} for operation in old_calls)

    assert scalar(db, f"SELECT count(*) FROM chat_requests WHERE id='{uuid.UUID(newest)}'") == '0'
    assert scalar(db, f"""SELECT count(*) FROM chat_requests WHERE id IN
                  ('{uuid.UUID(pending)}','{uuid.UUID(dismissible)}') AND recipient_device IS NULL AND expires_at>now()""") == '2'
    assert scalar(db, f"SELECT count(*) FROM key_packages WHERE device_id='{device}'") == packages_before
    assert scalar(db, f"SELECT count(*) FROM conversation_bootstraps WHERE conversation_id='{uuid.UUID(waiting['id'])}'") == '0'
    assert scalar(db, f"SELECT received FROM conversation_bootstraps WHERE conversation_id='{uuid.UUID(incoming['id'])}'") == 'f'

    fresh = d.login(account['username'], password, account['device'])['accessToken']
    d.request('/v1/conversations/establish', waiting, token=fresh, expected=201)
    welcome = next(row for row in d.request('/v1/crypto/welcomes', token=fresh) if row['group'] == incoming['id'])
    account['device'].call('directory_join', **welcome)
    d.request(f"/v1/crypto/welcomes/{incoming['id']}/ack", {}, token=fresh, expected=204)


def main():
    d.BASE = 'https://127.0.0.1:5192'
    mail = {'VerificationEmail__Provider': 'Mailpit', 'VerificationEmail__MailpitPort': '51028'}
    with patch.dict(os.environ, mail), database() as db:
        with d.Server(database=db, legacy_bootstrap=False), tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as scratch:
            run(db, Path(scratch))
    print('PASS recovery precedes stale invitation create/accept/dismiss, publish/lease, establish and Welcome ACK.')


if __name__ == '__main__':
    main()
