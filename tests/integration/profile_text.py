"""Profile copy belongs to the owner and established DM peers only."""
import uuid


def verify(request, owner, peer, outsider, pending, group, owner_device):
    own = '/v1/users/me/profile-text'
    peer_url = f'/v1/conversations/{group}/profile-text/{owner_device}'
    empty = {'bio': None, 'status': None}

    def save(bio, status, revision, expected=200, token=owner):
        return request(own, {'bio': bio, 'status': status, 'revision': revision},
                       token=token, method='PUT', expected=expected)

    assert request(own, token=owner) == {**empty, 'revision': 0, 'visibleToPeers': True}
    assert request(peer_url, token=peer) == empty
    assert request(own, token=outsider) == {**empty, 'revision': 0, 'visibleToPeers': True}
    request(peer_url, token=outsider, expected=404)
    request(peer_url, token=pending, expected=403)
    request(peer_url, expected=401)
    request(f'/v1/conversations/{uuid.uuid4()}/profile-text/{owner_device}', token=peer, expected=404)
    request(f'/v1/conversations/{group}/profile-text/{uuid.uuid4()}', token=peer, expected=404)
    save('no', 'no', 0, 403, pending)
    save('no', 'no', 0, 401, None)
    updated = {'bio': 'Зоя 👩‍🔬\n天文', 'status': 'أهلاً · café'}
    assert save('  Зоя 👩‍🔬\r\n天文 ', 'أهلاً · cafe\u0301', 0) == {**updated, 'revision': 1, 'visibleToPeers': True}
    assert save(updated['bio'], updated['status'], 0) == {**updated, 'revision': 1, 'visibleToPeers': True}
    save('stale update', None, 0, 409)
    assert request(peer_url, token=peer) == updated
    assert all('bio' not in row and 'status' not in row for row in request('/v1/conversations',token=peer))
    for bio, status in [('x'*281,None),(None,'x'*81),('a\u202eb',None),(None,'x\ny'),(None,'\u200c')]:
        save(bio, status, 1, 400)
    request(own, {'bio': None}, token=owner, method='PUT', expected=400)
    assert request(peer_url, token=peer) == updated
    hidden = request(own, {**updated, 'revision': 1, 'visibleToPeers': False}, token=owner, method='PUT')
    assert hidden == {**updated, 'revision': 2, 'visibleToPeers': False}
    assert request(peer_url, token=peer) == empty
    assert request(own, token=owner) == hidden
    # Earlier clients omit visibility. An edit preserves the owner's choice.
    save('private note', None, 2)
    assert request(peer_url, token=peer) == empty
    request(own, {**updated, 'revision': 2, 'visibleToPeers': True}, token=owner, method='PUT', expected=409)
    revealed = request(own, {**updated, 'revision': 3, 'visibleToPeers': True}, token=owner, method='PUT')
    assert revealed['revision'] == 4 and request(peer_url, token=peer) == updated
    for blocker in (owner, peer):
        username = next(row['peerName'] for row in request('/v1/conversations', token=blocker) if row['id'] == group)
        route = '/v1/contact-blocks/' + username
        request(route, method='PUT', token=blocker, expected=204)
        assert request(peer_url, token=peer) == empty
        request(route, method='DELETE', token=blocker, expected=204)
        assert request(peer_url, token=peer) == updated
    assert save(None,None,4) == {**empty, 'revision': 5, 'visibleToPeers': True}
    assert request(peer_url, token=peer) == empty

if __name__ == '__main__':
    import tempfile
    from pathlib import Path
    import delivery as d
    from directory import establish
    from private_blobs import database
    d.BASE = 'https://127.0.0.1:5086'
    with database() as db, d.Server(db, legacy_bootstrap=False), tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as tmp:
        root = Path(tmp)
        a, b, outsider = [d.account(root) for _ in range(3)]
        a['device'].pin(b['device'])
        b['device'].pin(a['device'])
        group = establish(a,b)
        pending = d.login(a['username'],a['password'],d.Device(root))
        verify(d.request, a['session']['accessToken'], b['session']['accessToken'], outsider['session']['accessToken'],
               pending['accessToken'], group, a['device'].identity)
    print('Profile visibility, legacy updates, optimistic concurrency and peer access passed over HTTPS')
