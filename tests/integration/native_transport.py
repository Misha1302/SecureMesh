#!/usr/bin/env python3
"""Run production Dart transport + Rust bridge against real TLS API/PG, with controlled network faults."""
import asyncio
import concurrent.futures
import json
import os
import ssl
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path
import delivery as d


class FaultProxy:
    def __init__(self, mode, upstream_port=5095):
        self.mode=mode
        self.upstream_port=upstream_port
        self.loop=asyncio.new_event_loop()
        self.thread=threading.Thread(target=self.loop.run_forever)
        self.thread.start()
        self.dropped=0
        self.observed=[]
        self.writers=set()
        self.tasks=set()
        async def start():
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(d.ROOT/'.local/tls.pem',d.ROOT/'.local/tls.key')
            self.server=await asyncio.start_server(self.forward,'127.0.0.1',0,ssl=context,limit=131077)
            return self.server.sockets[0].getsockname()[1]
        self.port=asyncio.run_coroutine_threadsafe(start(),self.loop).result(10)

    async def forward(self,reader,writer):
        self.tasks.add(asyncio.current_task());self.writers.add(writer)
        upstream=None
        try:
            header=await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'),10)
            websocket=False
            source,upstream=await asyncio.open_connection('127.0.0.1',self.upstream_port,ssl=d.TLS,server_hostname='localhost')
            self.writers.add(upstream)
            async def pipe(src,dst,downstream):
                while data:=await src.read(16384):
                    mode=self.mode.read_text()
                    self.observed.append(dict(event='data',websocket=websocket,mode=mode,downstream=downstream,bytes=len(data)))
                    if mode=='offline' or (websocket and (mode=='halfopen' or (mode=='lostack' and downstream))):
                        self.dropped+=len(data);continue
                    if websocket and mode=='malformed' and downstream:
                        # Invalid server binary frame, not a simulated encrypted message or ACK.
                        dst.write(b'\x82\x01\xff');await dst.drain();return
                    dst.write(data);await dst.drain()
            async def requests():
                # Dart correctly reuses HTTP keep-alive sockets for an Upgrade.
                # Parse every HTTP request, not just the first request on a TCP connection.
                nonlocal websocket
                current=header
                while True:
                    fields={k.strip().lower():v.strip().lower() for line in current.split(b'\r\n')[1:] if b':' in line for k,v in [line.split(b':',1)]}
                    websocket=fields.get(b'upgrade')==b'websocket'
                    if websocket:self.observed.append(dict(event='upgrade',websocket=True,mode=self.mode.read_text(),downstream=False,bytes=len(current)))
                    if websocket and self.mode.read_text()=='blocked':
                        writer.write(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                        await writer.drain();return
                    if websocket and self.mode.read_text()=='badupgrade':
                        writer.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: invalid\r\n\r\n')
                        await writer.drain();return
                    upstream.write(current);await upstream.drain()
                    if websocket:
                        await pipe(reader,upstream,False);return
                    remaining=int(fields.get(b'content-length',b'0'))
                    assert 0<=remaining<=131072
                    while remaining:
                        data=await reader.readexactly(min(16384,remaining));remaining-=len(data)
                        upstream.write(data);await upstream.drain()
                    current=await reader.readuntil(b'\r\n\r\n')
            tasks=[asyncio.create_task(requests()),asyncio.create_task(pipe(source,writer,True))]
            try:
                _,pending=await asyncio.wait(tasks,return_when=asyncio.FIRST_COMPLETED)
                for task in pending:task.cancel()
                await asyncio.gather(*tasks,return_exceptions=True)
            finally:
                for task in tasks:task.cancel()
        except (OSError,asyncio.TimeoutError,asyncio.IncompleteReadError):
            pass
        finally:
            for connection in (writer,upstream):
                if connection:
                    connection.close();self.writers.discard(connection)
            self.tasks.discard(asyncio.current_task())

    def close(self):
        async def stop():
            self.server.close();await self.server.wait_closed()
            for writer in list(self.writers):writer.close()
            for task in list(self.tasks):task.cancel()
            await asyncio.gather(*list(self.tasks),return_exceptions=True)
        asyncio.run_coroutine_threadsafe(stop(),self.loop).result(10)
        self.loop.call_soon_threadsafe(self.loop.stop);self.thread.join(timeout=10);self.loop.close()


def main():
    d.BASE='https://127.0.0.1:5097'
    with d.Server(),tempfile.TemporaryDirectory(prefix='securemesh-native-transport-',dir=d.ROOT/'.local') as tmp:
        try:
            with d.Server(legacy_bootstrap=False):
                raise AssertionError('Second fixture attached to an existing API')
        except RuntimeError as error:
            assert str(error)=='TEST_API_PORT_IN_USE_5097'
        root=Path(tmp);a,b=[d.account(root) for _ in range(2)]
        da,db=a['device'],b['device'];da.pin(db);db.pin(da)
        group=str(uuid.uuid4());da.call('create',group=group)
        welcome=da.call('add',group=group,keypackage=db.call('keypackage')['keypackage']);db.call('join',group=group,welcome=welcome['welcome'])
        d.request('/v1/conversations',dict(id=group,deviceIds=[da.identity,db.identity],initialEpoch=welcome['epoch']),token=a['session']['accessToken'],expected=201)
        mode=root/'mode';mode.write_text('pass');proxy=FaultProxy(mode,upstream_port=5097)
        fixture=root/'fixture.json'
        fixture.write_text(json.dumps(dict(endpoint=f'https://127.0.0.1:{proxy.port}',group=group,mode=str(mode),cert=str(d.ROOT/'.local/tls.pem'),library=str(d.ROOT/'src/crypto_core/target/debug/libsecuremesh_crypto.so'),devices=[dict(id=who['device'].identity,path=str(who['device'].path),passphrase=who['device'].password,token=who['session']['accessToken']) for who in (a,b)])))
        fixture.chmod(0o600)
        try:
            subprocess.run([str(d.ROOT/'.local/flutter/bin/dart'),'run','tool/transport_smoke.dart',str(fixture)],cwd=d.ROOT/'apps/client_flutter',env={**os.environ,'PUB_CACHE':str(d.ROOT/'.local/pub-cache')},check=True,timeout=45)
            assert proxy.dropped>0,'faults were not injected'
            print('Fault proxy dropped real TLS-decoded transport bytes:',proxy.dropped)
            print('PASS: native child terminated within 45 seconds including lost close frames; no hanging process accepted as success.')
        finally:
            proxy.close()
            print('Fault proxy observed modes:',sorted({r['mode'] for r in proxy.observed}))


if __name__=='__main__':main()
