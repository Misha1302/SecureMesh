# Контракт API и состояния данных (обязательные инварианты)

Это целевая спецификация. Реальная схема должна поддерживать миграции и генерируемый OpenAPI/protobuf и согласовываться с клиентами.

## 1. HTTP / WebSocket endpoints

| Resource | Method | Responsibility |
|---|---|---|
| `/health/live`, `/health/ready` | GET | process/readiness; no secrets |
| `/v1/auth/register` | POST | account+email verification trigger |
| `/v1/auth/login` | POST | bearer session, rotation, rate limits |
| `/v1/auth/refresh` | POST | one-time rotated refresh with reuse detection |
| `/v1/auth/logout` | POST | revoke current session |
| `/v1/auth/verify-email` | POST | consume expiring one-time token |
| `/v1/auth/recover` | POST | reset account access, not E2EE keys |
| `/v1/users/me` | GET/PATCH | self profile/settings |
| `/v1/users/by-username/{username}` | GET | privacy-scoped public profile |
| `/v1/devices` | GET/POST/DELETE | register/revoke device, trust workflow |
| `/v1/crypto/keypackages` | POST/GET | publish/lease one-time key packages; auth + freshness |
| `/v1/crypto/devices/{userId}` | GET | signed bindings/transparency references |
| `/v1/conversations` | GET/POST | DM/group open, membership policy |
| `/v1/conversations/{id}/members` | GET/POST/DELETE | authenticated invites, member change intent, MLS handshake must complete |
| `/v1/messages` | POST | idempotent encrypted envelope durable write |
| `/v1/sync` | GET | cursor pagination per device, ordered events |
| `/v1/acks` | POST | processed cursor/device receipts |
| `/v1/stream` | WSS | framed binary send, ack, sync, signaling |
| `/v1/media/uploads` | POST | allocate size/quota/auth bound upload session |
| `/v1/media/uploads/{id}/parts` | PUT | upload ciphertext chunk with checksum |
| `/v1/media/uploads/{id}/complete` | POST | commit manifest; get opaque media_id |
| `/v1/media/{id}` | GET | signed download / restricted private access |
| `/v1/channels` | GET/POST | discover/create public space |
| `/v1/channels/{id}/posts` | GET/POST | public feed and publication |
| `/v1/search` | GET | public only; private search client-side |
| `/v1/reports` | POST | user-selected content report |
| `/v1/admin/*` | scoped | admin roles, complaint queues, policy/audit, MFA |
| `/v1/calls/*` | WebSocket/POST | one-to-one signaling/call state |

All endpoints implement server-side authorization including object-level checks, request validation, rate-limits, metrics, error response codes, cursor ownership, request-size limits, anti-CSRF (cookie mode), audit as applicable.

## 2. Основные сущности / PostgreSQL indexes

- `users(id UUID PK, username CITEXT UNIQUE, email_hash/normalized_email UNIQUE, display_name, status, created_at, ... )`. Для реальной email доставки email должен быть доступен сервису, но хранить encrypted-at-rest PII или более privacy-preserving lookup index; не делать email_hash единственным полем без возможности отправки писем.
- `password_credentials(user_id PK, argon2id_phc, updated_at)` — PHC включает параметры и salt, plaintext не хранится.
- `device_identities(id UUID PK, user_id FK, public_signature_key, credential_binding, created_at, revoked_at, verified_state, version)`.
- `sessions(id, user_id, device_id, token_hash, rotated_at, revoked_at, expires_at)`; `email_tokens` hashed and one-use.
- `crypto_key_packages(id, device_id, public_payload, created_at, expires_at, used_at, last_resort)`; allocate atomically.
- `conversations(id, kind E2EE_DM/E2EE_GROUP/PUBLIC_DISCUSSION, created_at, ...)`.
- `conversation_members(conversation_id, user_id, role, joined_at, left_at, ...)` and `member_devices` or equivalent explicit device membership; preserve membership snapshots/history.
- `message_envelopes(id, conversation_id, server_seq, sender_user_id, sender_device_id, client_message_id, ciphertext BYTEA, ciphertext_hash, mls_epoch, envelope_kind, created_at)`; UNIQUE(conversation_id, sender_device_id, client_message_id), UNIQUE(conversation_id, server_seq), append-only core.
- `delivery_cursors(device_id, conversation_id, last_persisted_seq, ...)`; ack monotonic with compare-and-swap.
- `outbox_events(id, aggregate_key, event_kind, payload, status, next_attempt, created_at)` inserted in message transaction.
- `media_assets(id, owner_id, storage_key, encrypted/private, bytes, chunks, digest, created_at, deleted_at, ...)` + upload sessions/quotas.
- `channels`, `channel_members`, `public_posts`, `public_post_media`, `public_reactions`, `reports`, `moderation_actions`, `admin_audit`.

For production scale, avoid a global monotonic sequence per all chats; per-conversation sequence serialized using a dedicated row/atomic update or another verified concurrency model. Must test concurrent message writes and MLS group commits.

## 3. Протокол отправки: idempotency contract

Request: `sender_device_id` (from auth; not trusted client value), `conversation_id`, `client_message_id` UUID/ULID, `envelope_kind`, `mls_epoch`, `ciphertext` opaque bytes, optional `payload_digest` (server verifies hash).

Response on new insert: `server_message_id`, `server_sequence`, `durable=true` (only after DB commit), status `SAVED`.

Response on identical retry: **same** `server_message_id` and `server_sequence`.

Response on same ID and **different** ciphertext: `409 IDEMPOTENCY_CONFLICT`.

If pending DB write fails: 503 or fail, **no success ACK**.

If unauthorized recipient/device or revoked: 403 and no metadata leakage. Do not trust client-supplied role or sender ID.

## 4. Cursor and event flow

Use cursors containing device_id + conversation_id + monotonic sequence, opaque signed/encrypted when exposed as bearer to prevent tampering. Pagination `limit` <= 100 events by default; bounded bytes/page. Server returns `events`, `next_cursor`, `has_more`, optional stale warning and earliest retained cursor. Sender and recipient maintain separate `processed_seq`/receipt; decrypt errors and blocked MLS epochs do not silently advance cursor beyond recoverable state. For a multi-group sync, cursor may be a stream-specific monotonic number or per-conversation vector; choose one proven implementation and document invariants.

## 5. Deletion/edit/reaction events

Private edits/deletes/reactions are MLS encrypted typed application events referring to canonical message ID, authenticated sender and original conversation. Need anti-spoof tests. Server may perform retention deletion of ciphertext according to explicit policy; it cannot enforce erasure of already downloaded data on another device. Public edits and reactions may be server-visible with version checks.

## 6. Media transfer API

Upload session records declared size, content class `private_ciphertext` or `public_media`, quota, part index, per-part length/digest. Client may retry part with same digest; complete verifies all parts, commits manifest atomically and returns immutable opaque asset ID. Download uses ranged GET/signed URLs with scope and TTL; client verifies authenticated chunks before rendering.

## 7. Versioning and failure handling

Protobuf and HTTP contracts versioned, additive schema only within major version; schema migration compatibility tests. Error codes machine-readable; retries only idempotent operations or operations with idempotency keys. Bounded body and request timeout policies preserve 2G budget while preventing DoS (not infinite timeouts). Server is never a hidden source of E2EE plaintext.
