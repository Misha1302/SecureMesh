"""Two local WebRTC peers. Media is synthetic and all signaling traverses two actual MLS stores."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid
from unittest.mock import patch

from aiortc import AudioStreamTrack, VideoStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.sdp import candidate_from_sdp

ROOT = Path(__file__).resolve().parents[2]
BIN = os.getenv("SECUREMESH_CRYPTO_BIN", ROOT / "src/crypto_core/target/debug/securemesh-crypto")


class Store:
    def __init__(self, directory, name):
        self.proc = subprocess.Popen([BIN, "--serve", directory / name], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.command(passphrase="disposable-call-test-passphrase")
        self.identity = name
        self.public = self.command(op="init", identity=name)["public_key"]
        self.seq = 0
        self.cursor = 0

    def command(self, **req):
        self.proc.stdin.write(json.dumps(req) + "\n")
        self.proc.stdin.flush()
        value = json.loads(self.proc.stdout.readline())
        if "error" in value:
            raise RuntimeError("native call command rejected")
        return value

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def exchange(sender, recipient, group, call, signal):
    envelope = sender.command(op="call_queue", id=str(uuid.uuid4()), group=group, call=call,
                              peer=recipient.identity, signal=signal, confirmed=True)
    assert set(envelope) == {"id", "group", "epoch", "kind", "ciphertext"}
    recipient.seq += 1
    received = recipient.command(op="ingest", sender=sender.identity, seq=recipient.seq, cursor=str(recipient.seq), **envelope)
    assert received["event"]["accepted"]
    sender.command(op="saved", group=group, id=envelope["id"], seq=recipient.seq)
    events = recipient.command(op="call_events", group=group, after=recipient.cursor)["events"]
    assert len(events) == 1
    recipient.cursor = events[0]["seq"]
    return events[0]["event"]["signal"]


async def description(sender, receiver, remote_pc, group, call, local):
    # aiortc gathers before returning its description. Split out candidates to
    # exercise the same authenticated trickle path as the native Flutter client.
    lines, candidates, mid, index = [], [], None, -1
    for line in local.sdp.split("\r\n"):
        if line.startswith("m="):
            index += 1
            mid = None
        if line.startswith("a=mid:"):
            mid = line.split(":", 1)[1]
        if line.startswith("a=candidate:"):
            candidates.append({"kind": "ice", "candidate": line[2:], "mid": mid, "line": index})
        elif line != "a=end-of-candidates":
            lines.append(line)
    assert candidates and all(" typ host" in v["candidate"] for v in candidates)
    signal = exchange(sender, receiver, group, call, {"kind": local.type, "sdp": "\r\n".join(lines)})
    await remote_pc.setRemoteDescription(RTCSessionDescription(signal["sdp"], signal["kind"]))
    for candidate in candidates:
        item = exchange(sender, receiver, group, call, candidate)
        ice = candidate_from_sdp(item["candidate"].removeprefix("candidate:"))
        ice.sdpMid, ice.sdpMLineIndex = item["mid"], item["line"]
        await remote_pc.addIceCandidate(ice)


async def run():
    with tempfile.TemporaryDirectory() as directory:
        group, call = str(uuid.uuid4()), str(uuid.uuid4())
        a, b = Store(Path(directory), "caller"), Store(Path(directory), "callee")
        peers, tracks, incoming = [], [], [{}, {}]
        try:
            for own, peer in [(a, b), (b, a)]:
                own.command(op="pin", identity=peer.identity, public_key=peer.public, confirmed=True)
            a.command(op="create", group=group)
            kp = b.command(op="keypackage")
            welcome = a.command(op="add", group=group, keypackage=kp["keypackage"])
            b.command(op="join", group=group, welcome=welcome["welcome"])
            assert exchange(a, b, group, call, {"kind":"invite", "media":"video"})["media"] == "video"
            exchange(b, a, group, call, {"kind":"accept"})
            for i in range(2):
                pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
                peers.append(pc)
                pc.on("track", lambda track, i=i: incoming[i].update({track.kind: track}))
                for track in [AudioStreamTrack(), VideoStreamTrack()]:
                    tracks.append(track)
                    pc.addTrack(track)
            caller, callee = peers
            await caller.setLocalDescription(await caller.createOffer())
            await description(a, b, callee, group, call, caller.localDescription)
            await callee.setLocalDescription(await callee.createAnswer())
            await description(b, a, caller, group, call, callee.localDescription)
            for media in incoming:
                for kind in ["audio", "video"]:
                    frames = [await asyncio.wait_for(media[kind].recv(), 10) for _ in range(3)]
                    assert frames[-1].pts > frames[0].pts
            for pc in peers:
                assert pc.connectionState == "connected"
                assert all(x.sender.transport.state == "connected" for x in pc.getTransceivers())
            exchange(a,b,group,call,{"kind":"end"})
            print(json.dumps({"media":"synthetic", "endpoints":2,"decodedAudioFramesPerPeer":3,
                              "decodedVideoFramesPerPeer":3,"dtls":"connected","ice":"host-only","signaling":"OpenMLS"}))
        finally:
            for track in tracks:
                track.stop()
            await asyncio.gather(*(pc.close() for pc in peers))
            a.close()
            b.close()


if __name__ == "__main__":
    # Supply only loopback to ICE so this lab never enumerates or uses LAN interfaces.
    with patch("aioice.ice.get_host_addresses", return_value=["127.0.0.1"]):
        asyncio.run(run())
