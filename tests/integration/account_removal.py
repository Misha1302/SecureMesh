#!/usr/bin/env python3
"""Remove one synthetic account in an isolated PostgreSQL database and retain its peer's history."""
import base64
import concurrent.futures
import hashlib
import os
import subprocess
import tempfile
import uuid
from pathlib import Path
from unittest.mock import patch

import delivery as d
from directory import establish
from private_blobs import blob, database, postgres


def verify(server, source, root):
    a, b = d.account(root, 'example.org'), d.account(root)
    da, db = a['device'], b['device']
    at, bt = a['session']['accessToken'], b['session']['accessToken']
    da.pin(db)
    db.pin(da)
    group = establish(a,b)
    old = da.call('queue',group=group,id=str(uuid.uuid4()),text='Preserve peer-owned history')
    d.request('/v1/messages',d.envelope(old,group),token=at)
    d.sync(db,bt,group)
    pending = d.Device(root)
    pt = d.login(a['username'],a['password'],pending)['accessToken']
    d.request('/v1/devices/enrollment',{},token=pt)
    profile = d.request('/v1/users/me',token=at)
    owner = profile['userId']
    assert profile['labAccountRemoval'] and not d.request('/v1/users/me',token=pt)['labAccountRemoval']
    d.request('/v1/users/me/display-name',{'displayName':'Private Owner'},method='PUT',token=at)
    d.request('/v1/users/me/photo',{'pixels':base64.b64encode(bytes(6912)).decode()},method='PUT',token=at)
    channel = str(uuid.uuid4())
    path='/v1/public-channels'
    d.request(path,dict(id=channel,slug='lab_remove',title='Lab remove'),token=at,expected=201)
    d.request(f'{path}/{channel}/posts',dict(requestId=str(uuid.uuid4()),body='Lab post'),token=at,expected=201)
    d.request(f'{path}/{channel}/subscription',method='PUT',token=bt,expected=204)
    route=f'/v1/conversations/{group}/blobs/{uuid.uuid4()}'
    blob(route,at,'PUT',201,b'x'*32)
    partial=f'/v1/conversations/{group}/blobs/{uuid.uuid4()}'
    data=b'z'*33000
    blob(partial+'/parts?offset=0',at,'PUT',200,data[:32768],extra={
        'X-Blob-Length':str(len(data)),'X-Blob-SHA256':hashlib.sha256(data).hexdigest()})
    remove='/v1/users/me/removal'
    args={'requestId':da.identity,'password':a['password']}
    d.request(remove,args,expected=401)
    d.request(remove,args,token=pt,expected=403)
    d.request(remove,{**args,'password':'wrong-password'},token=at,expected=403)
    d.request(remove,args,token=bt,expected=403)
    assert d.request('/v1/users/me',token=at)['userId']==owner
    def query(sql):
        return postgres('psql','-U','securemesh','-d',source,'-XAtqc',sql,stdout=subprocess.PIPE,text=True).stdout.strip()
    other = d.request('/v1/users/me',token=bt)['userId']
    server.env['EnableLabAccountRemoval']='false'
    server.restart()
    d.request(remove,args,token=at,expected=404)
    assert not d.request('/v1/users/me',token=at)['labAccountRemoval']
    server.env['EnableLabAccountRemoval']='true'
    server.restart()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        results=[pool.submit(d.request,remove,args,at,expected=204) for _ in range(2)]
        for result in results: result.result()
    server.restart()
    d.request(remove,args,token=at,expected=204)
    d.request(remove,{**args,'requestId':str(uuid.uuid4())},token=at,expected=401)
    for token in (at,pt): d.request('/v1/users/me',token=token,expected=401)
    d.request('/v1/auth/refresh',{'token':a['session']['refreshToken']},expected=401)
    d.login(a['username'],a['password'],da,expected=401)
    for table,predicate in (
        ('users',f"id='{owner}' OR username='{a['username']}' OR email='{a['username']}@example.org'"),
        ('devices',f"user_id='{owner}'"),('auth_challenges',f"username='{a['username']}'"),
        ('sessions',f"device_id IN ('{da.identity}','{pending.identity}')"),
        ('private_blobs',f"owner_id='{owner}'"),('private_blob_uploads',f"owner_id='{owner}'"),
        ('device_enrollments',f"user_id='{owner}'"),('key_packages','true'),('chat_requests','true'),
        ('conversation_bootstraps','true'),('profile_photos',f"user_id='{owner}'"),
        ('channel_catalog',f"owner_id='{owner}'"),('public_channel_posts',f"channel_id='{channel}'"),
        ('public_channel_subscriptions',f"channel_id='{channel}'"),('email_tokens',f"user_id='{owner}'")):
        assert query(f'SELECT count(*) FROM {table} WHERE {predicate}')=='0',table
    assert query('SELECT count(*) FROM account_removal_receipts')=='1'
    assert query(f"SELECT count(*) FROM device_identifiers WHERE id='{da.identity}'")=='1'
    assert d.request('/v1/users/me',token=bt)['userId']==other
    assert d.request(path+'?q=lab_remove',token=bt)['items']==[]
    blob(route,bt,'GET',404)
    blob(partial+'/parts',bt,'GET',404)
    blob(route,bt,'PUT',409,b'y'*32)
    retained = d.request(f'/v1/sync?conversationId={group}&limit=1',token=bt)['messages']
    assert len(retained)==1 and retained[0]['senderDeviceId']==da.identity
    assert db.call('history',group=group)['events'][0]['text']=='Preserve peer-owned history'
    fresh=db.call('queue',group=group,id=str(uuid.uuid4()),text='stopped')
    d.request('/v1/messages',d.envelope(fresh,group),token=bt,expected=409)
    d.request('/v1/messages',d.envelope(old,group),token=at,expected=401)
    d.login(b['username'],b['password'],da,expected=403)
    print('PASS: fresh verified password and trusted session; verified example.org synthetic account; wrong password, pending device and disabled deployment denied; concurrent idempotent removal; server restart; credentials, device grants, identity, contacts, private media, staged uploads and owned channels gone; original peer SQLCipher history and server replay intact; old conversation writes denied.')


