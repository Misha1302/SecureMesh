# 2G-first протокол: детальные требования

## 1. Проблема и нефальсифицируемые обещания

2G (GPRS/EDGE) — не единая скорость или задержка. Существуют реальные конфигурации со скоростью менее 10 Кбит/с, потерями, нестабильным NAT/радиоканалом и периодами полного обрыва. Гарантировать мгновенную доставку невозможно; можно сделать **устойчивое хранение, повтор и последующую доставку**, когда канал снова доступен.

В режиме 2G обязательны только короткие текстовые сообщения и контрольная служебная информация. Медиа — по запросу/на Wi-Fi, без автоматической подгрузки. Новые MLS KeyPackages/Commits могут быть больше обычного текста: оценивайте overhead и не маскируйте его.

## 2. Транспорт и framing

1. Основной: один persistent WSS `/v1/stream`, TLS 1.3, protocol version negotiation, heartbeat с учётом сети и battery.
2. Fallback: HTTPS POST `/v1/messages`, GET `/v1/sync?cursor=...&limit=...`, long-poll optional, без request per keystroke.
3. Frames: Protobuf (см. `contracts/wire.proto`); varint length-prefix + strict maximum frame length, unknown fields tolerated by versioned schema.
4. Не включать произвольное zlib на секретных plaintext вместе с attacker-controlled fields; для маленького текста application compression обычно не нужна, в частности не использовать compression context рядом с секретами.
5. Квоты на memory buffers, cancellation, bounded queues/backpressure; неспособность клиента потребить stream не должна приводить к unbounded RAM.
6. Время/даты: серверные UTC timestamps для отображения, но порядок — только server sequence и MLS epoch; не rely on client clock.

### Минимальный wire envelope
`protocol_version`, `request_id`, `session_resume_token` (короткоживущий и связан с устройством), `type`, `conversation_id`, `sender_device_id`, `client_message_id`, `server_sequence`, `cursor`, `ciphertext`, `payload_type`, `ack_seq`/`received_seqs`, `retry_after_ms`. Включать только реально нужное поле по типу сообщения, избегать повторной передачи строковых имен.

**Security:** идемпотентность не равна защите от сетевого replay. Auth, проверка membership, MLS replay/epoch checks, связывание IDs с аутентифицированной идентичностью и ограничение возраста сообщений обязательны.

## 3. Состояние и durable semantics

### Клиент
- Перед отправкой transactionally save outbound event в encrypted SQLite (`client_message_id`, immutable ciphertext, target, attempt/backoff, status).
- UI статус `queued`; не создавать вторую копию при повторном нажатии retry.
- Retrying: exponential backoff + full jitter и быстрое возобновление при detected connectivity change; throttle при серверном `retry_after`.
- После ACK durable server commit сохранить mapping `client_message_id => server_seq` и удалить outbox запись/пометить persisted.
- По возврату сети: authenticate resume, sync missing events by cursor, дождаться local transaction commit, только после этого ACK own processed cursor.
- State machine должна быть протестирована на crash между любыми двумя шагами.

### Сервер
- Идемпотентный ключ `conversation_id + sender_device_id + client_message_id` с unique constraint и проверкой одинакового digest payload; повтор **с другим** ciphertext при том же ID -> 409/explicit conflict.
- INSERT message и outbox event в **одной транзакции**; durable ACK после COMMIT, не раньше.
- Получатель доставку подтверждает отдельно: ACK processed cursor после локального коммита.
- Клиентские read receipts — opt-in; серверное `delivered` означает только успешное подтверждение device commit.
- Queue/retention лимиты: долго офлайн клиенты — постраничная fetch-synchronization с continuations; не держать миллионы событий в едином frame.
- Если device не может дешифровать из-за устаревшей эпохи, это отдельное состояние, НЕ удалять сообщение/не считать доставленным; восстанавливать MLS context или сообщать actionable error.

## 4. Не смешивать подтверждения

- **transport ACK**: WebSocket/TCP доставил байты до узла — не использовать как durable status.
- **durable ACK**: DB commit succeeded.
- **device receipt**: приложение устройства записало событие.
- **read receipt**: пользователь/клиент опционально отметил прочтение.

