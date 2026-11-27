"""Exercise both password versions over the normal HTTPS API with real device proofs."""
import json
import subprocess
import urllib.parse
import urllib.request
import uuid

import process_spike


def verify(d, root, legacy):
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
    d.request('/v2/auth/register', {**registration, 'credential': cred}, expected=202)
    query = urllib.parse.urlencode({'query': 'to:' + email})
    with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/search?' + query) as response:
        message, = json.load(response)['messages']
    with urllib.request.urlopen('http://127.0.0.1:58028/api/v1/message/' + message['ID']) as response:
        token = json.load(response)['Text'].strip()
    d.request('/v1/auth/verify-email', {'token': token}, expected=204)

    def login(version, user, device, fields, expected=200):
        ch = d.request('/v1/auth/challenge', dict(username=user, deviceId=device.identity))
        signature = device.call('sign', payload=ch['payload'])['signature']
        return d.request(f'/v{version}/auth/login', dict(username=user, deviceId=device.identity,
            publicKey=device.public, signature=signature, challengeId=ch['challengeId'], **fields), expected=expected)

    device = d.Device(root)
    login(1, username, device, {'password': cred}, 401)
    login(2, username, device, {'password': master}, 401)
    login(2, legacy['username'], legacy['device'], {'credential': cred}, 401)
    session = login(2, username, device, {'credential': cred})
    assert session['trustState'] == 'DEVICE_TRUSTED'
    assert d.request('/v1/users/me', token=session['accessToken'])['displayName'] == name
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
