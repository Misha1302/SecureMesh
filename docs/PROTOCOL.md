# Implemented protocol slice

API v1 supports verified local accounts, per-device Ed25519 proof of possession, opaque bearer sessions and single-use rotating refresh families. Later devices receive account-only pending sessions. Private delivery requires trusted activation; old-device approval alone does not activate the candidate. The candidate verifies its independently pinned approver and signs activation locally. See DEVICE_TRUST.md for the signed, expiring protocol and its remaining QR/multi-device limitations. Every active WebSocket frame revalidates the database session and device revocation. Authentication uses the Authorization header; no query-string tokens or cookies.

`/v1/messages` commits `messages`, immutable idempotency identity, per-conversation sequence/epoch update and `outbox` in one PostgreSQL transaction, returning durable ACK only after COMMIT. Conversation row locking serializes concurrent writers. Identical retries preserve ID/sequence even after epoch changes; changed ciphertext, kind or epoch gives 409. Sender device comes from authentication.

`/v1/sync?conversationId=...&cursor=...&limit=...` has at most 100 events and 64 KiB ciphertext per page. Cursor is ASP.NET Data Protection authenticated and scoped to device+conversation. Keys persist in `.local/cursor-keys`; these are server cursor keys, not E2EE keys. Receipts are monotonic and cannot exceed the committed conversation sequence. Receipt remains a client assertion of local persistence, not proof a human read anything.

`/v1/stream` carries the immutable source protobuf contract with a varint length prefix per WebSocket binary message. Max 128 KiB, HELLO version/device negotiation, one bounded request/response loop, send/sync/processed-ACK/ping, per-operation 45 second timeout. Durable/sync semantics reuse the HTTPS service. There is no proactive push worker yet: clients issue sync requests. HTTP uses JSON/base64 for fallback. Development tests use a generated localhost certificate and explicit CA trust, never disabled TLS verification.

Client `queue` updates the MLS sender ratchet and immutable outbox in a SQLCipher transaction. `ingest` authenticates content/inner message identity with OpenMLS, persists inbox/deduplication and sequence+cursor in one transaction. Sender echoes match local ciphertext. Failed decryption or gaps do not advance the cursor. Repeated server sequences must contain the same envelope.

Initial one-device DMs use accepted username requests, bounded public-only OpenMLS KeyPackage validation, atomic one-use leases, and signed routed Welcome. Both clients independently compare/pin peer keys. Group creation, signed retry and recipient join are transactional in SQLCipher; replaying the same Welcome cannot reset an existing ratchet. See MLS_DIRECTORY.md. Direct existing-group registration is disabled by default; legacy low-level tests explicitly opt in. Native signup and the account hub use the real API rather than local Welcome exchange.

MeshTransport is the native WSS-first protobuf client with a six-request bound, strict correlation/ACK checks, HTTPS fallback and WSS re-probe. NativeDelivery shares its encrypted outbox/cursor cycle with executable Dart network tests. Single-use session refresh is coalesced and persisted before use. An initial full native GPRS regression failed its unchanged 15-second p95 gate; the raw failure remains retained. Independent send/sync scheduling and explicit detached TLS socket ownership now pass all six final current-native trials (2400 IDs). GPRS p95 is 4.672/4.928/4.742s; severe has no latency SLA. Child exit=0, current source hashes and a single binary set are checked; both earlier hanging variants remain failed. Combined faults remain incomplete.

Still missing: multi-device MLS leaf enrollment and server-authorized group changes, history transfer/recovery, QR camera, password reset, background delivery, metadata retention worker and delivered/read UI. Self-update epoch conflict/rebase has a real API test, but it is not a complete group workflow. The durable relay table has no pruning/fanout worker yet. Do not infer complete M2/M3/S0 gates from these component checks. PRODUCTION_APPROVED=false.

### Recipient delivery watermark