## 5. Порядок событий и MLS

Per-conversation server sequence monotonic и атомарный; сервер должен корректно упорядочивать MLS handshake и application messages (proposal/commit в согласованном epoch порядке), решать concurrent commits через ожидаемую версию эпохи и retry. **Не** менять protocol payload при повторной отправке уже сформированного сообщения. При нескольких устройствах — отдельный MLS participant identity для каждого устройства, отдельные device cursors; members devices must be authorized.

## 6. Сетевые профили для CI и измерений

Тестировать на изолированных сетевых интерфейсах/netns контейнеров; **не** использовать `tc qdisc add dev eth0 ...` на хосте владельца. Рекомендуется `tc netem` в test network namespace или контейнере, Toxiproxy для deterministic disconnect/latency; bandwidth нужно измерять на прикладном канале обеих сторон.

| Профиль | Bandwidth | RTT целевой | Packet loss | Ожидаемая проверка |
|---|---:|---:|---:|---|
| Normal | 10 Mbit/s | 50 ms | 0% | baseline |
| EDGE | 100 Kbit/s | 600 ms | 1% | fast reliable texting |
| GPRS | 20 Kbit/s | 1500 ms | 3% | P0 texting, p95 <=15 sec при тёплом соединении |
| Severe | 10 Kbit/s | 3000 ms | 10% | eventual delivery, no duplicates, no deadline |
| Blackout | 0 Kbit/s for 60 sec then EDGE | — | 100% then 1% | outbox persistent, eventual catch-up |
| Crash | process kill at random send/ACK steps | varies | varies | idempotence and recovery |
| Half-open | WSS appears live but packets black-holed | varies | 100% selected direction | timeout -> fallback/renew |

Профили — **синтетические stress-параметры**, а не характеристика всех сетей второго поколения. Отдельно нужны реальные устройства/операторы перед рыночным заявлением.

## 7. Измерения и строгие acceptance gates

- 200 сообщений от A к B, 200 от B к A, размеры 1..400 Unicode символов, реальное MLS; 3 независимых seed; перемешанные ACK drop, reconnect, process crash.
- 0 потерянных **после durable ACK** и 0 логических дублей во всех тестах; all eventual under functioning link and surviving DB. Сверить IDs, не только count.
- p95 end-to-end (warm connection, deterministic GPRS baseline) <= 15 sec **как инженерная цель**; если честно не достигнуто, зафиксировать RED и оптимизировать, не снижать критерий молча.
- Over-the-wire bytes for короткое текстовое MLS сообщение измерить и привести медиану/p95 с TLS record/network overhead отдельно от application payload; baseline цель <= 1 KiB для 100 UTF-8 chars, если криптопакет больше — описать размер и невозможность выполнить цель без ослабления безопасности.
- Media upload paused on low bandwidth and must not starve text; проверить fairness под постоянным большим upload.
- 30 минут нестабильной сети: bounded memory, no CPU spin, разумный battery baseline на реальном устройстве.
- Синхронизация при 1000 offline messages chunked и cursor-based, с корректным порядком MLS epoch.

## 8. Оптимизации, не ухудшающие безопасность

- Уменьшение protobuf envelope, удаление ненужных полей и неиспользуемых heartbeat.
- Группировка ACK и sync events, bounded prefetch, приоритет control+text над media.
- Абстракция NetworkQualityEstimator на p95 RTT / reconnect count / effective throughput; избегать определения «2G» лишь по OS network type.
- Connection resume, no repeated full auth handshake unless needed; reusing TLS sessions only if безопасно и поддерживается платформой.
- Локальный полнотекстовый поиск для private history; глобальный public search по API, не синхронизировать лишние посты.
- Не хранить все media thumbnails как base64 в сообщениях; отдельные manifests.

## 9. UI состояния связи

`online`, `weak connection`, `offline`, `queued N`, `syncing`, `key verification required`. Должно быть понятно, что «написано» не означает «уже на сервере». Клик по медиа на 2G предлагает «Скачать несмотря на слабую сеть».
