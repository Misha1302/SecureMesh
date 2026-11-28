#!/usr/bin/env python3
"""Produce a real native OpenMLS photo message for the browser WASM interop test."""
import base64
import json
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/crypto"))
from process_spike import Device


def main():
    photo = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP8z/CfgYEBAAoEAgDdrjB4AAAAAElFTkSuQmCC")
    message_id = str(uuid.uuid4())
    (ROOT / ".local").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="securemesh-browser-photo-", dir=ROOT / ".local") as directory:
        sender = Device(Path(directory))
        invitation, lease = str(uuid.uuid4()), str(uuid.uuid4())
        print(json.dumps({"sender":sender.identity,"senderKey":sender.public,"invitation":invitation,"lease":lease}), flush=True)
        request = json.loads(sys.stdin.readline())
        sender.call("pin", identity=request["recipient"], public_key=request["recipientKey"], confirmed=True)
        bootstrap = sender.call("directory_prepare", invitation=invitation, lease=lease,
            recipient=request["recipient"], reference=request["reference"], keypackage=request["keypackage"])
        group = bootstrap["id"]
        staged = sender.call("attachment_prepare", group=group, id=message_id,
            data=base64.b64encode(photo).decode(), name="native-photo.png", media="photo", caption="Native to browser")
        sealed = sender.call("attachment_ciphertext", group=group, id=message_id)["ciphertext"]
        envelope = sender.call("attachment_queue", group=group, id=message_id)
        assert staged["ciphertextBytes"] == len(base64.b64decode(sealed))
        print(json.dumps({"bootstrap": bootstrap, "group": bootstrap["id"], "id": message_id,
            "envelope": envelope, "sealed": sealed, "plain": base64.b64encode(photo).decode()}, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
