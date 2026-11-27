#!/usr/bin/env python3
"""Exercise HTTPS and WSS inactivity enforcement with a private PostgreSQL fixture."""
import hashlib
import subprocess
import tempfile
from pathlib import Path

import delivery as d
from private_blobs import database, postgres


POLICY = "/v1/auth/session/inactivity"
ACTIVITY = "/v1/auth/session/activity"


def verify(db, root):
    account = d.account(root)
    session = account["session"]
    access, refresh = session["accessToken"], session["refreshToken"]
    identity = d.request("/v1/users/me", token=access)

    def sql(query):
        return postgres(
            "psql", "-XAtq", "-v", "ON_ERROR_STOP=1", "-U", "securemesh", "-d", db,
            "-c", query, text=True, stdout=subprocess.PIPE,
        ).stdout.strip()

    def session_where(token):
        digest = hashlib.sha256(token.encode()).hexdigest()
        return f"access_hash=decode('{digest}','hex')"

    def age(token, days):
        assert isinstance(days, int)
        sql(f"""UPDATE sessions SET last_interactive_at=statement_timestamp()-{days}*interval '24 hours'
            WHERE {session_where(token)}""")

    def settings(token):
        return d.request(POLICY, token=token)

    def configure(token, value, expected=200):
        return d.request(POLICY, dict(idleTimeout=value), token, method="PUT", expected=expected)

    assert settings(access)["idleTimeout"] == "7"
    assert configure(access, "2", 400)["code"] == "INVALID_IDLE_TIMEOUT"
    for value in ("1", "3", "7", "14", "30", "90", "never"):
        policy = configure(access, value)
        assert policy["idleTimeout"] == value
        assert (policy["idleExpiresAt"] is None) == (value == "never")

    # Moving only the persisted activity timestamp avoids sleeps and leaves
    # access and refresh TTLs running on the real clock.
    age(access, 91)
    assert settings(access)["idleExpiresAt"] is None
    rotated = d.request("/v1/auth/refresh", dict(token=refresh))
    access, refresh = rotated["accessToken"], rotated["refreshToken"]
    assert settings(access)["idleTimeout"] == "never"
    configure(access, "1")
    age(access, 0)
    previous = settings(access)
    assert d.request("/v1/users/me", token=access)["trustState"] == "DEVICE_TRUSTED"

    stream = d.Stream(access, account["device"])
    try:
        ping = d.wire.Frame(kind=d.wire.PING, protocol_version=1)
        assert stream.exchange(ping).kind == d.wire.PONG
        assert settings(access) == previous
        extended = d.request(ACTIVITY, {}, access)
        assert extended["idleExpiresAt"] > previous["idleExpiresAt"]
        age(access, 1)
        denied = stream.exchange(ping)
        assert denied.server_error.code == 401 and denied.server_error.stable_code == "AUTH_REQUIRED"
    finally:
        stream.close()

    assert d.request("/v1/users/me", token=access, expected=401)["code"] == "AUTH_REQUIRED"
    assert d.request(ACTIVITY, {}, access, expected=401)["code"] == "AUTH_REQUIRED"
    assert configure(access, "never", 401)["code"] == "AUTH_REQUIRED"
    assert d.request("/v1/auth/refresh", dict(token=refresh), expected=401)["code"] == "INVALID_REFRESH"

    device = account["device"]
    challenge = d.request("/v1/auth/challenge", dict(username=account["username"], deviceId=device.identity))
    signature = device.call("sign", payload=challenge["payload"])["signature"]
    fresh = d.request("/v1/auth/reauthenticate", dict(
        username=account["username"], password=account["password"], deviceId=device.identity,
        publicKey=device.public, challengeId=challenge["challengeId"], signature=signature,
        expectedUserId=identity["userId"], expectedTrustState=identity["trustState"],
    ))
    assert d.request("/v1/users/me", token=fresh["accessToken"]) == identity
    access, refresh = fresh["accessToken"], fresh["refreshToken"]
    assert settings(access)["idleTimeout"] == "7"
    age(access, 6)
    previous = settings(access)
    rotated = d.request("/v1/auth/refresh", dict(token=refresh))
    access = rotated["accessToken"]
    assert settings(access) == previous
    assert d.request("/v1/auth/refresh", dict(token=refresh), expected=401)["code"] == "REFRESH_REUSE"
    assert d.request("/v1/users/me", token=access, expected=401)["code"] == "AUTH_REQUIRED"

    fresh = d.login(account["username"], account["password"], account["device"])
    access, refresh = fresh["accessToken"], fresh["refreshToken"]
    configure(access, "never")
    sql(f"UPDATE sessions SET refresh_expires_at=now() WHERE {session_where(access)}")
    assert d.request("/v1/auth/refresh", dict(token=refresh), expected=401)["code"] == "INVALID_REFRESH"

    pending = d.login(account["username"], account["password"], d.Device(root))
    assert pending["trustState"] == "DEVICE_PENDING_TRUST"
    assert d.request(ACTIVITY, {}, pending["accessToken"], expected=403)["code"] == "DEVICE_PENDING_TRUST"


def main():
    with database() as db, tempfile.TemporaryDirectory(dir=d.ROOT / ".local") as work, d.Server(db):
        verify(db, Path(work))
    print("PASS: inactivity policy, explicit activity, HTTPS/WSS expiry, refresh and replay, same-device v1 reauthentication")


if __name__ == "__main__":
    main()
