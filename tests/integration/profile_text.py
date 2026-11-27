"""Profile copy belongs to the owner and established DM peers only."""
import uuid


def verify(request, owner, peer, outsider, pending, group, owner_device):
    own = '/v1/users/me/profile-text'
    peer_url = f'/v1/conversations/{group}/profile-text/{owner_device}'
    empty = {'bio': None, 'status': None}

    def save(bio, status, revision, expected=200, token=owner):
        return request(own, {'bio': bio, 'status': status, 'revision': revision},
                       token=token, method='PUT', expected=expected)

    assert request(own, token=owner) == {**empty, 'revision': 0}
    assert request(peer_url, token=peer) == empty
    assert request(own, token=outsider) == {**empty, 'revision': 0}
    request(peer_url, token=outsider, expected=404)
    request(peer_url, token=pending, expected=403)
    request(peer_url, expected=401)
    request(f'/v1/conversations/{uuid.uuid4()}/profile-text/{owner_device}', token=peer, expected=404)
    request(f'/v1/conversations/{group}/profile-text/{uuid.uuid4()}', token=peer, expected=404)
    save('no', 'no', 0, 403, pending)
    save('no', 'no', 0, 401, None)
    updated = {'bio': 'Зоя 👩‍🔬\n天文', 'status': 'أهلاً · café'}
    assert save('  Зоя 👩‍🔬\r\n天文 ', 'أهلاً · cafe\u0301', 0) == {**updated, 'revision': 1}
    assert save(updated['bio'], updated['status'], 0) == {**updated, 'revision': 1}
    save('stale update', None, 0, 409)
    assert request(peer_url, token=peer) == updated
    assert all('bio' not in row and 'status' not in row for row in request('/v1/conversations',token=peer))
    for bio, status in [('x'*281,None),(None,'x'*81),('a\u202eb',None),(None,'x\ny'),(None,'\u200c')]:
        save(bio, status, 1, 400)
    request(own, {'bio': None}, token=owner, method='PUT', expected=400)
    assert request(peer_url, token=peer) == updated
    assert save(None,None,1) == {**empty, 'revision': 2}
    assert request(peer_url, token=peer) == empty
