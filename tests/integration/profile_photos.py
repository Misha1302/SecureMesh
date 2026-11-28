"""Exercise optional photo storage, version-only listings and DM-scoped reads."""
import base64
import uuid


def verify(request, owner, peer, outsider, pending, group):
    path = '/v1/users/me/photo'
    def put(image, token=owner, expected=200):
        return request(path, {'pixels': image}, token=token, method='PUT', expected=expected)
    def row():
        return next(x for x in request('/v1/conversations', token=peer) if x['id'] == group)
    def fetch(version, token=peer, room=group, expected=200):
        return request(f'/v1/conversations/{room}/photo/{version}', token=token, expected=expected)

    assert request(path, token=owner) == {'pixels': None}
    assert row()['peerPhotoVersion'] is None
    first = base64.b64encode(bytes([1,2,3]) * 2304).decode()
    second = base64.b64encode(bytes([0,11,33]) * 2304).decode()
    put(first, token=pending, expected=403)
    put(first, token=None, expected=401)
    put('Ag==', expected=400)
    request(path, {}, token=owner, method='PUT', expected=400)
    v1 = put(first)['photoVersion']
    assert put(first)['photoVersion'] == v1
    assert request(path, token=owner) == {'pixels': first}
    listing = row()
    assert listing['peerPhotoVersion'] == v1 and 'pixels' not in listing
    assert fetch(v1) == {'pixels': first}
    fetch(v1, token=outsider, expected=404)
    fetch(v1, token=pending, expected=403)
    fetch(v1, room=str(uuid.uuid4()), expected=404)
    for blocker in (owner, peer):
        target = next(chat['peerName'] for chat in request('/v1/conversations', token=blocker)
                      if chat['id'] == group)
        route = '/v1/contact-blocks/' + target
        request(route, method='PUT', token=blocker, expected=204)
        assert row()['peerPhotoVersion'] is None
        fetch(v1, expected=404)
        assert request(path, token=owner) == {'pixels': first}
        request(route, method='DELETE', token=blocker, expected=204)
        assert row()['peerPhotoVersion'] == v1 and fetch(v1) == {'pixels': first}
    v2 = put(second)['photoVersion']
    assert v2 != v1 and fetch(v2) == {'pixels': second}
    fetch(v1, expected=404)
    assert put(None) == {'photoVersion': None}
    assert row()['peerPhotoVersion'] is None and request(path, token=owner) == {'pixels': None}
    fetch(v2, expected=404)
