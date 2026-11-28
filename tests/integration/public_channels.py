"""Public catalog, subscriptions and owner-only publishing through the actual HTTPS API."""
from pathlib import Path
import tempfile
import uuid


def verify(request, owner, reader, outsider, pending):
    path = '/v1/public-channels'
    slug = 'qa_' + uuid.uuid4().hex[:12]
    channel = str(uuid.uuid4())
    spec = {'id': channel, 'slug': slug, 'title': 'Новости команды'}
    root = path + '/' + channel
    request(path, spec, token=pending, expected=403)
    request(path, spec, expected=401)
    request(path, {**spec, 'slug':'AB'}, token=owner, expected=400)
    assert request(path,spec,token=owner,expected=201)['id'] == channel
    assert request(path,spec,token=owner)['id'] == channel
    request(path,{**spec,'title':'Changed retry'},token=owner,expected=409)
    request(path,{**spec,'id':str(uuid.uuid4())},token=outsider,expected=409)
    start = request(path+'?q='+slug,token=reader)['items']
    assert len(start)==1 and not start[0]['owner'] and not start[0]['subscribed']
    assert request(path+'?mine=true&q='+slug,token=owner)['items'][0]['owner']
    assert request(path+'?mine=true&q='+slug,token=reader)['items']==[]
    request(root+'/posts', token=reader, expected=403)
    request(path+'/feed', expected=401)
    request(path+'/feed', token=pending, expected=403)
    request(path+'/feed?before=bad', token=reader, expected=400)
    request(root+'/subscription',token=reader,method='PUT',expected=204)
    request(root+'/subscription',token=reader,method='PUT',expected=204)
    request(root+'/subscription',token=pending,method='PUT',expected=403)
    assert request(path+'?mine=true&q='+slug,token=reader)['items'][0]['subscribed']
    data={'requestId':str(uuid.uuid4()),'body':'Публикация в открытом канале'}
    request(root+'/posts',data,token=reader,expected=403)
    seq=request(root+'/posts',data,token=owner,expected=201)['seq']
    assert request(root+'/posts',data,token=owner)['seq']==seq
    request(root+'/posts',{**data,'body':'changed'},token=owner,expected=409)
    request(root+'/posts',{**data,'body':' '},token=owner,expected=400)
    for i in range(9):
        request(root+'/posts',{'requestId':str(uuid.uuid4()),'body':'🚀'*2048},token=owner,expected=201)
    aggregate=request(path+'/feed',token=reader)
    assert len(aggregate['items']) == 10
    assert all(p['channelId'] == channel for p in aggregate['items'])
    assert request(path+'/feed',token=outsider)['items'] == []
    first=request(root+'/posts',token=reader)
    assert len(first['items'])==8 and first['next']==first['items'][-1]['seq']
    older=request(root+'/posts?before='+str(first['next']),token=reader)
    assert len(older['items'])==2 and older['next'] is None and older['items'][-1]['seq']==seq
    assert not ({p['seq'] for p in first['items']} & {p['seq'] for p in older['items']})
    for i in range(11):
        request(root+'/posts',{'requestId':str(uuid.uuid4()),'body':f'page {i}'},token=owner,expected=201)
    second={'id':str(uuid.uuid4()),'slug':'other_'+uuid.uuid4().hex[:12],'title':'Other'}
    request(path,second,token=owner,expected=201)
    second_root=path+'/'+second['id']
    request(second_root+'/subscription',token=reader,method='PUT',expected=204)
    second_seq=request(second_root+'/posts',{'requestId':str(uuid.uuid4()),'body':'Second channel'},token=owner,expected=201)['seq']
    page1=request(path+'/feed',token=reader)
    assert len(page1['items'])==20 and page1['next']
    page2=request(path+'/feed?before='+page1['next'],token=reader)
    assert len(page2['items'])==2 and page2['next'] is None
    assert second_seq in [p['seq'] for p in page1['items']+page2['items']]
    assert {p['channelId'] for p in page1['items']+page2['items']} == {channel,second['id']}
    assert not ({p['seq'] for p in page1['items']} & {p['seq'] for p in page2['items']})
    assert [p['publishedAt'] for p in page1['items']+page2['items']] == sorted(
        [p['publishedAt'] for p in page1['items']+page2['items']], reverse=True)
    request(second_root,token=owner,method='DELETE',expected=204)
    request(root+'/posts?before=-1',token=reader,expected=400)
    request(root+'/posts/'+str(seq),token=reader,method='DELETE',expected=403)
    request(root+'/posts/'+str(seq),token=owner,method='DELETE',expected=204)
    request(root+'/posts',data,token=owner,expected=409)
    request(root,token=reader,method='DELETE',expected=403)
    request(root+'/subscription',token=reader,method='DELETE',expected=204)
    request(root+'/posts',token=reader,expected=403)
    assert request(path+'/feed',token=reader)['items'] == []
    request(root,token=owner,method='DELETE',expected=204)
    request(root+'/posts',token=owner,expected=404)
    assert request(path+'?q='+slug,token=outsider)['items']==[]
    request(path,spec,token=owner,expected=409)

    # A separate account exercises real limits without consuming the fixture owner's allowance.
    quota_slug = 'limit_' + uuid.uuid4().hex[:9]
    opened = []
    for i in range(8):
        item = {'id': str(uuid.uuid4()), 'slug': f'{quota_slug}_{i}', 'title': 'Quota check'}
        request(path, item, token=outsider, expected=201)
        opened.append(item['id'])
    extra = {'id': str(uuid.uuid4()), 'slug': quota_slug + '_extra', 'title': 'Another channel'}
    request(path, extra, token=outsider, expected=409)
    for channel_id in opened:
        request(path + '/' + channel_id, token=outsider, method='DELETE', expected=204)
    for i in range(2):
        item = {'id': str(uuid.uuid4()), 'slug': f'{quota_slug}_again{i}', 'title': 'Quota check'}
        request(path, item, token=outsider, expected=201)
        request(path + '/' + item['id'], token=outsider, method='DELETE', expected=204)
    request(path, extra, token=outsider, expected=429)


