# Shared encrypted profile schema

V1–V6 are copied verbatim from the MIT-licensed OpenMLS SQLite storage provider. Version 0.3.0 and version 0.4.0-rc.1 ship identical bytes for these six scripts. Preserve filenames, contents and migration table name. The prior client's Refinery runner validates their checksums and rejects a database with additional migration entries. [Upstream source](https://github.com/openmls/openmls/tree/b792393d8a710632c42cce2a6462d99cac48363c/sqlite_storage/migrations)

SecureMesh uses the ordinary MLS storage API. Upstream V7 and V8 concern draft virtual-client tables. SecureMesh keeps that extension disabled. Enabling it or advancing the ordinary MLS storage schema requires an explicit compatibility decision, tests against existing profiles and a recovery path. The schema unit test also runs the complete upstream migration set against a disposable store to detect drift in the six shared scripts.
