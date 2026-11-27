#!/usr/bin/env python3
"""Stage the allowlisted SecureMesh PWA and checksums for a dedicated origin."""

import argparse
import hashlib
from pathlib import Path
import tempfile


SOURCE = Path(__file__).resolve().parents[1] / "site" / "app"
ASSETS = (
    "account.js",
    "app.css",
    "app.js",
    "apple-touch-icon.png",
    "crypto/securemesh_browser_crypto.js",
    "crypto/securemesh_browser_crypto_bg.wasm",
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
    "sw.js",
    "vault.js",
)
CACHE_MARKER = b"${cachePrefix}v1"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checksum_lines(files: dict[str, bytes]) -> str:
    return "".join(f"{digest(data)}  app/{name}\n" for name, data in files.items())


def package(destination: Path) -> None:
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

    worker = files["sw.js"]
    if worker.count(CACHE_MARKER) != 1:
        raise ValueError("Expected exactly one service worker cache version marker")

    cache_id = digest(checksum_lines(files).encode("ascii"))[:24].encode("ascii")
    files["sw.js"] = worker.replace(CACHE_MARKER, CACHE_MARKER + b"-" + cache_id)

    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
        staging = Path(temporary) / "bundle"
        for name, data in files.items():
            target = staging / "app" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (staging / "SHA256SUMS").write_text(checksum_lines(files), encoding="ascii")
        staging.rename(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new output directory for app/ and SHA256SUMS")
    args = parser.parse_args()
    try:
        package(args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
