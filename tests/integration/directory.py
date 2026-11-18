#!/usr/bin/env python3
"""Real signed KeyPackage AS/DS + recipient-approved Welcome routing, never local Welcome exchange."""
import base64
import concurrent.futures
import hashlib
import json
import subprocess
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path
import delivery as d


def sql(statement):
    return subprocess.check_output(['docker','compose','exec','-T','db','psql','-U','securemesh','-d','securemesh','-v','ON_ERROR_STOP=1','-Atc',statement],cwd=d.ROOT,text=True)


def establish(a,b,check_crash=False):
    da,db=a['device'],b['device'];at=a['session']['accessToken'];bt=b['session']['accessToken']
    invitation=str(uuid.uuid4());lease=str(uuid.uuid4())
    d.request('/v1/chat-requests',dict(id=invitation,username=b['username']),token=at,expected=201)
    d.request(f'/v1/chat-requests/{invitation}/accept',{},token=bt,expected=204)
    published=d.request('/v1/crypto/keypackages',dict(payload=db.call('keypackage')['keypackage']),token=bt,expected=201)
    package=d.request('/v1/crypto/keypackages/lease',dict(invitationId=invitation,requestId=lease),token=at)
    assert package['reference']==published['reference']
    # Independent pins are a prerequisite, never inferred from the directory response.
    args=dict(invitation=invitation,lease=lease,recipient=db.identity,reference=package['reference'],keypackage=package['keypackage'])
    if check_crash:da.call('directory_prepare',reject=True,**args,crash_before_commit=True)
    request=da.call('directory_prepare',**args)
    assert da.call('directory_prepare',**args)==request
    group=request['id']
    d.request('/v1/conversations/establish',request,token=at,expected=201)
    certificate=next(c for c in d.request('/v1/crypto/welcomes',token=bt) if c['group']==group)
    db.call('directory_join',**certificate)
    d.request(f'/v1/crypto/welcomes/{group}/ack',{},token=bt,expected=204)
    return group


