# Тестовое размещение SecureMesh PWA

GitHub Actions собирает архив `securemesh-pwa` для лабораторного стенда. Сайт проекта на GitHub Pages публикуется отдельно. Для испытания браузерного клиента нужен выделенный HTTPS‑домен, где размещены только файлы PWA. Клиент обращается к одному заданному API по HTTPS. Используйте отдельные тестовые аккаунты и данные.

## Подготовка файлов

Скачайте артефакт задания **Package SecureMesh web app** или соберите его из выбранного коммита в новом каталоге. Для воспроизводимой локальной сборки в Linux установите Rust 1.100.0 и wasm-bindgen CLI 0.2.130.

```sh
rustup toolchain install 1.100.0 --profile minimal --target wasm32-unknown-unknown
cargo +1.100.0 install wasm-bindgen-cli --version 0.2.130 --locked
python3 scripts/package-pwa.py /tmp/securemesh-pwa
cd /tmp/securemesh-pwa
sha256sum --check --strict SHA256SUMS
```

Сборщик берёт файлы по явному списку и заново собирает WebAssembly и JS-загрузчик с закреплённым `Cargo.lock` в чистом каталоге. Эти два файла попадают в пакет после побайтовой сверки с файлами в репозитории. При расхождении сборщик завершает работу с ошибкой. Идентификатор кеша service worker зависит от содержимого пакета. `SHA256SUMS` позволяет проверить целостность файлов после копирования. Храните ведомость хешей вне корня сайта и публикуйте только проверенный каталог `app/`.

## Тестовый веб-сервер

Пример для Caddy. Замените `pwa.test.example.org` точным HTTPS‑именем лаборатории и разместите каталог `app/` в `/srv/securemesh-pwa/www/`. Версия PWA в этом репозитории предназначена для API `https://securemesh.90-156-230-119.sslip.io`. Для отдельного API‑стенда вместе поменяйте фиксированный адрес клиента и разрешённый узел в `connect-src`, затем соберите пакет повторно.

```caddyfile
pwa.test.example.org {
    root * /srv/securemesh-pwa/www
    header {
        -Server
        Content-Security-Policy "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self'; manifest-src 'self'; worker-src 'self'; connect-src 'self' https://securemesh.90-156-230-119.sslip.io; base-uri 'none'; object-src 'none'; form-action 'none'; frame-ancestors 'none'"
        X-Content-Type-Options nosniff
        Referrer-Policy no-referrer
        Cross-Origin-Resource-Policy same-origin
        Cache-Control no-cache
    }
    @entry path / /app
    redir @entry /app/ 308
    @assets path /app/*
    handle @assets {
        @wasm path *.wasm
        header @wasm Content-Type application/wasm
        file_server
    }
    handle {
        respond 404
    }
}
```

CSP разрешает только собственные скрипты и worker, компиляцию WebAssembly и запросы к указанному API. Service worker хранит статические ресурсы из списка для пути `/app/`. Запросы API, заголовки авторизации и пользовательские данные через этот кеш не проходят.

В конфигурации API задайте `BrowserClientOrigin=https://pwa.test.example.org`. Используйте точный адрес лаборатории со схемой и портом при наличии, без пути и завершающей косой черты. Без этой настройки CORS для веб-клиента выключен. TLS‑сертификат API должен быть действителен. До запуска испытаний убедитесь, что инфраструктура API не кеширует ответы с данными аккаунта.

## Проверка на стенде

1. В Safari на iPhone откройте `https://pwa.test.example.org/app/` и добавьте страницу на экран «Домой». Откройте значок при подключении к интернету. Перейдите в справку по ссылке SecureMesh в шапке мессенджера и дождитесь отметки «Справка доступна офлайн».
2. В лаборатории профиля проверьте создание и открытие тестового профиля. Проверьте web–native обмен на паре отдельного браузерного и нативного устройства. Сверьте ключи до обмена.
3. Отключите сеть, закройте приложение и откройте его с экрана «Домой». Проверьте запуск справки и открытие локального профиля. Для отправки и получения сообщений восстановите сеть.
4. Сверьте в инструментах браузера список кешированных путей с пакетом. Убедитесь, что вызовы API проходят только к указанному узлу и что запрос с постороннего origin не получает разрешающий CORS‑заголовок.

Артефакт предназначен для испытания. Публичный выпуск требует проверки на физическом iPhone, независимого аудита безопасности и разрешения владельца проекта.
