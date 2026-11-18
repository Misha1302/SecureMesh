# Local operations and continuation

Run make bootstrap/demo/smoke/verify/down from this root. Ports are loopback; only project resources are controlled. make down preserves volumes and stops an owned tracked demo API PID after checking its command/cwd. Never prune unrelated Docker networks/volumes.

Evidence: reports/evidence. make verify aggregates failures and exits nonzero. Long tests: make network-gprs/network-severe. Disruptive DB recovery: deploy/backups/README.md. Raw metrics store IDs/times/byte counts/tc statistics, not private texts or keys.

Runtime credentials/stores/SDKs are ignored under .local and .env. Scripts now disable core dumps. Early synthetic crash tests ran before that safeguard; host coredump collection was not audited, so AT-021 remains partial. No real private data was used. API logging excludes bodies/tokens; the Xvfb harness redacts native debug endpoint URLs.

Explicit INVALID_CURSOR causes replay from beginning and durable local digest deduplication. Failed decrypt never advances its event cursor. After a commit timeout, retry exact ciphertext/ID; only explicit epoch conflict permits discarding/rebasing a pending commit.

Continue with dependency/provider/storage remediation and negative crypto tests; actual authenticated KeyPackage leasing/Welcome routing/enrollment; native WSS manager with HTTPS fallback; mixed blackout/crash/half-open/media scenarios. Then M4–M6. Keep original brief/checks immutable and edit reports matrix only.

No production capacity, deployment rollback or independent audit is verified. Future domain/TLS, service credentials, signing/store release, legal and operating approval are separate owner work after implementation/security completion.
