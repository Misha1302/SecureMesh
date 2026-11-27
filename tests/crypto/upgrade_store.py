#!/usr/bin/env python3
"""Exercise an on-disk MLS/SQLCipher upgrade using two actual CLI versions."""
import argparse
import tempfile
import uuid
from pathlib import Path

import process_spike as spike


def run(before, after):
    with tempfile.TemporaryDirectory(prefix='securemesh-upgrade-') as work:
        root = Path(work)
        spike.BIN = before
        sender = spike.Device(root)
        receiver = spike.Device(root)
        sender.pin(receiver)
        receiver.pin(sender)
        group = str(uuid.uuid4())
        sender.call('create', group=group)
        welcome = sender.call('add', group=group,
                              keypackage=receiver.call('keypackage')['keypackage'])
        receiver.call('join', group=group, welcome=welcome['welcome'])
        previous = sender.call('queue', group=group, id=str(uuid.uuid4()), text='before upgrade')
        receiver.call('process', group=group, ciphertext=previous['ciphertext'])
        pending = sender.call('queue', group=group, id=str(uuid.uuid4()), text='pending during upgrade')
        outbox = sender.call('outbox')
        history = receiver.call('history', group=group)

        spike.BIN = after
        assert sender.call('identity')['public_key'] == sender.public
        assert receiver.call('identity')['public_key'] == receiver.public
        assert sender.call('peer_key_status', identity=receiver.identity,
                           public_key=receiver.public)['status'] == 'matches'
        assert sender.call('outbox') == outbox
        assert receiver.call('history', group=group) == history
        assert receiver.call('process', group=group,
                             ciphertext=pending['ciphertext'])['text'] == 'pending during upgrade'
        assert sender.call('draft_get', group=group)['text'] == ''
        sender.call('draft_put', group=group, text='черновик до отката')
        sender.call('saved', group=group, id=previous['id'], seq=1)
        sender.call('peer_processed', group=group, seq=1)
        updated = receiver.call('queue', group=group, id=str(uuid.uuid4()), text='mixed-version message')

        spike.BIN = before
        assert sender.call('process', group=group,
                           ciphertext=updated['ciphertext'])['text'] == 'mixed-version message'
        assert receiver.call('identity')['public_key'] == receiver.public
        assert {m['text'] for m in receiver.call('history', group=group)['events']} >= {
            'before upgrade', 'pending during upgrade'}

        spike.BIN = after
        assert sender.call('draft_get', group=group)['text'] == 'черновик до отката'
        timeline = {row['id']: row['status'] for row in
                    sender.call('timeline', group=group)['messages']}
        assert timeline[previous['id']] == 'delivered'
        assert timeline[pending['id']] == 'queued'

    print('PASS: pre-upgrade identity, pins, encrypted history and immutable outbox preserved; '
          'queued message survives upgrade; original binary can reopen the store and read new MLS traffic.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path, help='crypto CLI compiled from the old version')
    parser.add_argument('after', type=Path, help='crypto CLI compiled from the proposed version')
    args = parser.parse_args()
    run(args.before.resolve(strict=True), args.after.resolve(strict=True))
