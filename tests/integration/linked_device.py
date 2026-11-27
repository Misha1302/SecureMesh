"""Three independent MLS stores using the real HTTPS roster, sync, and revocation routes."""
import tempfile
import uuid
from pathlib import Path


def run(request, devices, tokens):
    a,b,c=devices
    at,bt,ct=tokens
    group=str(uuid.uuid4())
    def post(route,data,token,expected=200):
        return request(route,data,token=token,expected=expected)
    def send(wire):
        return post('/v1/messages',dict(conversationId=group,clientMessageId=wire['id'],mlsEpoch=wire['epoch'],
                         envelopeKind=wire['kind'],ciphertext=wire['ciphertext']),at)
    def sync(token):
        return request('/v1/sync?conversationId='+group,token=token)['messages']
    def ingest(client,row):
        return client.call('ingest',group=group,id=row['clientMessageId'],sender=row['senderDeviceId'],
                           seq=row['serverSequence'],epoch=row['mlsEpoch'],kind=row['envelopeKind'],
                           ciphertext=row['ciphertext'],digest=row['ciphertextSha256'])
    a.pin(b);b.pin(a);c.pin(a);c.pin(b)
    a.call('create',group=group)
    initial=a.call('add',group=group,keypackage=b.call('keypackage')['keypackage'])
    b.call('join',group=group,welcome=initial['welcome'])
    post('/v1/conversations',dict(id=group,deviceIds=[a.identity,b.identity],initialEpoch=1),at,201)
    first=a.call('queue',group=group,id=str(uuid.uuid4()),text='before enrollment')
    send(first);ingest(a,sync(at)[0]);ingest(b,sync(bt)[0])
    e=post('/v1/devices/enrollment',{},ct)
    path='/v1/devices/enrollment/'+e['id']
    proof=dict(account=request('/v1/users/me',token=ct)['userId'],payload=e['payload'])
    proof['candidate_signature']=c.call('enrollment_proof',**proof)['signature']
    post(path+'/proof',dict(signature=proof['candidate_signature']),ct,204)
    proof['grant_signature']=a.call('enrollment_approve',**proof,confirmed=True)['signature']
    post(path+'/approve',dict(signature=proof['grant_signature']),at,204)
    proof['activation_signature']=c.call('enrollment_accept',**proof,approver=a.identity)['activation_signature']
    post(path+'/activate',dict(signature=proof['activation_signature']),ct,204)
    for token in (at,ct):
        assert request(path,token=token)['activationSignature']==proof['activation_signature']
    request(path,token=bt,expected=404)
    post('/v1/crypto/keypackages',dict(payload=c.call('keypackage')['keypackage']),ct,201)
    rid=str(uuid.uuid4())
    route=f'/v1/conversations/{group}/roster-packages/{c.identity}/{rid}'
    post(route,{},bt,403)
    package=post(route,{},at)
    add=dict(group=group,device=c.identity,epoch=1,action='add')
    a.call('roster_approve',**add,approver=a.identity,confirmed=True,**proof)
    t=a.call('roster_stage',**add,id=rid,**package)
    endpoint='/v1/roster/transitions'
    post(endpoint,t|dict(seq=9),at,403)
    acknowledgment=post(endpoint,t,at)
    assert post(endpoint,t,at)['alreadySaved']
    a.call('roster_saved',group=group,id=rid,**acknowledgment)
    ingest(a,sync(at)[-1])
    change=request(f'/v1/conversations/{group}/roster/2',token=bt)
    b.call('roster_approve',**add,approver=a.identity,confirmed=True,**change['certificate'])
    ingest(b,sync(bt)[-1])
    assert sync(ct)==[]
    assert request('/v1/conversations',token=ct)[0]['peerDevice']==b.identity
    welcome=request('/v1/roster/welcomes',token=ct)[0]
    c.call('roster_join',transition=welcome,confirmed=True,expected_members=[x.identity for x in devices])
    post('/v1/acks',dict(conversationId=group,sequence=2),ct,204)
    assert request('/v1/roster/welcomes',token=ct)==[]
    future=a.call('queue',group=group,id=str(uuid.uuid4()),text='new device future only')
    send(future);ingest(a,sync(at)[-1]);ingest(b,sync(bt)[-1])
    messages=sync(ct)
    assert [x['serverSequence'] for x in messages]==[3]
    assert ingest(c,messages[0])['event']['text']=='new device future only'
    request('/v1/devices/'+c.identity,token=at,method='DELETE',expected=204)
    request('/v1/sync?conversationId='+group,token=ct,expected=401)
    remove=dict(group=group,device=c.identity,epoch=2,action='remove')
    for client in (a,b):
        client.call('roster_approve',**remove,approver=a.identity,confirmed=True)
    t=a.call('roster_stage',**remove,id=str(uuid.uuid4()))
    ack=post(endpoint,t,at)
    a.call('roster_saved',group=group,id=t['id'],**ack)
    for client,token in ((a,at),(b,bt)):
        ingest(client,sync(token)[-1])
    last=a.call('queue',group=group,id=str(uuid.uuid4()),text='after removal')
    send(last)
    assert ingest(b,sync(bt)[-1])['event']['text']=='after removal'
    c.call('process',reject=True,group=group,ciphertext=last['ciphertext'])
    print('PASS HTTPS + PostgreSQL + three OpenMLS stores: authenticated enrollment, scoped package lease, signed transactional admission, immutable retry, history floor, Welcome ACK, future delivery, revoke and Remove.')


if __name__=='__main__':
    import delivery as d
    d.BASE='https://127.0.0.1:5123'
    with d.Server(),tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as tmp:
        a,b=[d.account(Path(tmp)) for _ in range(2)]
        c=d.Device(Path(tmp))
        ct=d.login(a['username'],a['password'],c)['accessToken']
        run(d.request,[a['device'],b['device'],c],[a['session']['accessToken'],b['session']['accessToken'],ct])
