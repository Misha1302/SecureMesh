# Executed local recovery scope

.local/venv/bin/python tests/integration/recovery.py checks a project DB stop before commit, restart, acknowledged-message retention, pg_dump/pg_restore into a fresh securemesh_restore_* database, count consistency and recipient decryption with its original local MLS state. It deletes only its new database and preserves the original. This test temporarily stops SecureMesh DB; run outside other SecureMesh sessions.

It does not back up objects, establish PITR/RPO/RTO or restore private keys from the server. Full DB+object backup/recovery remains missing.
