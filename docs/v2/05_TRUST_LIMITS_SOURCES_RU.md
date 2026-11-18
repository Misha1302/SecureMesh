# SecureMesh V2 — границы обещаний, эксплуатационная приватность и источники

**«Администратор не сможет прочитать шифротекст с сервера даже если захочет»** — проверяемая архитектурная цель при недоверенном сервере и доверенных клиентских ключах. Не означает, что пользователь не сможет добровольно раскрыть свой recovery key, что украденное разблокированное устройство безопасно, что IP не наблюдается провайдером или что злонамеренное обновление клиента невозможно. Не использовать маркетинговые абсолюты.

Отдельные угроза-модели: скомпрометированный VPS/DB/backup; malicious identity/KeyPackage directory и split-view; supply-chain/update signer; скомпрометированный endpoint; abusive registered user; network observer. Для каждой — что гарантируется, что обнаруживается, что остаётся риском, негативные тесты и ограничения.

Privacy ops: не требовать телефон; опциональный email при достаточной anti-abuse модели; псевдонимы, минимизация IP/time/membership logs и сроков хранения, privacy-safe push/metrics/analytics, S3 logs, user-selected disclosure при жалобах, публичный контент модератору доступен, private plaintext нет. Admin MFA, ролевая авторизация, audit/dual approval, резервные копии вне VPS, проверенный restore. Ограничения удалений: уже полученные копии/скриншоты/экспорты неизвлекаемы из чужих устройств по протоколу.

**Официальные референсы (сверять актуальность перед реализацией):**
- Telegram FAQ, перечень UX-функций групп, каналов, сообщений, разницы cloud/secret chats: https://telegram.org/faq
- Telegram история функций и расширений: https://telegram.org/blog
- Signal Secure Backups как образец пользовательского recovery key без доступа сервиса: https://support.signal.org/hc/en-us/articles/9708267671322-Signal-Secure-Backups
- MLS RFC 9420: https://www.rfc-editor.org/rfc/rfc9420
- OpenMLS: https://openmls.tech/
- W3C WebAuthn: https://www.w3.org/TR/webauthn-3/
- WebRTC: https://www.w3.org/TR/webrtc/
- OWASP ASVS: https://owasp.org/www-project-application-security-verification-standard/

Не включать чужой код, брендинг, иконки/логотипы и точные визуальные ассеты Telegram. Выбранные библиотеки проверять на совместимость, лицензии и обновлённые advisories. Не заявлять «аудировано», если внешнего аудита не было.
