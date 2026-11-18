#!/usr/bin/env python3
"""Create actual local accounts and client stores; no prewritten chat messages."""
import json
import os
import sys
import uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests/integration'))
import delivery

def main():
    os.umask(0o077)
    delivery.BASE='https://127.0.0.1:5088'
    root=ROOT/'.local/demo';root.mkdir(exist_ok=True)
    manifest=root/'profiles.json'
    if manifest.exists():
        print('Local demo profiles already exist at .local/demo/profiles.json; not overwritten.');return
    a,b=[delivery.account(root) for _ in range(2)]; da,db=a['device'],b['device'];da.pin(db);db.pin(da)
    group=str(uuid.uuid4());da.call('create',group=group)
    welcome=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage']);db.call('join',group=group,welcome=welcome['welcome'])
    delivery.request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=welcome['epoch']),token=a['session']['accessToken'],expected=201)
    profiles=[]
    for who,peer in [(a,b),(b,a)]:
        device=who['device']; other=peer['device']
        device.call('profile_put',profile=dict(endpoint=delivery.BASE,group=group,peerName=peer['username'],peerDevice=other.identity,peerKey=other.public,trustConfirmed=False,**who['session']))
        profiles.append(dict(database=str(device.path),passphrase=device.password,username=who['username']))
    manifest.write_text(json.dumps(profiles,indent=2)+'\n')
    print('Two real verified local accounts and MLS profiles created. Unlock details are in ignored .local/demo/profiles.json (mode 600). No messages seeded. Compare keys before sending.')

if __name__=='__main__':main()
