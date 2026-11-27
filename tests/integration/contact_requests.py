"""Pending requests can be dismissed by either participant without breaking accepted MLS invitations."""
import uuid


def verify(request, sender, recipient, stranger, username):
    path = '/v1/chat-requests'
    for token in [sender, recipient]:
        payload = {'id': str(uuid.uuid4()), 'username': username}
        request(path, payload, token=sender, expected=201)
        item = path + '/' + payload['id']
        request(item + '/dismiss', {}, token=stranger, expected=404)
        for _ in range(2):
            request(item + '/dismiss', {}, token=token, expected=204)
        request(path, payload, token=sender)
        request(item + '/accept', {}, token=recipient, expected=404)
        assert all(r['id'] != payload['id'] for r in request(path, token=recipient))