Native DM sync pages may carry peerProcessedSequence (protobuf field 5). It is
the greatest contiguous cursor acknowledged by a trusted, active device of a
different member account. A sender's own cursor cannot advance it. The server
relays this delivery indicator; it is not a signed read receipt. Clients cache
only positive increases in SQLCipher, so retries, reordered pages and an older
server omitting this additive field cannot regress the displayed state.

The build and generation scripts consume `contracts/runtime/wire.proto`.
The original brief schema remains in `contracts/wire.proto` for compatibility comparison.


### References in private text replies

Inside the MLS application payload, a reply optionally includes `replyTo` with the
original message UUID in `id` and the original authenticated device identity in
`sender`. Both coordinates are scoped to the same MLS group. They are stored
with the local encrypted draft and with the authored/received event. Outbox
retries reuse the original ciphertext. Ordinary text events retain their previous
wire format. The relay sees the existing envelope and cannot index reply edges.
Older readers display the new message's text normally.

The client resolves the preview against its own authenticated timeline. If the
original is outside local history it shows an unavailable-message label.
Messages containing spoilers use a generic preview. The application does not
send a copy of the quoted message or fetch it from the relay for preview.
### Optional profile photo

A trusted device can use `GET /v1/users/me/photo` and `PUT /v1/users/me/photo`. The JSON field `pixels` is either null (no photo, or remove on update) or base64 of exactly 6,912 bytes of 48 × 48 RGB pixels, top row first. The client previews the center crop and sends it only after the user chooses Save. The server stores one current thumbnail per account. These profile pixels are visible to the server and are separate from encrypted message content.

The update returns a nullable UUID `photoVersion`. Existing two-party conversation listings expose `peerPhotoVersion`; an unchanged thumbnail retains its version on retry. The client fetches the pixels using `GET /v1/conversations/{group}/photo/{version}` after a version is first seen. This request checks the same device membership and Welcome visibility as the listing. Unrelated conversations and retired versions return 404. Identical pixel data on different accounts has independent version identifiers. An old client can ignore the optional field. Removing a photo prevents future downloads but cannot erase copies a peer already obtained. Usernames, identity keys, trust decisions, and message formats are independent of photos.

### Public text channels

Verified, trusted devices can browse the catalog. Public channel content is readable by the hosting server. Public channel storage, membership, routes, post identifiers and UI are separate from private MLS conversations. The member list and owner account UUID are not included in the catalog. Any eligible account can subscribe and read. Publishing and deleting require the owner account.

| Route | Contract |
|---|---|
| GET /v1/public-channels | Search by ASCII handle prefix `q`. Set `mine=true` for owned/subscribed channels. Pass the response's optional `next` slug as `after` for the following 25-item page. |
| POST /v1/public-channels | Send a client-generated UUID `id`, lowercase `slug` (3–32 ASCII letters, digits or underscores) and `title` (1–80 Unicode scalars). An identical retry returns the existing ID. |
| PUT or DELETE /v1/public-channels/{id}/subscription | Subscribe or unsubscribe the authenticated account. Ownership already grants read access. |
| POST /v1/public-channels/{id}/posts | Owner sends `requestId` (client UUID) and `body` (1–2,048 Unicode scalars). Reusing an ID with different text returns 409. |
| GET /v1/public-channels/{id}/posts | Owner or subscriber reads up to eight newest posts. Pass the optional `next` sequence as `before` for strictly older posts. |
| DELETE /v1/public-channels/{id}/posts/{seq} | Owner clears post content. The request identifier remains reserved for at least 24 hours to handle late retries. |
| DELETE /v1/public-channels/{id} | Owner deletes the channel, posts and subscriptions. Its creator's request ID remains reserved for at least 24 hours. |

Each account can own eight channels and subscribe to 128 others. Each channel holds up to 2,000 visible posts. The API accepts up to ten new channels, 120 new publications and 180 new subscriptions per account per hour. The PostgreSQL transaction combines state changes and quota accounting. Deletions prevent future retrieval from the service. Recipients may retain earlier copies. Public text channels currently lack media, additional administrators, moderation reports, push delivery and external share links.
