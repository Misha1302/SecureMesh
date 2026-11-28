#!/usr/bin/env python3
"""Verify account-level invitation blocks over authenticated HTTPS in an isolated database."""
import concurrent.futures
import json
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

import delivery as test
from directory import establish
from private_blobs import database


def run(root):
    sender, owner, other = [test.account(root) for _ in range(3)]
    sender_token, owner_token, other_token = [
        account['session']['accessToken'] for account in (sender, owner, other)
    ]
    sender['device'].pin(owner['device'])
    owner['device'].pin(sender['device'])
    group = establish(sender, owner)
    block_list = '/v1/contact-blocks'
    block_route = block_list + '/' + sender['username']
    invite_route = '/v1/chat-requests'

    def invite(token=sender_token, name=owner['username'], expected=201, invitation=None):
        invitation = invitation or str(uuid.uuid4())
        return test.request(invite_route, dict(id=invitation, username=name), token=token, expected=expected)

    def requests(token):
        return test.request(invite_route, token=token)

    pending_id = invite()['id']
    assert any(row['id'] == pending_id for row in requests(owner_token))
    accepted_id = invite()['id']
    test.request(f'{invite_route}/{accepted_id}/accept', {}, token=owner_token, expected=204)
    pending_device = test.Device(root)
    pending_token = test.login(owner['username'], owner['password'], pending_device)['accessToken']
    test.request(block_list, expected=401)
    test.request(block_route, token=pending_token, method='PUT', expected=403)
    test.request(block_list, token=pending_token, expected=403)
    test.request(block_list + '/' + owner['username'], token=owner_token, method='PUT', expected=400)
    assert test.request(block_list, token=owner_token) == {'items': []}
    for _ in range(2):
        test.request(block_route, token=owner_token, method='PUT', expected=204)
    assert test.request(block_list, token=owner_token) == {'items': [sender['username']]}
    assert test.request(block_list, token=sender_token) == {'items': []}
    assert all(row['id'] != pending_id for row in requests(owner_token))
    assert any(row['id'] == accepted_id and row['accepted'] for row in requests(owner_token))
    test.request(f'{invite_route}/{pending_id}/accept', {}, token=owner_token, expected=404)
    assert invite(expected=404) == invite(name='absent_' + uuid.uuid4().hex[:12], expected=404)
    invite(invitation=pending_id, expected=200)
    assert all(row['id'] != pending_id for row in requests(owner_token))
    assert invite(token=other_token)['id']

    # The established conversation still carries ciphertext in both directions.
    for source, target, source_token, target_token in (
        (sender, owner, sender_token, owner_token),
        (owner, sender, owner_token, sender_token),
    ):
        message = source['device'].call('queue', group=group, id=str(uuid.uuid4()), text='Existing chat remains available')
        test.request('/v1/messages', test.envelope(message, group), token=source_token)
        test.sync(target['device'], target_token, group)
    for account in (owner, sender):
        events = account['device'].call('history', group=group)['events']
        assert any(event['text'] == 'Existing chat remains available' for event in events)

    for _ in range(2):
        test.request(block_route, token=owner_token, method='DELETE', expected=204)
    assert test.request(block_list, token=owner_token) == {'items': []}
    fresh_id = invite()['id']
    assert any(row['id'] == fresh_id for row in requests(owner_token))

    # Either the new invite loses the race or the block expires it before returning.
    raced_id = str(uuid.uuid4())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        def send():
            request = urllib.request.Request(test.BASE + invite_route, data=json.dumps({
                'id': raced_id, 'username': owner['username'],
            }).encode(), headers={'Authorization': 'Bearer ' + sender_token, 'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(request, context=test.TLS, timeout=10) as response:
                    return response.status
            except urllib.error.HTTPError as error:
                return error.code
        sending = pool.submit(send)
        blocking = pool.submit(test.request, block_route, token=owner_token, method='PUT', expected=204)
        blocking.result()
        assert sending.result() in (201, 404)
    incoming = {row['id'] for row in requests(owner_token)}
    assert fresh_id not in incoming and raced_id not in incoming


def main():
    test.BASE = 'https://127.0.0.1:5195'
    with database() as db, tempfile.TemporaryDirectory(dir=test.ROOT/'.local') as scratch:
        with test.Server(database=db, legacy_bootstrap=False):
            run(Path(scratch))
    print('PASS contact blocks, signed-in owner isolation, pending requests, creation race, unblock, and retained MLS conversation.')


if __name__ == '__main__':
    main()
