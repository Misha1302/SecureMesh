# ADR 011 — local foundations (2026-11-18)

Use installed .NET SDK 10.0.111, pinned by global.json. PostgreSQL 17 remains supported and its available official image is pinned by digest. No unsupported-version assertion about PostgreSQL 18 is made. EF Core owns versioned migrations; explicit parameterized Npgsql transactions will implement the delivery hot path.

The host's Docker default pools are exhausted (actual Compose failure). Do not prune unrelated networks. SecureMesh uses its own configurable /28 subnet (10.239.238.0/28 by default; no overlap in inspected Docker subnets). All published ports bind loopback. Compose project name is securemesh, shutdown never deletes volumes.

Native client state uses OpenMLS 0.9.2 with RustCrypto and openmls_sqlite_storage 0.3.0 over SQLCipher via rusqlite. Each operation wraps MLS state and app inbox/outbox changes in one SQLite transaction, synchronous FULL. SQLCipher support is checked at runtime; wrong passphrase fails closed. CLI receives passphrase on stdin, never command line. User passphrase is the local Linux fallback until secure platform key storage/Flutter integration exists.

OpenMLS source/API consulted: https://github.com/openmls/openmls and crates.io package source downloaded by Cargo. Actual Cargo.lock pins transitive dependencies. No audit claim.
