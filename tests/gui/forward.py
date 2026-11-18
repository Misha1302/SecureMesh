"""Opaque loopback TLS forwarding inside the owned Xvfb container; no TLS termination."""
import asyncio
import os


async def pipe(source,target):
    try:
        while data:=await source.read(16384):target.write(data);await target.drain()
    finally:target.close()


async def forward(source,target):
    try:
        incoming,outgoing=await asyncio.open_connection(os.environ['UPSTREAM_HOST'],int(os.environ.get('UPSTREAM_PORT','5098')))
        await asyncio.gather(pipe(source,outgoing),pipe(incoming,target))
    except OSError:target.close()


async def main():
    async with await asyncio.start_server(forward,'127.0.0.1',5088) as server:await server.serve_forever()


asyncio.run(main())
