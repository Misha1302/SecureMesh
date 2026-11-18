# Источники и caveats

**Дата отбора:** 2026-11-18. Это **проверяемые первичные источники**, не свидетельства о создании или аудите SecureMesh. Конкретные версии библиотек для реализации Codex обязан проверить в момент начала работы и закрепить lock files/commit.

## Стандарты и безопасность

1. IETF RFC 9420 — Messaging Layer Security: https://www.rfc-editor.org/rfc/rfc9420.html (MLS, async group key agreement, PFS/PCS).
2. IETF RFC 9750 — MLS Architecture: https://www.rfc-editor.org/rfc/rfc9750.html (Authentication Service, Delivery Service, key directory, metadata limitations and epoch ordering).
3. OpenMLS implementation: https://github.com/openmls/openmls and https://book.openmls.tech/ (Rust library; Android, iOS, WASM have *build* support, which does not guarantee target tests passed).
4. Signal libsignal README: https://github.com/signalapp/libsignal (use outside of Signal is unsupported; APIs can change).
5. Signal PQXDH specification: https://signal.org/docs/specifications/pqxdh/ (alternative protocol; not chosen in this architecture).
6. OWASP Password Storage Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html (Argon2id, unique salt, no plaintext).
7. OWASP ASVS 5.0: https://asvs.owasp.org/ (application security acceptance baseline).
8. TLS 1.3 IETF RFC 8446: https://www.rfc-editor.org/rfc/rfc8446.html (transport security).

## Runtime, UI, operations

9. .NET support policy: https://dotnet.microsoft.com/en-us/platform/support/policy (.NET 10 is active LTS as of 2026-11-18; .NET 11 STS also current, pin appropriate supported runtime).
10. Flutter supported platforms: https://docs.flutter.dev/reference/supported-platforms (Android, iOS, desktop, browser; mobile background and platform SDK constraints remain).
11. flutter_rust_bridge: https://cjycode.com/flutter_rust_bridge/ and WASM limitations https://cjycode.com/flutter_rust_bridge/manual/miscellaneous/wasm-limitations (not all native patterns transfer to web).
12. Linux `tc netem`: https://man7.org/linux/man-pages/man8/tc-netem.8.html (delay/loss/rate network emulation).
13. Toxiproxy: https://github.com/Shopify/toxiproxy (deterministic development failure injection).
14. MDN WebSocket API: https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API (classic browser WebSocket API has no intrinsic backpressure; app must bound queues).
15. Android background restrictions: https://developer.android.com/develop/background-work/background-tasks/bg-work-restrictions (OS and manufacturers throttle background jobs).
16. Apple Background Tasks: https://developer.apple.com/documentation/backgroundtasks/ (background tasks scheduled by OS; cannot promise immediate wake).
17. Codex noninteractive usage: https://learn.chatgpt.com/docs/non-interactive-mode (current documented `codex exec --sandbox workspace-write`, stdin; `--full-auto` no longer supported).
18. Codex AGENTS.md configuration: https://learn.chatgpt.com/docs/agent-configuration/agents-md (project file read at startup).

## Known unknowns requiring real testing

- Exact OpenMLS API and Flutter Rust bridge version compatibility in the execution environment.
- Flutter web plus Rust OpenMLS WASM operational integration with secure storage on supported browsers; need cross-browser tests.
- Device trust bootstrap/key transparency strategy under compromised server; independent cryptographic review required.
- iOS/macOS native builds require macOS/Xcode; Linux cannot prove Apple builds worked.
- 2G physical field performance requires real carrier/device trials, not only netem.
- Native push service credentials and app store signing belong to future deployment.

## Source and license hygiene

Sources cited for standards/choices, not copied wholesale. Codex must check licenses of dependencies, pin revisions and provide notices/SBOM. Avoid plagiarism/redistribution of Telegram UI assets, client proprietary components or artwork.
