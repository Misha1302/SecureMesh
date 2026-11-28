#!/usr/bin/env python3
"""Stage the allowlisted SecureMesh PWA and checksums for a dedicated origin."""

import argparse
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "site" / "app"
BROWSER_BUILD = ROOT / "src" / "browser_crypto" / "build.sh"
BROWSER_ASSETS = (
    "crypto/securemesh_browser_crypto.js",
    "crypto/securemesh_browser_crypto_bg.wasm",
)
ASSETS = (
    "account.js",
    "app.css",
    "app.js",
    "apple-touch-icon.png",
    *BROWSER_ASSETS,
    "icon-192.png",
    "icon-512.png",
    "icon-maskable-512.png",
    "index.html",
    "manifest.webmanifest",
    "mesh-worker.js",
    "messenger.js",
    "profile.css",
    "profile.html",
    "profile.js",
    "private-image.js",
    "sw.js",
    "vault.js",
)
CACHE_MARKER = b"${cachePrefix}v1"
INTEGRITY_MARKER = b"const releaseIntegrity = null;"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checksum_lines(files: dict[str, bytes]) -> str:
    return "".join(f"{digest(data)}  app/{name}\n" for name, data in files.items())


def render_service_worker(files: dict[str, bytes]) -> bytes:
    worker = files["sw.js"]
    if worker.count(CACHE_MARKER) != 1 or worker.count(INTEGRITY_MARKER) != 1:
        raise ValueError("Expected exactly one service worker cache marker and one integrity marker")

    integrity = {
        name: "sha256-" + base64.b64encode(hashlib.sha256(files[name]).digest()).decode("ascii")
        for name in ASSETS if name != "sw.js"
    }
    cache_id = digest(checksum_lines(files).encode("ascii"))[:24].encode("ascii")
    manifest = json.dumps(integrity, indent=2).encode("ascii")
    return worker.replace(CACHE_MARKER, CACHE_MARKER + b"-" + cache_id).replace(
        INTEGRITY_MARKER, b"const releaseIntegrity = " + manifest + b";"
    )


def verify_browser_crypto(files: dict[str, bytes], staging: Path) -> None:
    generated = staging / "generated"
    environment = os.environ | {
        "CARGO_TARGET_DIR": str(staging / "target"),
        "RUSTUP_TOOLCHAIN": "1.100.0",
    }
    subprocess.run([BROWSER_BUILD, generated], cwd=ROOT, env=environment, check=True)

    for name in BROWSER_ASSETS:
        rebuilt = (generated / Path(name).name).read_bytes()
        if rebuilt != files[name]:
            raise ValueError(
                f"Browser crypto rebuild mismatch for {name}. "
                f"Source SHA-256: {digest(files[name])}. Rebuilt SHA-256: {digest(rebuilt)}."
            )
        files[name] = rebuilt
        print(f"Verified browser crypto rebuild: {name}")


DEFAULT_API = "https://securemesh.90-156-230-119.sslip.io"


def configure_api_origin(files: dict[str, bytes], origin: str) -> None:
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if len(origin) > 261 or not re.fullmatch(rf"https://(?:{label}\.)+[a-z]{{2,63}}", origin):
        raise ValueError("Expected a lowercase HTTPS DNS origin on the default port")
    for name, count in (("account.js", 1), ("index.html", 2)):
        if files[name].count(DEFAULT_API.encode()) != count:
            raise ValueError(f"Unexpected API origin references in {name}")
        files[name] = files[name].replace(DEFAULT_API.encode(), origin.encode())


def package(destination: Path, api_origin: str = DEFAULT_API) -> None:
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"Output already exists: {destination}")

    actual = {
        path.relative_to(SOURCE).as_posix()
        for path in SOURCE.rglob("*")
        if not path.is_dir() or path.is_symlink()
    }
    missing = sorted(set(ASSETS) - actual)
    unexpected = sorted(actual - set(ASSETS))
    if missing or unexpected:
        raise ValueError(f"Invalid PWA asset list. Missing: {missing}. Unexpected: {unexpected}.")

    files = {}
    for name in ASSETS:
        path = SOURCE / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected a regular PWA asset: {name}")
        files[name] = path.read_bytes()

    configure_api_origin(files, api_origin)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        temporary_path = Path(temporary)
        verify_browser_crypto(files, temporary_path)

        files["sw.js"] = render_service_worker(files)
        staging = temporary_path / "bundle"
        for name, data in files.items():
            target = staging / "app" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (staging / "SHA256SUMS").write_text(checksum_lines(files), encoding="ascii")
        staging.rename(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new output directory for app/ and SHA256SUMS")
    parser.add_argument("--api-origin", default=DEFAULT_API, help="fixed HTTPS API origin for this release")
    args = parser.parse_args()
    try:
        package(args.output, args.api_origin)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
