"""Exercise comment access after revocation, quota and moderation through HTTPS."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import uuid
import delivery as d
from private_blobs import database


def run():
    d.BASE='https://127.0.0.1:5268'
    with database() as db, d.Server(db), tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as tmp:
        owner,member,outsider=[d.account(Path(tmp)) for _ in range(3)]
        def call(route,actor,data=None,**kw):
            return d.request(route,data,token=actor['session']['accessToken'],**kw)
        base='/v1/public-channels'
        spec={'id':str(uuid.uuid4()),'slug':'team_'+uuid.uuid4().hex[:12],'title':'Comments'}
        call(base+'/invite-only',owner,spec,expected=201)
        room=base+'/'+spec['id']
        def message(body):
            return {'requestId':str(uuid.uuid4()),'body':body}
        post=room+'/posts/'+str(call(room+'/posts',owner,message('Post'),expected=201)['seq'])
        path=post+'/comments'
        call(path,outsider,expected=404)
        call(path,outsider,message('Hidden'),expected=404)
        call(room+'/invitations',owner,{'username':member['username']},expected=204)
        call(path,member,expected=403)
        call(room+'/subscription',member,method='PUT',expected=204)
        first=message('First')
        own=call(path,owner,first,expected=201)['id']
        assert call(path,owner,first)['id']==own
        call(path,owner,{**first,'body':'Changed'},expected=409)
        call(path+'/'+str(own),member,method='DELETE',expected=404)
        mine=call(path,member,message('Delete by author'),expected=201)['id']
        call(path+'/'+str(mine),member,method='DELETE',expected=204)
        retry=message('Delete by moderator')
        moderated=call(path,member,retry,expected=201)['id']
        call(path+'/'+str(moderated),owner,method='DELETE',expected=204)
        call(path,member,retry,expected=409)
        for n in range(16):
            call(path,member,message(str(n)),expected=201)
        page=call(path,member)
        assert len(page['items'])==16 and all(row['canDelete'] for row in page['items'])
        old=call(path+'?before='+str(page['next']),member)
        assert old['items']==[dict(id=own,body='First',username=owner['username'],canDelete=False)] and old['next'] is None
        from delivery_recovery_serialization import hold_row, newest_code, scalar as sql, wait_for
        with ThreadPoolExecutor(max_workers=2) as pool:
            with hold_row(db,f"SELECT 1 FROM public_channel_subscriptions WHERE channel_id='{spec['id']}' FOR UPDATE"):
                revoke=pool.submit(call,room+'/revoke-access',owner,{'username':member['username']},expected=204)
                wait_for(db,"wait_event_type='Lock' AND query LIKE 'DELETE FROM public_channel_subscriptions%'")
                late=pool.submit(call,path,member,message('Queued behind revocation'),expected=404)
                wait_for(db,"wait_event_type='Lock' AND query LIKE 'SELECT id FROM channel_catalog%FOR SHARE%'")
            revoke.result(timeout=5)
            late.result(timeout=5)
        call(path,member,expected=404)
        call(path,member,message('Revoked'),expected=404)
        call(path+'/'+str(page['items'][0]['id']),member,method='DELETE',expected=404)
        other_seq=call(room+'/posts',owner,message('Independent post'),expected=201)['seq']
        other_post=f'{room}/posts/{other_seq}'
        expired=call(other_post+'/comments',owner,message('Expired tombstone'),expected=201)['id']
        call(f'{other_post}/comments/{expired}',owner,method='DELETE',expected=204)
        sql(db,f"UPDATE public_channel_comments SET deleted_at=now()-interval '2 days' WHERE id={expired}")
        # A live write can proceed while a different post's expired tombstone is locked.
        with ThreadPoolExecutor(max_workers=1) as pool:
            with hold_row(db,f'SELECT id FROM public_channel_comments WHERE id={expired} FOR UPDATE'):
                independent=pool.submit(call,path,owner,message('Independent write'),expected=201)
                assert independent.result(timeout=3)['id'] > expired
        sql(db,f"""INSERT INTO public_channel_comments(post_seq,user_id,request_id,body,deleted_at)
                   SELECT {other_seq},u.id,gen_random_uuid(),NULL,now()-interval '1 hour' FROM users u,
                   generate_series(1,1024) WHERE u.username='{owner['username']}'""")
        call(path,owner,message('Recent moderation consumes account capacity'),expected=409)
        sql(db,f"UPDATE public_channel_comments SET deleted_at=now()-interval '2 days' WHERE post_seq={other_seq}")
        call(path,owner,message('Expired moderation releases account capacity'),expected=201)
        call(other_post,owner,method='DELETE',expected=204)
        post_seq=int(post.split('/')[-1])
        sql(db, f"""INSERT INTO public_channel_comments(post_seq,user_id,request_id,body)
                   SELECT {post_seq},u.id,gen_random_uuid(),'quota fixture' FROM users u,
                   generate_series(1,512) WHERE u.username='{owner['username']}'""")
        call(path,owner,message('Post capacity'),expected=409)
        sql(db,"DELETE FROM public_channel_comments WHERE body='quota fixture'")
        sql(db,"UPDATE public_channel_activity SET count=60 WHERE action='comment'")
        call(path,owner,message('Rate limit'),expected=429)
        public=dict(spec,id=str(uuid.uuid4()),slug='pub_'+uuid.uuid4().hex[:12])
        call(base,owner,public,expected=201)
        open_room=base+'/'+public['id']
        open_seq=call(open_room+'/posts',owner,message('Public'),expected=201)['seq']
        open_path=f'{open_room}/posts/{open_seq}/comments'
        call(open_path,outsider,expected=403)
        call(open_path,outsider,message('Unsubscribed'),expected=403)
        call(open_room+'/subscription',outsider,method='PUT',expected=204)
        assert call(open_path,outsider)['items']==[]
        call(open_room+'/posts/'+post.split('/')[-1]+'/comments',outsider,expected=404)
        call(post,owner,method='DELETE',expected=204)
        call(path,owner,expected=404)
        assert sql(db,'SELECT count(*) FROM public_channel_comments').strip()=='0'
        # Recovery wins the owner lock while the old credentials are still visible to HTTP auth.
        owner_device=uuid.UUID(owner['device'].identity)
        code=newest_code(owner['username']+'@securemesh.test')
        recovery={'token':code,'password':'recovered-'+uuid.uuid4().hex,'username':owner['username']}
        with ThreadPoolExecutor(max_workers=4) as pool:
            with hold_row(db,f"SELECT id FROM sessions WHERE device_id='{owner_device}' FOR UPDATE"):
                reset=pool.submit(d.request,'/v1/auth/recovery/complete',recovery,expected=204)
                wait_for(db,"wait_event_type='Lock' AND query LIKE 'UPDATE sessions SET revoked=true%'")
                reads=[pool.submit(call,route,owner,expected=401) for route in
                       (open_room+'/posts',base+'/feed',open_path)]
                wait_for(db,"wait_event_type='Lock' AND query LIKE 'SELECT id FROM users WHERE id=$1 FOR SHARE%'",3)
            reset.result(timeout=5)
            assert all(read.result(timeout=5)=={'code':'AUTH_REQUIRED'} for read in reads)
    print('PASS restricted comments, retries, keyset pagination, moderation, concurrent revocation and independent posts, quotas and post deletion')


if __name__=='__main__':
    run()