def hosted_ui(root):
    flutter=Path(os.environ.get('SECUREMESH_TEST_FLUTTER',d.ROOT/'.local/flutter/bin/flutter'))
    if not flutter.is_file(): return
    account=d.account(root,'example.net')
    device=account['device']
    session=account['session']
    device.call('profile_put',profile={**session,'username':account['username'],'deviceId':device.identity,
        'endpoint':d.BASE,'trustConfirmed':True})
    env={**os.environ,'SECUREMESH_PROFILE':str(device.path),'SECUREMESH_PROFILE_DIRECTORY':str(root),
        'SECUREMESH_REMOVE_PASSPHRASE':device.password,'SECUREMESH_REMOVE_PASSWORD':account['password'],
        'SECUREMESH_CRYPTO_LIB':str(d.ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'),
        'SECUREMESH_CERT_FILE':str(d.ROOT/'.local/tls.pem'),'FLUTTER_SUPPRESS_ANALYTICS':'true','DART_SUPPRESS_ANALYTICS':'true'}
    subprocess.run([str(flutter),'--suppress-analytics','test','--no-pub','--concurrency=1',
        'integration/account_removal_hosted_test.dart'],cwd=d.ROOT/'apps/client_flutter',env=env,check=True,timeout=100)
    d.request('/v1/users/me',token=session['accessToken'],expected=401)
    assert not device.path.exists()
    print('PASS: actual native ClientApp Settings dialog, SQLCipher unlock and TLS account removal, profile file removed and prior session rejected.')


def main():
    d.BASE='https://127.0.0.1:5104'
    with database() as source, tempfile.TemporaryDirectory(dir=d.ROOT/'.local') as tmp:
        with patch.dict(os.environ,{'EnableLabAccountRemoval':'true'}), d.Server(database=source,legacy_bootstrap=False) as server:
            verify(server,source,Path(tmp))
            import credential_versions
            account = credential_versions.verify(d, Path(tmp), d.account(Path(tmp)))
            token = account['session']['accessToken']
            request_id = str(uuid.uuid4())
            confirmation = dict(requestId=request_id)
            d.request('/v1/users/me/removal', {**confirmation, 'password': account['credential']}, token=token, expected=403)
            d.request('/v1/users/me/removal', {**confirmation, 'credential': account['credential']}, token=token, expected=204)
            d.request('/v1/users/me', token=token, expected=401)
            hosted_ui(Path(tmp))


if __name__=='__main__':main()
