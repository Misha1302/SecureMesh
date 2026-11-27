"""Exercise real enrollment and membership changes across independent OpenMLS stores."""
import base64
from pathlib import Path
import secrets
import tempfile
import time
import uuid

from process_spike import Device, PersistentDevice


def uid():
    return str(uuid.uuid4())


def check(devices):
    owner, peer, candidate = devices
    assert len({device.public for device in devices}) == 3
    owner.pin(peer)
    peer.pin(owner)
    candidate.pin(owner)
    candidate.pin(peer)
    group = uid()
    owner.call('create', group=group)
    initial = owner.call('add', group=group, keypackage=peer.call('keypackage')['keypackage'])
    peer.call('join', group=group, welcome=initial['welcome'])

    before = owner.call('queue', group=group, id=uid(), text='old epoch')
    peer.call('ingest', **before, seq=1, sender=owner.identity)
    account = uid()
    issued = int(time.time())
    transcript = '\n'.join(['SecureMesh/enrollment-request/v1', account, candidate.identity,
                            candidate.public, uid(), secrets.token_hex(32), str(issued), str(issued + 300)])
    proof = dict(account=account, payload=base64.b64encode(transcript.encode()).decode())
    proof['candidate_signature'] = candidate.call('enrollment_proof', **proof)['signature']
    proof['grant_signature'] = owner.call('enrollment_approve', **proof, confirmed=True)['signature']
    proof['activation_signature'] = candidate.call('enrollment_accept', **proof,
                                                  approver=owner.identity)['activation_signature']
    approval = dict(group=group, device=candidate.identity, approver=owner.identity,
                    confirmed=True, action='add', epoch=1, **proof)
    add = dict(group=group, id=uid(), epoch=1, device=candidate.identity, action='add',
               keypackage=candidate.call('keypackage')['keypackage'])
    owner.call('roster_approve', **approval)
    owner.call('roster_stage', reject=True, **add)  # earlier outgoing message is queued
    owner.call('ingest', **before, seq=1, sender=owner.identity)
    owner.call('roster_stage', reject=True, **(add | dict(keypackage=peer.call('keypackage')['keypackage'])))
    Device.call(owner, 'roster_stage', reject=True, **add, crash_before_commit=True)
    assert owner.call('roster_pending',group=group)['transition'] is None
    abandoned=owner.call('roster_stage', **add)
    owner.call('roster_rejected',reject=True,group=group,id=add['id'],digest=abandoned['digest'])
    owner.call('roster_rejected',group=group,id=add['id'],digest=abandoned['digest'],epoch_conflict_confirmed=True)
    owner.call('roster_stage', reject=True, **add)
    add['id']=uid()
    owner.call('roster_approve', **approval)
    added=owner.call('roster_stage', **add)
    assert Device.call(owner,'roster_pending',group=group)['transition']==added
    assert owner.call('roster_stage', **add)==added
    owner.call('roster_stage', reject=True, **(add | dict(device=peer.identity)))
    assert owner.call('outbox')['messages']==[]  # never upload through the generic sender
    owner.call('queue', reject=True, group=group, id=uid(),text='pending epoch')
    owner.call('saved', reject=True,group=group,id=add['id'],seq=2)
    ack=dict(group=group,id=add['id'],digest=added['digest'],seq=2,durable=True)
    for changed in [dict(digest='wrong'),dict(durable=False),dict(seq=0)]:
        owner.call('roster_saved',reject=True,**(ack|changed))
    Device.call(owner,'roster_saved',reject=True,**ack,crash_before_commit=True)
    assert owner.call('roster_pending',group=group)['transition']==added
    assert owner.call('roster_saved',**ack)['epoch']==2
    assert owner.call('roster_saved',**ack)['already_saved']
    owner.call('roster_saved',reject=True,**(ack|dict(seq=3)))
    assert owner.call('roster_pending',group=group)['transition'] is None
    transition = dict(group=group, id=add['id'], epoch=1, kind=3, sender=owner.identity,
                      ciphertext=added['commit'], seq=2)
    owner.call('ingest', **transition)
    peer.pin(candidate)  # Global out-of-band identity trust is insufficient for this group.
    peer.call('ingest', reject=True, **transition)
    for changed in [dict(confirmed=False), dict(epoch=2), dict(account=uid()),
                    dict(approver=peer.identity), dict(device=uid()),
                    dict(activation_signature=proof['grant_signature'])]:
        peer.call('roster_approve', reject=True, **(approval | changed))
    peer.call('roster_approve', **approval)
    for changed in [dict(sender=candidate.identity), dict(kind=1), dict(epoch=2)]:
        peer.call('ingest', reject=True, **(transition | changed))
    assert peer.call('cursor', group=group)['seq'] == 1
    # Kill a separate worker before commit while the long-lived peer worker is idle.
    Device.call(peer, 'ingest', reject=True, **transition, crash_before_commit=True)
    assert peer.call('cursor', group=group)['seq'] == 1
    assert peer.call('ingest', **transition)['event']['epoch'] == 2
    assert peer.call('ingest', **transition)['duplicate']

    candidate.call('join', group=group, welcome=added['welcome'],
                   expected_members=[device.identity for device in devices])
    candidate.call('process', reject=True, group=group, ciphertext=before['ciphertext'])
    after = owner.call('queue', group=group, id=uid(), text='after joining')
    assert peer.call('ingest', **after, seq=3, sender=owner.identity)['event']['text'] == 'after joining'
    assert candidate.call('process', group=group, ciphertext=after['ciphertext'])['text'] == 'after joining'

    owner.call('ingest', **after, seq=3,sender=owner.identity)
    remove=dict(group=group,epoch=2,action='remove',device=candidate.identity)
    owner.call('roster_approve', **remove, approver=owner.identity,confirmed=True)
    removed=owner.call('roster_stage', **remove,id=uid())
    assert not removed['welcome']
    assert owner.call('roster_saved',group=group,id=removed['id'],digest=removed['digest'],durable=True,seq=4)['epoch']==3
    removal = dict(group=group, epoch=2, kind=3, seq=4, id=removed['id'], ciphertext=removed['commit'],
                   sender=owner.identity)
    owner.call('ingest', **removal)
    peer.call('ingest', reject=True, **removal)
    peer.call('roster_approve', group=group, device=candidate.identity, approver=owner.identity,
              epoch=2, action='remove', confirmed=True)
    assert peer.call('ingest', **removal)['event']['epoch'] == 3
    last = owner.call('queue', group=group, id=uid(), text='after removal')
    assert peer.call('ingest', **last, seq=5, sender=owner.identity)['event']['text'] == 'after removal'
    candidate.call('process', reject=True, group=group, ciphertext=last['ciphertext'])


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as root:
        clients = [PersistentDevice.wrap(Device(Path(root))) for _ in range(3)]
        try:
            check(clients)
        finally:
            for client in clients:
                client.close()
    print('PASS: three independent stores, enrollment signatures, scoped roster consent, '
          'transaction rollback, future-only Welcome, and revoked leaf exclusion.')
