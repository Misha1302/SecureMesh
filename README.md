# SecureMesh — local implementation

`PARTIAL / NOT_READY`. `PRODUCTION_APPROVED=false`. Original Russian requirements remain immutable in the root. Actual progress and missing gates are in [STATUS.md](STATUS.md).

Requirements: Linux, Docker/Compose, .NET SDK 10.0.111, Rust 1.93.1, Python 3. No external account or server credentials are needed.

```sh
make bootstrap
make demo
# another terminal:
make smoke
make crypto
make verify
make down
```

`make demo` runs the local API in the foreground at http://127.0.0.1:5088. Stop it with Ctrl-C. `make down` stops only the SecureMesh Compose project and preserves its database volume. Credentials are generated into ignored `.env`; do not share it. Runtime logs and temporary client stores belong in ignored `.local/`.

`make verify` executes implemented checks and then the original acceptance gate. It returns nonzero while required AT scenarios are incomplete. A green component test does not imply product readiness.

The Rust CLI is a real local client crypto/storage process, not yet a Flutter application. It uses OpenMLS and SQLCipher, receiving a JSON command (including local passphrase) on stdin. Do not pass passwords on the command line. No public deployment, external SMTP or push is configured.
