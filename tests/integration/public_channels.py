"""Public catalog, subscriptions and owner-only publishing through the actual HTTPS API."""
from pathlib import Path
import tempfile
from datetime import datetime
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
    pin = {'expectedRevision':0, 'seq':seq}
    request(root+'/pin',pin,method='PUT',expected=401)
    request(root+'/pin',pin,method='PUT',token=pending,expected=403)
    request(root+'/pin',pin,method='PUT',token=reader,expected=403)
    request(root+'/pin',{'seq':seq},method='PUT',token=owner,expected=400)
    request(root+'/pin',{'expectedRevision':0},method='PUT',token=owner,expected=400)
    assert request(root+'/posts',token=owner)['pinRevision']==0
    for _ in range(2):
        request(root+'/pin',pin,method='PUT',token=owner,expected=204)
    reaction = f'{root}/posts/{seq}/reaction'
    request(reaction, {'kind':'heart'}, method='PUT', expected=401)
    request(reaction, method='DELETE', expected=401)
    request(reaction, {'kind':'heart'}, method='PUT', token=pending, expected=403)
    request(reaction, {'kind':'heart'}, method='PUT', token=outsider, expected=403)
    request(reaction, {'kind':'unknown'}, method='PUT', token=reader, expected=400)
    for _ in range(2):
        assert request(reaction,{'kind':'heart'},method='PUT',token=reader)['heart']==1
    assert request(root+'/posts',token=owner)['items'][0]['reactions']==dict(like=0,heart=1,smile=0,mine=None)
    assert request(path+'/feed',token=reader)['items'][0]['reactions']['mine']=='heart'
    assert request(reaction,{'kind':'smile'},method='PUT',token=reader)==dict(like=0,heart=0,smile=1,mine='smile')
    assert request(reaction,{'kind':'like'},method='PUT',token=owner)==dict(like=1,heart=0,smile=1,mine='like')
    assert request(reaction,method='DELETE',token=owner)==dict(like=0,heart=0,smile=1,mine=None)
    for _ in range(2):
        assert request(reaction,method='DELETE',token=reader)==dict(like=0,heart=0,smile=0,mine=None)
    assert request(root+'/posts',data,token=owner)['seq']==seq
    request(root+'/posts',{**data,'body':'changed'},token=owner,expected=409)
    request(root+'/posts',{**data,'body':' '},token=owner,expected=400)
    request(reaction,{'kind':'like'},method='PUT',token=reader)
    first_post = request(root+'/posts',token=owner)['items'][0]
    assert first_post['editedAt'] is None
    edit_route = f'{root}/posts/{seq}'
    edit = {'expectedRevision':1,'body':'Исправленная публикация'}
    request(edit_route,edit,method='PUT',expected=401)
    request(edit_route,edit,method='PUT',token=pending,expected=403)
    request(edit_route,edit,method='PUT',token=reader,expected=403)
    saved = request(edit_route,edit,method='PUT',token=owner)
    assert saved['revision']==2 and saved['seq']==seq
    assert datetime.fromisoformat(saved['editedAt']) >= datetime.fromisoformat(first_post['publishedAt'])
    assert request(edit_route,edit,method='PUT',token=owner) == saved
    assert request(edit_route,{**edit,'expectedRevision':2},method='PUT',token=owner) == saved
    request(edit_route,{**edit,'body':'Stale overwrite'},method='PUT',token=owner,expected=409)
    updated = request(root+'/posts',token=reader)['items'][0]
    assert updated == {**first_post,'revision':2,'body':edit['body'],'editedAt':saved['editedAt'],
                       'reactions':dict(like=1,heart=0,smile=0,mine='like')}
    aggregate_edit = request(path+'/feed',token=reader)['items'][0]
    assert aggregate_edit['editedAt'] == saved['editedAt'] and aggregate_edit['reactions'] == updated['reactions']
    for i in range(9):
        request(root+'/posts',{'requestId':str(uuid.uuid4()),'body':'🚀'*2048},token=owner,expected=201)
    aggregate=request(path+'/feed',token=reader)
    assert aggregate['items']
    assert all(p['channelId'] == channel for p in aggregate['items'])
    assert request(path+'/feed',token=outsider)['items'] == []
    first=request(root+'/posts',token=reader,max_bytes=262144)
    assert first['pinned']=={'seq':seq,'body':edit['body']} and first['pinRevision']==1
    assert seq not in [post['seq'] for post in first['items']]
    another=first['items'][0]['seq']
    request(root+'/pin',{'expectedRevision':1,'seq':another},method='PUT',token=owner,expected=204)
    request(root+'/pin',pin,method='PUT',token=owner,expected=409)
    assert request(root+'/posts',token=reader)['pinned']['seq']==another
    for _ in range(2):
        request(root+'/pin',{'expectedRevision':2,'seq':None},method='PUT',token=owner,expected=204)
    assert request(root+'/posts',token=reader)['pinned'] is None
    request(root+'/pin',{'expectedRevision':3,'seq':seq},method='PUT',token=owner,expected=204)
    assert len(first['items'])==8 and first['next']==first['items'][-1]['seq']
    older=request(root+'/posts?before='+str(first['next']),token=reader)
    assert len(older['items'])==2 and older['next'] is None and older['items'][-1]['seq']==seq
    assert not ({p['seq'] for p in first['items']} & {p['seq'] for p in older['items']})
    for i in range(11):
        request(root+'/posts',{'requestId':str(uuid.uuid4()),'body':'🌙'*2048},token=owner,expected=201)
    second={'id':str(uuid.uuid4()),'slug':'other_'+uuid.uuid4().hex[:12],'title':'Other'}
    request(path,second,token=owner,expected=201)
    second_root=path+'/'+second['id']
    request(second_root+'/subscription',token=reader,method='PUT',expected=204)
    second_seq=request(second_root+'/posts',{'requestId':str(uuid.uuid4()),'body':'Second channel'},token=owner,expected=201)['seq']
    request(f'{second_root}/posts/{seq}/reaction',{'kind':'heart'},method='PUT',token=reader,expected=404)
    request(second_root+'/pin',{'expectedRevision':0,'seq':seq},method='PUT',token=owner,expected=404)
    posts = []
    feed_path = path + '/feed'
    while True:
        page = request(feed_path, token=reader, max_bytes=262144)
        assert page['items']
        posts.extend(page['items'])
        assert len(posts) <= 22
        if page['next'] is None:
            break
        feed_path = path + '/feed?before=' + page['next']
    assert len({p['seq'] for p in posts}) == len(posts) == 22
    assert posts[0]['seq'] == second_seq
    assert {p['channelId'] for p in posts} == {channel, second['id']}
    ordered = [(p['publishedAt'], p['seq']) for p in posts]
    assert ordered == sorted(ordered, reverse=True)
    request(second_root,token=owner,method='DELETE',expected=204)
    request(root+'/posts?before=-1',token=reader,expected=400)
    request(root+'/posts/'+str(seq),token=reader,method='DELETE',expected=403)
    request(reaction,{'kind':'like'},method='PUT',token=reader)
    request(root+'/posts/'+str(seq),token=owner,method='DELETE',expected=204)
    assert request(root+'/posts',token=reader)['pinned'] is None
    assert request(root+'/posts',token=reader)['pinRevision']==5
    request(root+'/pin',{'expectedRevision':3,'seq':seq},method='PUT',token=owner,expected=404)
    request(reaction,{'kind':'like'},method='PUT',token=reader,expected=404)
    request(reaction,method='DELETE',token=owner,expected=404)
    request(edit_route,{**edit,'expectedRevision':2},method='PUT',token=owner,expected=404)
    request(root+'/posts',data,token=owner,expected=409)
    request(root,token=reader,method='DELETE',expected=403)
    request(root+'/subscription',token=reader,method='DELETE',expected=204)
    request(root+'/posts',token=reader,expected=403)
    assert request(path+'/feed',token=reader)['items'] == []
    request(root,token=owner,method='DELETE',expected=204)
    request(root+'/posts',token=owner,expected=404)
    assert request(path+'?q='+slug,token=outsider)['items']==[]
    request(path,spec,token=owner,expected=409)



