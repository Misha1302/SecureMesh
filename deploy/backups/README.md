# Local recovery checks

Run each suite from the project root after bootstrapping SecureMesh. The fixtures use synthetic users and content.

| Command | Scope |
| --- | --- |
| `.local/venv/bin/python tests/integration/restore_v2.py` | Creates a fresh source database and restore target, runs PostgreSQL custom-format dump and restore, and starts the API against the restored database. Checks migrations, retained identity and login, decryption and delivery receipts with the recipient's original SQLCipher profile, profile-text visibility and contact blocks, restricted channel access, post/comment contents, the pinned publication and its revision, and idempotent retries. |
| `tests/integration/channel_pin_rollout.py` | Restores a live pinned publication and its revision, then runs the pre-pin API against the restored database to verify that deletion still clears the pin. See [artifact arguments](../README.md#channel-pin-rollback). |
| `.local/venv/bin/python tests/integration/private_blobs.py` | Restores database-backed encrypted attachment bytes and their MLS envelope. The original recipient downloads, authenticates and decrypts the restored content. |
| `.local/venv/bin/python tests/integration/recovery.py` | Temporarily stops the project's test PostgreSQL service before a message is committed, restarts it and checks previously acknowledged data. Run this disruptive suite only on a dedicated test stack. |

The database stores encrypted message envelopes and attachment bytes alongside server-readable account, profile and public-channel records. Protect operational database backups as sensitive data. The isolated dump checks use the original client store and keep the API's key directory. A replacement-host drill must separately restore the protected Data Protection key ring, service configuration and TLS credentials. Point-in-time recovery, a backup schedule, retention, recovery time and an independent off-host restore remain open.
