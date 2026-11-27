"""Profile metadata contract on an established DM with two trusted peers and a stranger."""


def verify(request, owner, peer, outsider, pending, group, username):
    path = '/v1/users/me/display-name'

    def update(value, token=owner, expected=200):
        return request(path, {'displayName': value}, token=token, method='PUT', expected=expected)

    def peer_row():
        return next(row for row in request('/v1/conversations', token=peer) if row['id'] == group)

    original = peer_row()
    assert original['peerName'] == username and original['peerDisplayName'] is None
    update('untrusted edit', token=pending, expected=403)
    update('anonymous edit', token=None, expected=401)
    assert update('  Елена 👩‍🔬  ') == {'displayName': 'Елена 👩‍🔬'}
    assert request('/v1/users/me', token=owner)['displayName'] == 'Елена 👩‍🔬'
    updated = peer_row()
    assert updated == {**original, 'peerDisplayName': 'Елена 👩‍🔬'}
    assert request('/v1/conversations', token=outsider) == []
    assert request('/v1/users/me', token=outsider)['displayName'] is None
    for invalid in ('a' * 65, 'a\nb', 'test\u202e', '\u200d'):
        update(invalid, expected=400)
    request(path, {}, token=owner, method='PUT', expected=400)
    assert peer_row()['peerDisplayName'] == 'Елена 👩‍🔬'
    assert update('e\u0301') == {'displayName': 'é'}
    assert update('𐐀' * 64) == {'displayName': '𐐀' * 64}
    assert update(None) == {'displayName': None}
    assert peer_row() == original
