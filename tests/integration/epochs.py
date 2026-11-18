#!/usr/bin/env python3
import concurrent.futures
import tempfile
import uuid
from pathlib import Path
import delivery as d

def main():
    d.BASE='https://127.0.0.1:5092'
    with d.Server(),tempfile.TemporaryDirectory(prefix='securemesh-epochs-',dir=d.ROOT/'.local') as tmp:
        a,b=[d.account(Path(tmp)) for _ in range(2)];da,db=a['device'],b['device'];at=a['session']['accessToken'];bt=b['session']['accessToken']
        da.pin(db);db.pin(da);group=str(uuid.uuid4());da.call('create',group=group)
        welcome=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage']);db.call('join',group=group,welcome=welcome['welcome'])
        d.request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=welcome['epoch']),token=at,expected=201)
        commits=[who.call('stage_rekey',group=group,id=str(uuid.uuid4())) for who in (da,db)]
        def send(index):
            m=commits[index]
            # This scenario permits either contender to win; no fixed expected winner.
            import json,urllib.error,urllib.request
            req=urllib.request.Request(d.BASE+'/v1/messages',data=json.dumps(d.envelope(m,group)).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+[at,bt][index]})
            try:
                with urllib.request.urlopen(req,context=d.TLS) as response:return response.status,json.load(response)
            except urllib.error.HTTPError as e:return e.code,json.load(e)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(send,range(2)))
        assert sorted(r[0] for r in results)==[200,409]
        winner=next(i for i,r in enumerate(results) if r[0]==200);loser=1-winner
        clients=[da,db];tokens=[at,bt]
        assert results[loser][1]['code']=='MLS_EPOCH_CONFLICT'
        # An uncertain ACK is retried with identical ciphertext before deciding whether to merge.
        saved=d.request('/v1/messages',d.envelope(commits[winner],group),token=tokens[winner])
        assert saved['alreadyCommitted'] and saved['serverSequence']==1
        clients[winner].call('commit_saved',group=group,id=commits[winner]['id'],seq=1)
        clients[loser].call('commit_rejected',group=group,id=commits[loser]['id'],epoch_conflict_confirmed=True)
        d.sync(clients[loser],tokens[loser],group);d.sync(clients[winner],tokens[winner],group)
        rebased=clients[loser].call('stage_rekey',group=group,id=str(uuid.uuid4()))
        assert rebased['epoch']==2
        saved=d.request('/v1/messages',d.envelope(rebased,group),token=tokens[loser]);assert saved['serverSequence']==2
        clients[loser].call('commit_saved',group=group,id=rebased['id'],seq=2)
        d.sync(clients[winner],tokens[winner],group);d.sync(clients[loser],tokens[loser],group)
        for i,client in enumerate(clients):
            msg=client.call('queue',group=group,id=str(uuid.uuid4()),text='after concurrent epoch resolution')
            assert msg['epoch']==3
            d.request('/v1/messages',d.envelope(msg,group),token=tokens[i])
        for i,client in enumerate(clients):
            d.sync(client,tokens[i],group,limit=1)
            assert client.call('cursor',group=group)['seq']==4
            assert len(client.call('history',group=group)['events'])==1
        print('PASS: two real MLS commits race at epoch 1; exactly one accepted; lost ACK retry preserves commit; winner merges only after durable save; loser discards confirmed-rejected pending commit, processes winner, rebases at epoch 2; both clients resume encrypted text at epoch 3 with contiguous cursors. Group membership workflow remains separate.')

if __name__=='__main__':main()
