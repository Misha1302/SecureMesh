# SecureMesh V2 — продуктовый каталог функций

Стандарт: не «визуальные заглушки», а backend + storage + client UX + security + реальные тесты. Каждый ID переводится в DONE_VERIFIED только после E2E и негативных проверок. Функции Telegram выступают сценарием использования, а не архитектурой защиты. Номер телефона необязателен, публичные username псевдонимны, но IP и метаданные не обещано скрыть.

## P0 — личное общение, идентичность и восстановление
- A01: один аккаунт, username/стабильный ID, profile/avatar/bio/privacy, вход/выход, опциональные email/phone, password+Argon2id, passkeys где доступны, refresh rotation, защита от перебора и enumeration. Сегодня email-обязательный backend менять только с безопасной миграцией.
- A02: много активных устройств, независимые device credentials и MLS keys; список активных устройств, trusted enrollment с QR/подписью, отзыв, alerts о новом устройстве и смене identity; login не равен E2EE-trust.
- A03: синхронизация новых E2EE сообщений на все подтверждённые устройства, независимые cursors/outbox; история с ранее доверенного устройства или пользовательского E2EE backup; локальный зашифрованный поиск по истории.
- A04: отдельный пользовательский recovery key (высокая энтропия), клиентские encrypted backup snapshots и восстановление с нуля; без всех устройств+recovery key старая приватная история невосстановима; account password reset не расшифровывает данные.
- M01: 1:1 E2EE с реальной отправкой по username (chat request, accept/reject/block), per-device MLS, подтверждённые KeyPackages, отсутствие скрытого участника.
- M02: закрытые групповые E2EE чаты: создание/приглашение/ссылка/вход/выход/бан/роли, group MLS epoch/rekey и доставка Welcome; исключённый участник не видит **будущие** сообщения; исходная история может у него остаться.
- M03: сообщения Unicode/emoji/rich text, ответ/цитата, редактирование, удаление для себя/всех (best-effort), пересылка с privacy rules, reactions, pin, mention, hashtags, spoiler, безопасные ссылки/preview, сообщения себе, черновики, архив, папки, mute.
- M04: TTL/disappearing messages, one-time media, настройки read receipts/typing/last seen, временные события и подтверждения; не обещать невозможность скриншота или уничтожение внешней копии.
- M05: честные состояния queued/sending/durable/delivered/read(opt-in), UUID dedup, надёжная off-line очередь, 2G приоритет текста и MLS-control; без plaintext fallback.

## P1 — каналы как в Telegram, публичные группы и посты
- C01: каналы public/invite-only, создание/редактирование/удаление, username/короткие ссылки, avatar/description, subscribers, join/leave, владелец/редакторы/админы и permissions, подписка и настройки уведомлений. Invite-only канал помечать server-visible: он **не** E2EE.
- C02: канал-публикация: форматированный текст, фото/альбом, видео/кружочки/голос/файл, черновик, запланированный пост, редактирование/удаление, реакция, закрепление, публичный permalink, репост, опрос, агрегированный счётчик просмотров без поимённого трекинга по умолчанию.
- C03: публичные посты и канал-листинг, feed по подпискам (хронологический MVP), публичный поиск по каналам/постам/тегам, comments через привязанную группу, темы/topics, ветки обсуждения, mentions, moderation.
- G01: публичные / ограниченные группы с ролями, invite links и сроками, join requests, mutes/bans/slow mode, topics/threads, pinned messages, реакции, защита от спама, жалобы, аудит модерации и granular ACL.
- G02: строгое разделение закрытых E2EE групп и публичных server-visible групп; приватная переписка не попадает в поиск/модерацию без явного user-selected disclosure.
- C04: один публичный пост + fanout pointers/cursors; не создавать E2EE copy для каждого подписчика. Пагинация, квоты, антинакрутка просмотров, контроль прав на публикацию.

## P1 — медиа, кружочки, звонки
- F01: фото/альбомы/изображения/GIF/stickers/файлы/документы/ZIP/обычное видео; preview/download, cancel/resume/checksum/size limit, клиентское E2EE/private chunks, signed URLs/ACL/TTL и квоты.
- F02: **голосовые**: mic permission, запись/остановка/отмена, Opus или обоснованный эквивалент, wave/duration/progress/seek/play/speed и фоновое воспроизведение при допустимой политике.
- F03: **кружочки**: камера permission, front/rear camera, запись, предварительный просмотр в круге, crop/aspect/orientation, сжатие, отправка, отмена, воспроизведение на получателе, ограничения длительности/размера; собственная визуальная реализация, не копия Telegram.
- F04: публичное медиа может безопасно транскодироваться сервером; приватное шифруется **до** загрузки на клиенте с уникальным per-file ключом в E2EE manifest, приватные thumbnails тоже клиентские. Публичное фото очищать от EXIF/геометок по безопасной политике.
- F05: 2G: никаких автоматических загрузок медиа, autoplay, фонового upload при нехватке полосы; очередь коротких текстов/MLS и ACK обслуживается раньше медиа; adaptive/resumable chunks.
- AV01: WebRTC 1:1 голосовые и видеозвонки с TURN, signaling, проверка идентичности устройства, mute/camera swap/reconnect, понятный отказ при плохой сети. Не обещать звонки на 2G или криптографическую E2EE гарантию звонка без проверки binding.
- N01: privacy-safe push APNs/FCM, локальная расшифровка уведомлений, настройки per-chat, foreground/background resume, RU/EN.

## P1 — UX, инфраструктура, антиабьюз
- U01: Flutter app onboarding, chats, DM by username, groups, channels, feed, search, media, recovery, trusted devices, user privacy, moderation/admin, calls, settings, animations, light/dark, accessibility, small-screen/mobile/desktop; реальные тесты платформ.
- U02: пользовательские функции экспорт/удаление своих данных, download management, cache purge, backups, settings for privacy; retention честно ограничивает deletion чужих копий.
- S01: модерация публичных данных, жалобы на private сообщения только после раскрытия выбранного пользователем контента, abuse limits, admin MFA/RBAC/audit; оператор никогда не получает E2EE keys.
- S02: не навязывать импорт адресной книги, телефон, геолокацию, рекламную аналитику, скрытое идентифицирование устройств.

## P2 — максимально широкий Telegram-подобный набор после P0/P1
Stories, live streams, group calls, расширенные polls/quiz, community collections, bots/mini-app permission model, advanced topics, custom themes, advanced sticker packs, smart folders, scheduled/recurring messages, chat export/import, rich channel analytics, custom admin commands, premium-like UI options без реального биллинга, расширенные публичные API. Каждая новая возможность проходит отдельную безопасность/2G/ACL проверку; не добавлять фейковые кнопки.
