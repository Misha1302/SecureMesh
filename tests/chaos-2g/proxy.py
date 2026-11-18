"""Opaque TCP forwarding only. TLS endpoints remain client and API."""
import asyncio
import os

async def pipe(reader,writer):
    try:
        while data:=await reader.read(16384):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()

async def forward(reader,writer):
    try:
        upstream,downstream=await asyncio.open_connection(os.environ['UPSTREAM_HOST'],5090)
        await asyncio.gather(pipe(reader,downstream),pipe(upstream,writer))
    except (OSError,asyncio.IncompleteReadError): writer.close()

async def main():
    server=await asyncio.start_server(forward,'0.0.0.0',15090,limit=32768)
    async with server: await server.serve_forever()

asyncio.run(main())