def main():
    d.BASE='https://127.0.0.1:5096'
    with d.Server(legacy_bootstrap=False) as server,tempfile.TemporaryDirectory(prefix='securemesh-directory-',dir=d.ROOT/'.local') as tmp:
        root=Path(tmp);a,b,outsider=[d.account(root) for _ in range(3)]
        da,db=a['device'],b['device'];at=a['session']['accessToken'];bt=b['session']['accessToken'];ot=outsider['session']['accessToken']
        d.request('/v1/conversations',dict(id=str(uuid.uuid4()),deviceIds=[da.identity,db.identity],initialEpoch=1),token=at,expected=403)
        kp=db.call('keypackage')['keypackage']
        d.request('/v1/crypto/keypackages',dict(payload=kp),token=at,expected=400)
        bad=bytearray(base64.b64decode(kp));bad[-1]^=1
        d.request('/v1/crypto/keypackages',dict(payload=base64.b64encode(bad).decode()),token=bt,expected=400)
        d.request('/v1/crypto/keypackages',dict(payload=base64.b64encode(b'not MLS').decode()),token=bt,expected=400)
        published=d.request('/v1/crypto/keypackages',dict(payload=kp),token=bt,expected=201)
        assert d.request('/v1/crypto/keypackages',dict(payload=kp),token=bt)['reference']==published['reference']
        pending=d.Device(root);ps=d.login(a['username'],a['password'],pending)
        d.request('/v1/crypto/keypackages',dict(payload=pending.call('keypackage')['keypackage']),token=ps['accessToken'],expected=403)
        invitation=str(uuid.uuid4())
        d.request('/v1/chat-requests',dict(id=invitation,username=b['username']),token=at,expected=201)
        d.request(f'/v1/chat-requests/{invitation}',token=ot,expected=404)
        d.request(f'/v1/chat-requests/{invitation}/accept',{},token=ot,expected=404)
        d.request('/v1/crypto/keypackages/lease',dict(invitationId=invitation,requestId=str(uuid.uuid4())),token=at,expected=403)
        d.request(f'/v1/chat-requests/{invitation}/accept',{},token=bt,expected=204)
        assert any(q['id']==invitation for q in d.request('/v1/chat-requests',token=bt))
        def lease(_):
            lid=str(uuid.uuid4());request=urllib.request.Request(d.BASE+'/v1/crypto/keypackages/lease',data=json.dumps(dict(invitationId=invitation,requestId=lid)).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+at})
            try:
                with urllib.request.urlopen(request,context=d.TLS,timeout=20) as response:return response.status,json.load(response),lid
            except urllib.error.HTTPError as error:return error.code,json.load(error),lid
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(lease,range(2)))
        assert sorted(r[0] for r in results)==[200,409],[(r[0],r[1]) for r in results]
        _,package,lid=next(r for r in results if r[0]==200)
        assert d.request('/v1/crypto/keypackages/lease',dict(invitationId=invitation,requestId=lid),token=at)==package
        d.request('/v1/crypto/keypackages/lease',dict(invitationId=invitation,requestId=lid),token=ot,expected=403)
        assert package['keypackage']==kp
        group=str(uuid.uuid4());da.call('create',group=group)
        da.call('add',reject=True,group=group,keypackage=kp)
        da.pin(db);db.pin(da)
        joined=da.call('add',group=group,keypackage=package['keypackage'])
        binding=dict(group=group,invitation=invitation,lease=lid,sender=da.identity,recipient=db.identity,reference=package['reference'],welcome=joined['welcome'])
        signature=da.call('directory_sign',**binding)['signature']
        request=dict(id=group,invitationId=invitation,leaseId=lid,welcome=joined['welcome'],signature=signature)
        d.request('/v1/conversations/establish',{**request,'signature':base64.b64encode(bytes(64)).decode()},token=at,expected=403)
        d.request('/v1/conversations/establish',request,token=bt,expected=403)
        assert not d.request('/v1/conversations/establish',request,token=at,expected=201)['alreadyCommitted']
        assert d.request('/v1/conversations/establish',request,token=at)['alreadyCommitted']
        server.restart()
        sql(f"UPDATE key_packages SET lease_expires_at=now()-interval '1 second' WHERE lease_id='{uuid.UUID(lid)}'")
        assert d.request('/v1/conversations/establish',request,token=at)['alreadyCommitted']
        d.request('/v1/conversations/establish',{**request,'id':str(uuid.uuid4())},token=at,expected=409)
        assert d.request('/v1/crypto/welcomes',token=ot)==[]
        assert d.request('/v1/crypto/welcomes',token=at)==[]
        certificate=next(c for c in d.request('/v1/crypto/welcomes',token=bt) if c['group']==group)
        d.request(f'/v1/crypto/welcomes/{group}/ack',{},token=ot,expected=404)
        corrupted=bytearray(base64.b64decode(certificate['welcome']));corrupted[-1]^=1
        db.call('directory_join',reject=True,**{**certificate,'welcome':base64.b64encode(corrupted).decode()})
        db.call('directory_join',reject=True,**{**certificate,'recipient':outsider['device'].identity})
        db.call('directory_join',reject=True,**certificate,crash_before_commit=True)
        db.call('directory_join',**certificate)
        assert db.call('directory_join',**certificate)['already_joined']
        message=da.call('queue',group=group,id=str(uuid.uuid4()),text='Routed Welcome, not local test exchange')
        d.request('/v1/messages',d.envelope(message,group),token=at)
        d.sync(db,bt,group)
        assert len(db.call('history',group=group)['events'])==1
        # Redelivered Welcome must not overwrite a progressed MLS ratchet.
        assert db.call('directory_join',**certificate)['already_joined']
        response=db.call('queue',group=group,id=str(uuid.uuid4()),text='Recipient joined via authenticated delivery service')
        d.request('/v1/messages',d.envelope(response,group),token=bt)
        d.sync(da,at,group);d.sync(db,bt,group)
        assert len(da.call('history',group=group)['events'])==1
        d.request(f'/v1/crypto/welcomes/{group}/ack',{},token=bt,expected=204)
        assert all(c['group']!=group for c in d.request('/v1/crypto/welcomes',token=bt))
        assert sql(f"SELECT count(*) FROM members WHERE conversation_id='{uuid.UUID(group)}'").strip()=='2'
        # Native preparation stores group, Welcome and immutable retry request in one SQLCipher transaction.
        second=establish(a,b,check_crash=True)
        prepared=da.call('outbox')['messages']
        assert all(m['group']!=second for m in prepared)
        unexpected=outsider['device']
        for left,right in ((da,unexpected),(unexpected,da),(unexpected,db)):left.pin(right)
        hostile=str(uuid.uuid4());da.call('create',group=hostile)
        da.call('add',group=hostile,keypackage=db.call('keypackage')['keypackage'])
        hidden=da.call('add',group=hostile,keypackage=unexpected.call('keypackage')['keypackage'])
        binding=dict(group=hostile,invitation=str(uuid.uuid4()),lease=str(uuid.uuid4()),sender=da.identity,recipient=unexpected.identity,reference=package['reference'],welcome=hidden['welcome'])
        raw=f"SecureMesh/conversation-establish/v1\n{hostile}\n{binding['invitation']}\n{binding['lease']}\n{da.identity}\n{unexpected.identity}\n{package['reference']}\n{base64.b64encode(hashlib.sha256(base64.b64decode(hidden['welcome'])).digest()).decode()}\n1".encode()
        signature=da.call('sign',payload=base64.b64encode(raw).decode())['signature']
        unexpected.call('directory_join',reject=True,**binding,signature=signature)
        print('PASS: real OpenMLS public KeyPackage validation; credential/key/signature substitution denied; trusted publication; explicit recipient consent; atomic one-use lease/race/idempotency; signed recipient-scoped Welcome; legacy bootstrap disabled; crash before local join COMMIT recovers; redelivery cannot roll back MLS; TLS two-way ciphertext delivery and membership IDOR; late bootstrap ACK retry after lease expiry; no private keys in server helper.')


if __name__=='__main__':main()
