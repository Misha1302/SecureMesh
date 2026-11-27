#!/usr/bin/env python3
"""Check HTTPS readiness and the v2 registration rejection contract."""
import argparse
import base64
import json
import ssl
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check(opener, label, request, expected_status, field, expected_value):
    try:
        response = opener.open(request, timeout=10)
    except HTTPError as error:
        response = error
    with response:
        status = response.getcode()
        if status != expected_status:
            raise ValueError(f"{label}: expected HTTP {expected_status}, got {status}")
        if response.headers.get_content_type() != "application/json":
            raise ValueError(f"{label}: expected an application/json response")
        raw = response.read(4097)
        if len(raw) > 4096:
            raise ValueError(f"{label}: response exceeds 4096 bytes")
        payload = json.loads(raw)
        if not isinstance(payload, dict) or payload.get(field) != expected_value:
            raise ValueError(f"{label}: expected {field}={expected_value!r}")
        print(f"PASS {label}: HTTP {status} {expected_value}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("origin", help="HTTPS origin of the API or its public ingress")
    parser.add_argument("--ca-file", help="trusted CA PEM for a local or staging endpoint")
    args = parser.parse_args()
    try:
        origin = urlsplit(args.origin)
        port = origin.port
    except ValueError as error:
        parser.error(str(error))
    if (origin.scheme != "https" or not origin.hostname or origin.username is not None
            or origin.path not in ("", "/") or "?" in args.origin or "#" in args.origin
            or port == 0):
        parser.error("origin must be an HTTPS origin without credentials, a path, a query or a fragment")
    base = f"https://{origin.netloc}"

    # Keep both username and email invalid. Even an implementation ignoring
    # displayName must reject the payload before storage or email delivery.
    registration = {
        "username": "!",
        "email": "invalid",
        "credential": base64.b64encode(bytes(32)).decode("ascii"),
    }
    try:
        tls = ssl.create_default_context(cafile=args.ca_file)
        opener = build_opener(HTTPSHandler(context=tls), NoRedirect())
        check(opener, "readiness", Request(base + "/health/ready"), 200, "status", "ready")
        for name, expected in (("Z", "INVALID_REGISTRATION"), ("Z\n", "INVALID_DISPLAY_NAME")):
            request = Request(
                base + "/v2/auth/register",
                data=json.dumps({**registration, "displayName": name}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            check(opener, f"v2 registration with displayName={name!r}", request, 400, "code", expected)
    except (OSError, URLError, ValueError) as error:
        parser.exit(1, f"FAIL: {error}\n")


if __name__ == "__main__":
    main()
