"""Invite-only discoverability, exact account matching, legacy read visibility and post revisions."""
import uuid


def verify(request, owner, reader, outsider, pending, username):
    path='/v1/public-channels'
    handle='private_'+uuid.uuid4().hex[:12]
    spec={'id':str(uuid.uuid4()),'title':'Team','slug':handle}
    root=path+'/'+spec['id']
    create=request(path+'/invite-only',spec,token=owner,expected=201)
    assert create['inviteOnly'] is True
    listing=path+'?includeRestricted=true&q='+handle
    assert request(listing,token=owner)['items'][0]['inviteOnly']
    assert request(path+'?q='+handle,token=owner)['items']==[]
    assert request(listing,token=reader)['items']==[]
    assert request(listing,token=outsider)['items']==[]
    # A public handle may coincide, so handle availability never reveals a restricted room.
    public={'id':str(uuid.uuid4()),'title':'Anyone','slug':handle}
    request(path,public,token=outsider,expected=201)
    assert [x['id'] for x in request(listing,token=reader)['items']]==[public['id']]
    request(path+'/'+public['id'],token=outsider,method='DELETE',expected=204)
    request(root+'/subscription',token=reader,method='PUT',expected=404)
    request(root+'/posts',token=reader,expected=404)
    request(root,token=outsider,method='DELETE',expected=404)
    pub=request(root+'/posts',{'requestId':str(uuid.uuid4()),'body':'Original'},token=owner,expected=201)
    seq=pub['seq']
    editpath=root+'/posts/'+str(seq)
    reaction=editpath+'/reaction'
    request(reaction,{'kind':'heart'},token=outsider,method='PUT',expected=404)
    def invite(who,token=owner,expected=204):
        return request(root+'/invitations',{'username':who},token=token,expected=expected)
    invite(username+'!',expected=400)
    invite('no_such_'+uuid.uuid4().hex[:14])
    assert request(listing,token=reader)['items']==[]
    invite(username)
    invite(username.upper())
    assert request(listing,token=reader)['items'][0]['invited'] is True
    request(root+'/posts',token=reader,expected=403)
    request(reaction,{'kind':'heart'},token=reader,method='PUT',expected=403)
    invite(username,token=reader,expected=403)
    request(root+'/subscription',token=pending,method='PUT',expected=403)
    request(root+'/subscription',token=reader,method='DELETE',expected=204)
    assert request(listing,token=reader)['items']==[]
    invite(username)
    request(root+'/subscription',token=reader,method='PUT',expected=204)
    assert request(listing,token=reader)['items'][0]['subscribed']
    assert all(p['channelId'] != spec['id'] for p in request(path+'/feed',token=reader)['items'])
    before=request(root+'/posts',token=reader)['items'][0]
    assert before['revision']==1 and before['body']=='Original'
    edit={'expectedRevision':1,'body':'Corrected'}
    request(editpath,edit,token=reader,method='PUT',expected=403)
    request(editpath,edit,token=outsider,method='PUT',expected=404)
    request(editpath,edit,token=pending,method='PUT',expected=403)
    assert request(editpath,edit,token=owner,method='PUT')['revision']==2
    assert request(editpath,edit,token=owner,method='PUT')['revision']==2
    request(editpath,{'expectedRevision':1,'body':'Lost write'},token=owner,method='PUT',expected=409)
    after=request(root+'/posts',token=reader)['items'][0]
    assert after=={**before,'body':'Corrected','revision':2}
    request(root+'/subscription',token=reader,method='DELETE',expected=204)
    request(root+'/posts',token=reader,expected=404)
    request(root+'/subscription',token=reader,method='PUT',expected=404)
    invite(username)
    request(root+'/subscription',token=reader,method='PUT',expected=204)
    request(root+'/revoke-access',{'username':username},token=reader,expected=403)
    assert request(reaction,{'kind':'heart'},token=reader,method='PUT')['heart']==1
    request(root+'/revoke-access',{'username':username},token=owner,expected=204)
    request(reaction,method='DELETE',token=reader,expected=404)
    request(reaction,{'kind':'smile'},token=reader,method='PUT',expected=404)
    assert request(root+'/posts',token=owner)['items'][0]['reactions']['heart']==0
    request(root+'/posts',token=reader,expected=404)
    assert request(listing,token=reader)['items']==[]
    request(root,token=owner,method='DELETE',expected=204)
