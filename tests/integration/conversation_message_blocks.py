#!/usr/bin/env python3
"""Established MLS message pause through HTTPS/WSS and live PostgreSQL."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import uuid

import delivery as d
from delivery_recovery_serialization import hold_row, scalar, wait_for
from directory import establish
from private_blobs import database


def run():
    d.BASE = 'https://127.0.0.1:5297'
    with database() as db, d.Server(db, legacy_bootstrap=False), tempfile.TemporaryDirectory() as scratch:
        sender, receiver, outsider = (d.account(Path(scratch)) for _ in range(3))
        a, b = sender['device'], receiver['device']
        a.pin(b)
        b.pin(a)
        group = establish(sender, receiver)
        at, bt, ot = (account['session']['accessToken'] for account in (sender, receiver, outsider))
        route = f'/v1/conversations/{group}/message-block'
        messages = '/v1/messages'

        def queue(device, text):
            return device.call('queue', group=group, id=str(uuid.uuid4()), text=text)

        first = queue(a, 'Already accepted before the block')
        pending = queue(a, 'Pending until the recipient resumes')
        reverse = queue(b, 'Reverse delivery is also paused')
        saved = d.request(messages, d.envelope(first, group), token=at)
        assert saved['durable'] and saved['serverSequence'] == 1
        assert d.request(route, token=bt) == {'blockedByYou': False, 'paused': False}
        d.request(route, token=ot, method='PUT', expected=404)
        d.request(route, method='PUT', expected=401)

        # Make the block waiter first on the same conversation row, then send.
        # Both observed requests begin before the artificial lock is released.
        with ThreadPoolExecutor(max_workers=2) as pool:
            with hold_row(db, f"SELECT id FROM conversations WHERE id='{group}' FOR UPDATE"):
                blocking = pool.submit(d.request, route, token=bt, method='PUT')
                wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT account_removed FROM conversations WHERE id=$1 FOR UPDATE%'")
                late = pool.submit(d.request, messages, d.envelope(pending, group), token=at, expected=409)
                wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT epoch,next_seq,account_removed FROM conversations%'")
            assert blocking.result(timeout=10) == {'blockedByYou': True, 'paused': True}
            assert late.result(timeout=10) == {'code': 'CONVERSATION_MESSAGES_BLOCKED'}
        assert d.request(route, token=at) == {'blockedByYou': False, 'paused': True}
        assert d.request(route, token=bt, method='PUT')['blockedByYou']
        assert d.request(messages, d.envelope(first, group), token=at)['serverSequence'] == 1
        assert d.request(messages, d.envelope(reverse, group), token=bt, expected=409)['code'] == 'CONVERSATION_MESSAGES_BLOCKED'
        stream = d.Stream(at, a)
        try:
            denied = stream.send(pending, group)
            assert denied.kind == d.wire.SERVER_ERROR and denied.server_error.stable_code == 'CONVERSATION_MESSAGES_BLOCKED'
            assert stream.send(first, group).durable_ack.server_sequence == 1
        finally:
            stream.close()
        assert scalar(db, f"SELECT next_seq,epoch FROM conversations WHERE id='{group}'") == '1|1'
        d.sync(b, bt, group)
        assert b.call('cursor', group=group)['seq'] == 1
        assert b.call('history', group=group)['events'][0]['text'] == 'Already accepted before the block'

        assert d.request(route, token=at, method='PUT') == {'blockedByYou': True, 'paused': True}
        assert d.request(route, token=bt, method='DELETE') == {'blockedByYou': False, 'paused': True}
        d.request(messages, d.envelope(pending, group), token=at, expected=409)
        assert d.request(route, token=at, method='DELETE') == {'blockedByYou': False, 'paused': False}
        assert d.request(messages, d.envelope(pending, group), token=at)['serverSequence'] == 2
        assert d.request(messages, d.envelope(reverse, group), token=bt)['serverSequence'] == 3
        d.sync(b, bt, group)
        d.sync(a, at, group)
        assert b.call('cursor', group=group)['seq'] == a.call('cursor', group=group)['seq'] == 3
        assert [e['text'] for e in b.call('history', group=group)['events']] == [
            'Already accepted before the block', 'Pending until the recipient resumes']
        assert [e['text'] for e in a.call('history', group=group)['events']] == [
            'Reverse delivery is also paused']
        # This preference does not silently activate the legacy invite block.
        assert d.request('/v1/contact-blocks', token=bt) == {'items': []}
    print('PASS established message blocks, concurrent gate, HTTPS/WSS, stable ACK, MLS resume and history')


if __name__ == '__main__':
    run()
