"""Exercise both password versions over the normal HTTPS API with real device proofs."""
import json
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


def verify(d, root, legacy):
    import process_spike
    from directory import establish

    username = 'v2_' + uuid.uuid4().hex[:20]
    email = username + '@securemesh.test'
    name = 'Елена 👩‍🔬 李'
    master = 'Фраза-' + uuid.uuid4().hex
    def derive(origin, principal):
        req = dict(op='derive_server_credential_v2', endpoint=origin, username=principal, password=master)
        output = subprocess.check_output([str(process_spike.BIN), ''], input=json.dumps(req), text=True)
        return json.loads(output)['credential']

    cred = derive(d.BASE, username)
    assert cred != derive(d.BASE, legacy['username']) and cred != derive('https://example.org', username)
    registration = dict(username=username, email=email, displayName=name)
    d.request('/v2/auth/register', {**registration, 'password': master}, expected=400)
    d.request('/v2/auth/register', {**registration, 'credential': 'invalid'}, expected=400)
    d.request('/v2/auth/register', {**registration, 'credential': cred, 'password': master}, expected=400)
    d.request('/v1/auth/register', {**registration, 'credential': cred}, expected=400)
    d.request('/v1/auth/register', {**registration, 'password': '👩‍🔬' * 15}, expected=400)
    d.request('/v2/auth/register', {**registration, 'credential': cred}, expected=202)
    query = urllib.parse.urlencode({'query': 'to:' + email})
    with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/search?' + query) as response:
        message, = json.load(response)['messages']
    with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/message/' + message['ID']) as response:
        token = json.load(response)['Text'].strip()
    d.request('/v1/auth/verify-email', {'token': token}, expected=204)

    def login(version, user, device, fields, expected=200, action='login'):
        ch = d.request('/v1/auth/challenge', dict(username=user, deviceId=device.identity))
        signature = device.call('sign', payload=ch['payload'])['signature']
        return d.request(f'/v{version}/auth/{action}', dict(username=user, deviceId=device.identity,
            publicKey=device.public, signature=signature, challengeId=ch['challengeId'], **fields), expected=expected)

    device = d.Device(root)
    login(1, username, device, {'password': cred}, 401)
    login(2, username, device, {'password': master}, 401)
    login(2, legacy['username'], legacy['device'], {'credential': cred}, 401)
    session = login(2, username, device, {'credential': cred})
    assert session['trustState'] == 'DEVICE_TRUSTED'
    me = d.request('/v1/users/me', token=session['accessToken'])
    assert me['displayName'] == name
    expected_identity = dict(expectedUserId=me['userId'], expectedTrustState=me['trustState'])
    fields = dict(credential=cred, **expected_identity)
    unknown = d.Device(root)
    login(2, username, unknown, fields, 403, 'reauthenticate')
    login(2, username, device, dict(fields, expectedUserId=str(uuid.uuid4())), 403, 'reauthenticate')
    login(2, username, device, dict(fields, expectedTrustState='DEVICE_PENDING_TRUST'), 403, 'reauthenticate')
    devices = d.request('/v1/devices', token=session['accessToken'])
    assert [row['id'] for row in devices] == [device.identity]

    # Reauthorize the same MLS identity while a real encrypted outbox row is
    # pending, then deliver that immutable row with the new session.
    peer = legacy['device']
    device.pin(peer); peer.pin(device)
    group = establish(dict(username=username, device=device, session=session), legacy)
    queued = device.call('queue', group=group, id=str(uuid.uuid4()), text='Queued before reauthentication')
    d.request('/v1/auth/logout', {}, token=session['accessToken'], expected=204)
    d.request('/v1/users/me', token=session['accessToken'], expected=401)
    replacement = login(2, username, device, fields, action='reauthenticate')
    assert replacement['accessToken'] != session['accessToken']
    assert replacement['deviceId'] == device.identity and replacement['trustState'] == 'DEVICE_TRUSTED'
    token = replacement['accessToken']
    assert d.request('/v1/users/me', token=token) == me
    assert device.call('identity')['public_key'] == device.public
    assert queued in device.call('outbox')['messages']
    assert d.request('/v1/messages', d.envelope(queued, group), token=token)['durable']
    session = replacement
    assert login(2, username, d.Device(root), {'credential': cred})['trustState'] == 'DEVICE_PENDING_TRUST'
    assert d.login(legacy['username'], legacy['password'], legacy['device'])['trustState'] == 'DEVICE_TRUSTED'
    path = root / 'v2-store.db'
    def local(op, secret, **args):
        return subprocess.run([str(process_spike.BIN), str(path)], input=json.dumps(dict(
            op=op, passphrase=secret, **args)), text=True, capture_output=True)
    assert local('init', master, identity=str(uuid.uuid4()), onboarding=dict(
        endpoint=d.BASE, username=username, registeredHere=True, credentialVersion=2)).returncode == 0
    assert json.loads(local('onboarding_state', master).stdout)['draft']['credentialVersion'] == 2
    assert local('identity', cred).returncode != 0
    assert local('identity', master).returncode == 0
    return dict(username=username, password=master, credential=cred, session=session, device=device)


def main():
    import delivery as d
    from private_blobs import database

    with database() as db, tempfile.TemporaryDirectory(dir=d.ROOT / '.local') as work, d.Server(db):
        root = Path(work)
        verify(d, root, d.account(root))
    print('PASS: v1/v2 credential isolation, v2 same-device reauthentication and durable MLS outbox delivery.')


if __name__ == '__main__':
    main()
