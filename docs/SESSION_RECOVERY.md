# Native session recovery (development)

The native client requests `deviceBoundRefresh=true` at password login. Such sessions reject the legacy bearer-only `/v1/auth/refresh` before rotation. Older bearer clients retain their existing one-use/reuse behavior. A native client can upgrade an old session through the signed route; no plaintext or bearer fallback is attempted after a signed refresh fails.

`POST /v1/auth/refresh/device` requires the refresh token plus the existing device's Ed25519 signature over the UTF-8 bytes:

```
SecureMesh/refresh/v1\n{lowercase request UUID}\n{lowercase device UUID}\n{lowercase SHA256 hex of refresh token}
```

The client builds this fixed-purpose message locally; it does not sign an arbitrary server-supplied refresh payload. Its request UUID, origin, old token and signature are committed in SQLCipher before HTTP. Reopening uses exactly that journal. The server verifies the current non-revoked device before exposing cached state or revoking a family. Rotation, successor session and protected response commit in one PostgreSQL transaction. An exact signed retry recovers the same tokens for at most 24 hours, only while the successor is unused/unrevoked and refresh-valid. Remaining access time is recalculated without extending the deadline. An already expired recovered access token is saved first, then the client can rotate its recovered refresh once. A changed authenticated request with the used token still revokes that family. Invalid signatures cannot trigger that action. Corrupted/unreadable cached protection fails closed with `REFRESH_STATE_UNAVAILABLE`; it never mints replacement tokens.

Local completion atomically merges allowlisted session fields into the existing profile and removes the pending journal. A matching receipt permits duplicate local completion; stale replies after a later rotation or reauthentication are rejected. MLS identity, ratchet, history, pins and immutable outbox are untouched. Concurrent native requests share the rotation; six simultaneous exact HTTP retries are also covered separately by integration tests. A device may create 512 rotations per rolling day; exact cached replay is not another rotation. Expired rows are pruned on that device's next new rotation. Inactive-device physical cleanup and whole-system retention remain unfinished; the 24-hour replay check does not claim automatic global deletion.

If recovery has expired or the family was revoked, **Sign in again** in chat/settings/account hub proves the account password and the same local signing key. It does not initialize a new device. Legacy completed demo profiles missing public account labels can adopt them only after that ownership check; another account cannot adopt the existing device. Local enrollment gates and keys/queue are preserved. A revoked device cannot use this route to revive itself. Password entry is ephemeral and is not put in the journal. This repairs access to an available, unlocked store; it cannot recover a lost store, forgotten local passphrase or old history from another device. Interrupted password reauthentication can be retried with the password; its server login is not advertised as exactly-once.

## Migration and backup

Migration `202611190007_DeviceBoundRefresh` adds `sessions.device_bound_refresh` (default false, preserving old clients) and `refresh_rotations`. Destructive downgrade is deliberately refused. Replay responses are protected using the standard ASP.NET Data Protection provider with application `SecureMesh.DeviceRefresh.v1` and purpose `SecureMesh.DeviceRefresh.Response.v1`. Its independent directory is `<StateDirectory>/refresh-keys` (default `.local/refresh-keys`); incumbent cursor protection is unchanged. These are server authentication-response protection keys, not MLS/private-chat keys.

For a consistent local recovery, preserve PostgreSQL **and** that refresh-key directory with owner-only permissions. Keep `.local/cursor-keys` for incumbent cursors and the separate client SQLCipher files/passphrases through their existing protected workflow. Do not put any of them in Git/logs. `make refresh-upgrade` creates the real previous six-migration schema via EF, copies only its own synthetic legacy fixture, upgrades it, then performs `pg_dump`/isolated `pg_restore` and a separate refresh-key directory restore. Exact replay tokens and original-recipient decryption are asserted. This is a scoped local restore test; media, object storage, OS keyring, production backup operations and independent audit are not covered.

## Verification

`make refresh-recovery`: actual lost refresh reply after server COMMIT, owned native SIGKILL, API/content-root restart, immutable retry, forged/foreign proof, response corruption, expiry, local pre-COMMIT abort, concurrency, pending/private gates, same-key password repair and ciphertext delivery.

`make refresh-quota`: 512 real signed rotations, denial of the next one, exact session/ledger counts and owned timestamp-window recovery. Normal global rate limits are retained.

`make gui-reauthentication`: actual Linux GTK/Xvfb wrong/correct password, RU/EN compact views, same device/queue and once-only original-ciphertext delivery. These are Linux windows, not Android/iOS qualification. Historical before-fix failure and subsequent execution logs are retained under `reports/evidence/v2-refresh-*`.

The threat model follows refresh replay concerns described in [RFC 9700 section 4.14](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14) and standard [Data Protection purpose separation](https://learn.microsoft.com/en-us/aspnet/core/security/data-protection/consumer-apis/purpose-strings?view=aspnetcore-10.0). This application-specific signed protocol is not an OAuth/DPoP compliance claim or independent security assurance. RustSec blockers and the wider missing-feature matrix remain. `PRODUCTION_APPROVED=false`.