def verify_channel_limits(request, outsider):
    path='/v1/public-channels'
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


def verify_reaction_quota_and_revoke(db, owner, reader, username):
    import concurrent.futures
    import delivery as d
    from delivery_recovery_serialization import hold_row, scalar, wait_for

    path = '/v1/public-channels'
    channel = uuid.uuid4()
    root = f'{path}/{channel}'
    d.request(path+'/invite-only', {'id':str(channel),'slug':'limits_'+uuid.uuid4().hex[:10],
                                   'title':'Reaction limits'}, token=owner, expected=201)
    d.request(root+'/invitations', {'username':username}, token=owner, expected=204)
    d.request(root+'/subscription', method='PUT', token=reader, expected=204)
    first, second = [
        d.request(root+'/posts', {'requestId':str(uuid.uuid4()),'body':body},
                  token=owner, expected=201)['seq']
        for body in ('Quota check', 'Removal is still available')
    ]
    reaction = f'{root}/posts/{first}/reaction'
    other = f'{root}/posts/{second}/reaction'
    heart = {'kind':'heart'}
    assert d.request(reaction, heart, method='PUT', token=reader)['heart'] == 1
    d.request(other, {'kind':'like'}, method='PUT', token=reader)
    user = uuid.UUID(d.request('/v1/users/me', token=reader)['userId'])
    scalar(db, f"UPDATE public_channel_activity SET count=240 WHERE user_id='{user}' AND action='reaction'")
    assert d.request(reaction, heart, method='PUT', token=reader)['heart'] == 1
    assert d.request(reaction, {'kind':'smile'}, method='PUT', token=reader,
                     expected=429)['code'] == 'CHANNEL_RATE_LIMIT'
    assert d.request(other, method='DELETE', token=reader)['like'] == 0
    scalar(db, f"UPDATE public_channel_activity SET count=0 WHERE user_id='{user}' AND action='reaction'")

    # Queue the reaction behind the channel row while revocation waits on membership removal.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        with hold_row(db, f"SELECT user_id FROM public_channel_subscriptions WHERE channel_id='{channel}' AND user_id='{user}' FOR UPDATE"):
            revoke = pool.submit(d.request, root+'/revoke-access', {'username':username}, token=owner, expected=204)
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'DELETE FROM public_channel_subscriptions s USING users u%'")
            change = pool.submit(d.request, reaction, {'kind':'smile'}, method='PUT', token=reader, expected=404)
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM channel_catalog WHERE id=$1 FOR SHARE%'")
        revoke.result(timeout=10)
        assert change.result(timeout=10)['code'] == 'CHANNEL_NOT_FOUND'
    assert d.request(root+'/posts', token=owner)['items'][1]['reactions'] == dict(like=0,heart=0,smile=0,mine=None)
    d.request(root, method='DELETE', token=owner, expected=204)