def main():
    import os
    import subprocess
    import sys
    import delivery as d
    import invite_channels
    d.BASE='https://127.0.0.1:5119'
    with d.Server() as server, tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as tmp:
        a,b,c=[d.account(Path(tmp)) for _ in range(3)]
        pending=d.login(a['username'],a['password'],d.Device(Path(tmp)))
        tokens=[a['session']['accessToken'],b['session']['accessToken'],c['session']['accessToken'],pending['accessToken']]
        verify(d.request,*tokens)
        # Start a fresh service token bucket; the two suites deliberately exercise many requests.
        server.restart()
        invite_channels.verify(d.request,tokens[1],tokens[2],tokens[0],tokens[3],c['username'])
        if '--ui' in sys.argv:
            server.restart()
            env={**os.environ,'SECUREMESH_CHANNEL_FIXTURE_URL':d.BASE,
                 'SECUREMESH_CHANNEL_FIXTURE_CA':str(d.ROOT/'.local/tls.pem'),
                 'SECUREMESH_CHANNEL_OWNER':tokens[1], 'SECUREMESH_CHANNEL_READER':tokens[0],
                 'SECUREMESH_CHANNEL_READER_USERNAME':a['username']}
            flutter=d.ROOT/'.local/flutter/bin/flutter'
            subprocess.run([str(flutter) if flutter.exists() else 'flutter','test','--no-pub',
                           '--concurrency=1','integration/public_channels_hosted_test.dart'],
                           cwd=d.ROOT/'apps/client_flutter',env=env,check=True)

    print('PASS trusted public channels, owner writes, subscription ACL, idempotency, Unicode and feed pagination.')


if __name__=='__main__':
    main()
