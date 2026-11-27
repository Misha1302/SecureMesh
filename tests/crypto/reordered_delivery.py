"""Delayed first ciphertext must survive fast later ACKs and a sender restart."""
from pathlib import Path
import tempfile
import uuid

from process_spike import Device


def identifier():
    return str(uuid.uuid4())


def main():
    with tempfile.TemporaryDirectory() as tmp:
        sender, receiver = Device(Path(tmp)), Device(Path(tmp))
        sender.pin(receiver)
        receiver.pin(sender)
        group = identifier()
        sender.call('create', group=group)
        welcome = sender.call('add', group=group, keypackage=receiver.call('keypackage')['keypackage'])
        receiver.call('join', group=group, welcome=welcome['welcome'])
        offered = [sender.call('queue', group=group, id=identifier(), text=f'text {n}') for n in range(12)]
        seq = 0

        def commit(message):
            nonlocal seq
            seq += 1
            receiver.call('ingest', **message, seq=seq, sender=sender.identity, cursor='')
            sender.call('saved', group=group, id=message['id'], seq=seq)

        # Every call reopens the actual SQLCipher store. Exercise refill while
        # the first write is delayed; the receiver uses its unchanged MLS policy.
        while True:
            available = sender.call('outbox', dispatch=True)['messages']
            assert available[0] == offered[0]
            if len(available) == 1:
                break
            commit(available[1])
        assert 0 < seq < len(offered) - 1
        assert len(sender.call('outbox')['messages']) == len(offered) - seq
        commit(offered[0])
        while pending := sender.call('outbox', dispatch=True)['messages']:
            commit(pending[0])
        assert seq == len(offered)
        actual = receiver.call('history', group=group)['events']
        assert len(actual) == len(offered) and {m['id'] for m in actual} == {m['id'] for m in offered}
        print('PASS: delayed oldest MLS envelope, later durable ACKs, repeated store reopen, exact-once receipt of all 12 messages')


if __name__ == '__main__':
    main()