def verify_deleted_post_retry(db, owner):
    import concurrent.futures
    import delivery as d
    from delivery_recovery_serialization import hold_row, scalar, wait_for

    channel = uuid.uuid4()
    root = f'/v1/public-channels/{channel}'
    d.request('/v1/public-channels', {'id':str(channel),'slug':'retry_'+uuid.uuid4().hex[:12],
                                     'title':'Delete retry'}, token=owner, expected=201)
    publication = {'requestId':str(uuid.uuid4()),'body':'An existing publication'}
    seq = d.request(root+'/posts', publication, token=owner, expected=201)['seq']
    pin={'expectedRevision':0,'seq':seq}
    d.request(root+'/pin',pin,method='PUT',token=owner,expected=204)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        with hold_row(db, f"SELECT seq FROM public_channel_posts WHERE seq={int(seq)} FOR UPDATE"):
            delete = pool.submit(d.request, f'{root}/posts/{seq}', method='DELETE', token=owner, expected=204)
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'UPDATE public_channel_posts SET body=NULL%'")
            retry = pool.submit(d.request, root+'/posts', publication, token=owner, expected=409)
            pin_retry=pool.submit(d.request,root+'/pin',pin,method='PUT',token=owner,expected=404)
            wait_for(db, "wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=$1 FOR NO KEY UPDATE%'")
        delete.result(timeout=10)
        assert pin_retry.result(timeout=10)['code']=='CHANNEL_POST_NOT_FOUND'
        assert retry.result(timeout=10)['code'] == 'CHANNEL_POST_CONFLICT'
    assert d.request(root+'/posts', publication, token=owner, expected=409)['code'] == 'CHANNEL_POST_CONFLICT'
    assert d.request(root+'/posts', token=owner)['items'] == []
    assert scalar(db, f"SELECT count(*) FROM public_channel_posts WHERE seq={int(seq)} AND body IS NULL") == '1'
    d.request(root, method='DELETE', token=owner, expected=204)


def main():
    import os
    import subprocess
    import sys
    import delivery as d
    import invite_channels
    from private_blobs import database
    d.BASE='https://127.0.0.1:5119'
    with database() as db, d.Server(db) as server, tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as tmp:
        a,b,c=[d.account(Path(tmp)) for _ in range(3)]
        pending=d.login(a['username'],a['password'],d.Device(Path(tmp)))
        tokens=[a['session']['accessToken'],b['session']['accessToken'],c['session']['accessToken'],pending['accessToken']]
        verify(d.request,*tokens)
        # Start a fresh service token bucket; the two suites deliberately exercise many requests.
        server.restart()
        verify_channel_limits(d.request,tokens[2])
        invite_channels.verify(d.request,tokens[1],tokens[2],tokens[0],tokens[3],c['username'])
        verify_reaction_quota_and_revoke(db, tokens[0], tokens[1], b['username'])
        verify_deleted_post_retry(db, tokens[0])
        if '--ui' in sys.argv:
            server.restart()
            env={**os.environ,'SECUREMESH_CHANNEL_FIXTURE_URL':d.BASE,
                 'SECUREMESH_CHANNEL_FIXTURE_CA':str(d.ROOT/'.local/tls.pem'),
                 'SECUREMESH_CHANNEL_OWNER':tokens[1], 'SECUREMESH_CHANNEL_READER':tokens[0],
                 'SECUREMESH_CHANNEL_READER_USERNAME':a['username']}
            local_flutter=d.ROOT/'.local/flutter/bin/flutter'
            flutter=os.environ.get('SECUREMESH_TEST_FLUTTER',str(local_flutter) if local_flutter.exists() else 'flutter')
            subprocess.run([flutter,'test','--no-pub',
                           '--concurrency=1','integration/public_channels_hosted_test.dart'],
                           cwd=d.ROOT/'apps/client_flutter',env=env,check=True)

    print('PASS public channel ACL, idempotency, edit timestamps, reactions, deletion race, Unicode and feed pagination.')


if __name__=='__main__':
    main()
