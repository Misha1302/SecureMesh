'use strict';

const cachePrefix = `securemesh-guide:${self.registration.scope}:`;
const cacheName = `${cachePrefix}v1`;
const url = (name) => new URL(name, self.registration.scope).href;
const home = url('./');
const index = url('index.html');
const assets = [
  index,
  url('profile.html'),
  url('profile.css'),
  url('profile.js'),
  url('vault.js'),
  url('mesh-worker.js'),
  url('messenger.js'),
  url('account.js'),
  url('crypto/securemesh_browser_crypto.js'),
  url('crypto/securemesh_browser_crypto_bg.wasm'),
  url('app.css'),
  url('app.js'),
  url('manifest.webmanifest'),
  url('icon-192.png'),
  url('icon-512.png'),
  url('icon-maskable-512.png'),
  url('apple-touch-icon.png'),
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName);
    await cache.addAll(assets.map((asset) => new Request(asset, {
      cache: 'reload',
      credentials: 'omit',
      redirect: 'error',
    })));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(
      names.filter((name) => name.startsWith(cachePrefix) && name !== cacheName)
        .map((name) => caches.delete(name)),
    );
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET' || request.headers.has('authorization') ||
      request.headers.has('range')) return;

  const asset = request.mode === 'navigate' && request.url === home ? index : request.url;
  if (!assets.includes(asset)) return;

  event.respondWith((async () => {
    try {
      const response = await caches.match(asset, { cacheName });
      if (response) return response;
    } catch {
      // A disabled or evicted cache can still use the browser's network path.
    }
    return fetch(request);
  })());
});
