#!/usr/bin/env python3
"""Real API/PG/SQLCipher/OpenMLS signer trust-boundary tests; no shared private keys."""
import base64
import concurrent.futures
import json
import subprocess
import tempfile
import uuid
from pathlib import Path
import delivery as d


def sql(statement):
    return subprocess.check_output(['docker', 'compose', 'exec', '-T', 'db', 'psql', '-U', 'securemesh', '-d', 'securemesh', '-v', 'ON_ERROR_STOP=1', '-Atc', statement], cwd=d.ROOT, text=True)


def start(owner, candidate):
    session=d.login(owner['username'], owner['password'], candidate)
    assert session['trustState']=='DEVICE_PENDING_TRUST'
    token=session['accessToken']
    request=d.request('/v1/devices/enrollment', {}, token=token)
    account=d.request('/v1/users/me', token=token)['userId']
    proof=candidate.call('enrollment_proof',payload=request['payload'],account=account)['signature']
    d.request(f"/v1/devices/enrollment/{request['id']}/proof",dict(signature=proof),token=token,expected=204)
    return session,request,account,proof


def main():
    d.BASE='https://127.0.0.1:5093'
    with d.Server(),tempfile.TemporaryDirectory(prefix='securemesh-enrollment-',dir=d.ROOT/'.local') as tmp:
        root=Path(tmp)
        a,b=[d.account(root) for _ in range(2)]
        da,db=a['device'],b['device'];at,bt=a['session']['accessToken'],b['session']['accessToken']
        candidate=d.Device(root)
        session,request,account,proof=start(a,candidate)
        token=session['accessToken'];rid=request['id'];payload=request['payload']
        assert da.public!=candidate.public
        assert d.request('/v1/users/me',token=token)['trustState']=='DEVICE_PENDING_TRUST'
        d.request('/v1/devices',token=token,expected=403)
        d.request('/v1/conversations',dict(id=str(uuid.uuid4()),deviceIds=[da.identity,candidate.identity]),token=token,expected=403)
        d.request('/v1/sync?conversationId='+str(uuid.uuid4()),token=token,expected=403)
        d.request('/v1/devices/'+da.identity,token=token,method='DELETE',expected=403)
        d.request(f'/v1/devices/enrollment/{rid}',token=bt,expected=404)
        d.request(f'/v1/devices/enrollment/{rid}/approve',dict(signature=proof),token=bt,expected=409)
        d.request(f'/v1/devices/enrollment/{rid}/approve',dict(signature=proof),token=token,expected=403)
        assert d.request('/v1/devices/enrollment',{},token=token)['id']==rid
        d.request(f'/v1/devices/enrollment/{rid}/proof',dict(signature=base64.b64encode(bytes(64)).decode()),token=token,expected=403)
        candidate.call('enrollment_proof',reject=True,payload=payload,account=str(uuid.uuid4()))
        altered=base64.b64decode(payload).decode().replace(candidate.public,db.public)
        candidate.call('enrollment_proof',reject=True,payload=base64.b64encode(altered.encode()).decode(),account=account)
        da.call('enrollment_approve',reject=True,payload=payload,account=account,candidate_signature=proof,confirmed=False)
        da.call('enrollment_approve',reject=True,payload=payload,account=account,candidate_signature=base64.b64encode(bytes(64)).decode(),confirmed=True)
        grant=da.call('enrollment_approve',payload=payload,account=account,candidate_signature=proof,confirmed=True)['signature']
        assert da.call('enrollment_approve',payload=payload,account=account,candidate_signature=proof,confirmed=True)['signature']==grant
        d.request(f'/v1/devices/enrollment/{rid}/approve',dict(signature=proof),token=at,expected=403)
        candidate.call('enrollment_accept',reject=True,payload=payload,account=account,candidate_signature=proof,approver=da.identity,grant_signature=grant)
        # Independent comparison of the old device is still required; the server cannot pin it.
        candidate.pin(da)
        candidate.call('enrollment_accept',reject=True,payload=payload,account=account,candidate_signature=proof,approver=da.identity,grant_signature=proof)
        accepted=candidate.call('enrollment_accept',payload=payload,account=account,candidate_signature=proof,approver=da.identity,grant_signature=grant)
        assert accepted['verified'] and not accepted['mls_joined']
        assert candidate.call('enrollment_accept',payload=payload,account=account,candidate_signature=proof,approver=da.identity,grant_signature=grant)==accepted
        d.request(f'/v1/devices/enrollment/{rid}/activate',dict(signature=accepted['activation_signature']),token=token,expected=409)

        def approve(_):
            import urllib.error,urllib.request
            req=urllib.request.Request(d.BASE+f'/v1/devices/enrollment/{rid}/approve',data=json.dumps(dict(signature=grant)).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+at})
            try:
                with urllib.request.urlopen(req,context=d.TLS,timeout=20) as response:return response.status
            except urllib.error.HTTPError as error:return error.code
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(approve,range(2)))
        assert sorted(results)==[204,409],results
        certificate=d.request(f'/v1/devices/enrollment/{rid}',token=token)
        assert certificate['approved'] and certificate['grantSignature']==grant
        assert d.request('/v1/users/me',token=token)['trustState']=='DEVICE_PENDING_TRUST'
        d.request('/v1/devices',token=token,expected=403)
        d.request(f'/v1/devices/enrollment/{rid}/activate',dict(signature=proof),token=token,expected=403)
        d.request(f'/v1/devices/enrollment/{rid}/activate',dict(signature=accepted['activation_signature']),token=token,expected=204)
        d.request(f'/v1/devices/enrollment/{rid}/activate',dict(signature=accepted['activation_signature']),token=token,expected=204)
        assert d.request('/v1/users/me',token=token)['trustState']=='DEVICE_TRUSTED'

        # Device trust does not retroactively add a leaf or reveal old MLS history.
        da.pin(db);db.pin(da);group=str(uuid.uuid4());da.call('create',group=group)
        welcome=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage'])
        db.call('join',group=group,welcome=welcome['welcome'])
        d.request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=welcome['epoch']),token=at,expected=201)
        message=da.call('queue',group=group,id=str(uuid.uuid4()),text='Enrollment must not import old traffic secrets')
        d.request('/v1/messages',d.envelope(message,group),token=at)
        d.request('/v1/sync?conversationId='+group,token=token,expected=403)
        candidate.call('process',reject=True,group=group,ciphertext=message['ciphertext'])

        # Expiry and revocation checked under the same account lock as approval.
        expired=d.Device(root);es,er,ea,ep=start(a,expired)
        eg=da.call('enrollment_approve',payload=er['payload'],account=ea,candidate_signature=ep,confirmed=True)['signature']
        sql(f"UPDATE device_enrollments SET expires_at=now()-interval '1 second' WHERE id='{uuid.UUID(er['id'])}'")
        d.request(f"/v1/devices/enrollment/{er['id']}/approve",dict(signature=eg),token=at,expected=409)
        assert d.request('/v1/users/me',token=es['accessToken'])['trustState']=='DEVICE_PENDING_TRUST'
        future=d.Device(root);fs,fr,fa,fp=start(a,future)
        fg=da.call('enrollment_approve',payload=fr['payload'],account=fa,candidate_signature=fp,confirmed=True)['signature']
        d.request('/v1/devices/'+da.identity,token=token,method='DELETE',expected=204)
        d.request(f"/v1/devices/enrollment/{fr['id']}/approve",dict(signature=fg),token=at,expected=401)
        d.request('/v1/auth/refresh',dict(token=a['session']['refreshToken']),expected=401)
        d.request('/v1/sync?conversationId='+group,token=at,expected=401)
        # The remaining trusted candidate cannot replay another approver's signature.
        d.request(f"/v1/devices/enrollment/{fr['id']}/approve",dict(signature=fg),token=token,expected=403)
        print('PASS: pending login isolation; independent device keys; owner/key-bound two-device signatures; pinned approver and explicit confirmation; durable immutable approval retry; activation proof only after local grant verification; invalid activation/proof/substitution/account/replay/expiry/IDOR/self-approval/race/revoked-approver denied; no automatic MLS/history access. Camera QR and MLS multi-device enrollment/rekey still unimplemented.')


if __name__=='__main__':main()
