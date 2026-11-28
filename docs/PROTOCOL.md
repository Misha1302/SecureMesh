# Implemented protocol slice

API v1 supports verified local accounts, per-device Ed25519 proof of possession, opaque bearer sessions and single-use rotating refresh families. Later devices receive account-only pending sessions. Private delivery requires trusted activation; old-device approval alone does not activate the candidate. The candidate verifies its independently pinned approver and signs activation locally. See DEVICE_TRUST.md for the signed, expiring protocol and its remaining QR/multi-device limitations. Every active WebSocket frame revalidates the database session and device revocation. Authentication uses the Authorization header; no query-string tokens or cookies.

Private send, sync and processed acknowledgements share the same database transaction gate on HTTPS and WebSocket. An operation takes a shared lock on its account and then rechecks its exact bearer session before accessing conversation state. Password recovery takes the same lock exclusively before revoking sessions. An operation that holds the lock first can finish against the old session. If recovery holds it first, an old-session operation returns 401 without reading or changing delivery state. A response may still arrive after recovery for an operation that already completed in the database.

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
computes this delivery indicator. A compromised server can advance the watermark. The UI attributes the delivery report to the server. There is no recipient-signed delivery proof or read receipt. Clients cache
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

### Private-chat profile text

A trusted device reads or replaces its account’s optional biography and status message at `/v1/users/me/profile-text`. GET returns nullable `bio` and `status` strings and an integer `revision`. PUT requires all three fields. Send null to clear a field. An update with a stale revision returns HTTP 409 unless it repeats values already saved. The client keeps the draft on conflict. The server normalizes text to NFC and accepts up to 280 Unicode scalar values for a biography and 80 for a single-line status. The status is user-authored text independent of presence.

Profile text is readable by the server. An active trusted device can request its peer’s fields at `GET /v1/conversations/{id}/profile-text/{peerDevice}` for an established one-to-one conversation. The directory must hold an acknowledged Welcome, including for existing conversations. Legacy conversations without this record cannot disclose profile text. The Flutter client fetches these fields when the user opens a contact profile whose stored conversation, username, device and identity key match the directory and the local key pin. Unrelated conversations and devices receive HTTP 404. These fields are omitted from directory listings. Clearing a field takes effect on the next fetch. Copies a peer already obtained may remain on their device.

### Public text channels

Verified, trusted devices can browse the catalog. Public channel content is readable by the hosting server. Public channel storage, membership, routes, post identifiers and UI are separate from private MLS conversations. The member list and owner account UUID are not included in the catalog. Any eligible account can subscribe and read. Publishing and deleting require the owner account.

| Route | Contract |
|---|---|
| GET /v1/public-channels | Search by ASCII handle prefix `q`. Set `mine=true` for owned/subscribed channels. Pass the response's optional opaque `next` cursor as `after` for the following 25-item page. |
| POST /v1/public-channels | Send a client-generated UUID `id`, lowercase `slug` (3–32 ASCII letters, digits or underscores) and `title` (1–80 Unicode scalars). An identical retry returns the existing ID. |
| PUT or DELETE /v1/public-channels/{id}/subscription | Subscribe or unsubscribe the authenticated account. Ownership already grants read access. |
| POST /v1/public-channels/{id}/posts | Owner sends `requestId` (client UUID) and `body` (1–2,048 Unicode scalars). Reusing an ID with different text returns 409. |
| GET /v1/public-channels/{id}/posts | Owner or subscriber reads up to eight newest posts. Pass the optional `next` sequence as `before` for strictly older posts. |
| DELETE /v1/public-channels/{id}/posts/{seq} | Owner clears post content. The request identifier remains reserved for at least 24 hours to handle late retries. |
| DELETE /v1/public-channels/{id} | Owner deletes the channel, posts and subscriptions. Its creator's request ID remains reserved for at least 24 hours. |

Each account can own eight channels and subscribe to 128 others. Each channel holds up to 2,000 visible posts. The API accepts up to ten new channels, 120 new publications and 180 new subscriptions per account per hour. The PostgreSQL transaction combines state changes and quota accounting. Deletions prevent future retrieval from the service. Recipients may retain earlier copies. Public text channels currently lack media, additional administrators, moderation reports, push delivery and external share links.

### Invitation-only server-readable channels and owner edits

To create a restricted channel, send the ordinary channel body to the distinct `POST /v1/public-channels/invite-only` route. The response must include `inviteOnly:true` before the native client offers to publish. Older servers reject this route. Privacy cannot be downgraded to public creation by ignoring an unknown JSON property. The visibility mode is immutable. This is an access-controlled bulletin, not a private MLS group. The hosting service can read the posts and membership.

Set `includeRestricted=true` in the catalog request to list your own channels, active invitations and subscribed restricted channels alongside public matches. Pre-invitation clients receive only public results. A restricted channel never reserves its slug in the public namespace. Cursors sort by slug and ID to handle equal names. Unrelated trusted accounts cannot discover, subscribe to or read a restricted channel even when given its UUID. A pending invitation grants access to metadata only. No public invitation URLs are generated.

| Operation | Behavior |
|---|---|
| Owner invites | POST `/v1/public-channels/{id}/invitations` with an exact `username`. Verified recipients see the invitation for seven days. An unknown username gets the same generic acknowledgement. Up to 120 attempts per owner per hour, 64 active invitations per channel and 128 per recipient. |
| Invitee accepts or declines | PUT `.../subscription` accepts; DELETE declines or leaves. Both consume the invitation. A former member needs a new invitation to return. |
| Owner withdraws access | POST `.../revoke-access` with the exact username to cancel an invitation or remove a subscriber. Future reads require a new invitation and acceptance. Up to 240 attempts per owner per hour. Copies already received by members remain outside server control. |
| Owner edits a post | PUT `.../posts/{seq}` with `body` and `expectedRevision`. A successful edit increments `revision` without reordering the feed. A stale revision returns 409, except when the immediately preceding identical edit succeeded and its response was lost. The UI marks edited posts. Up to 240 edits per owner per hour. |

Migration 011 keeps a public-only compatibility view for the original server binary, while all upgraded writes and visibility checks use the full catalog. Existing public channels retain their accounts, post IDs, subscriptions and visibility. The upgraded client labels restricted channels as server-readable.

For two real Flutter sessions against the isolated HTTPS integration server, run `.local/venv/bin/python tests/integration/public_channels.py --ui` from the repository root after local bootstrap and Flutter dependency installation. Test accounts, device keys and credentials belong to that fixture.
