'use strict';

const cachePrefix = `securemesh-guide:${self.registration.scope}:`;
const cacheName = `${cachePrefix}v1`;
const url = (name) => new URL(name, self.registration.scope).href;
const home = url('./');
const index = url('index.html');
const releaseIntegrity = null;
const labAssets = [
  'index.html',
  'profile.html',
  'profile.css',
  'profile.js',
  'vault.js',
  'mesh-worker.js',
  'messenger.js',
  'private-image.js',
  'history-search.js',
  'account.js',
  'crypto/securemesh_browser_crypto.js',
  'crypto/securemesh_browser_crypto_bg.wasm',
  'app.css',
  'app.js',
  'manifest.webmanifest',
  'icon-192.png',
  'icon-512.png',
  'icon-maskable-512.png',
  'apple-touch-icon.png',
];

const entries = releaseIntegrity ? Object.entries(releaseIntegrity) : labAssets.map((name) => [name, '']);
const assets = new Map(entries.map(([name, integrity]) => [url(name), integrity]));

function assetRequest(asset) {
  const integrity = assets.get(asset);
  const request = new Request(asset, {
    cache: 'no-store',
    credentials: 'omit',
    integrity,
    mode: 'same-origin',
    redirect: 'error',
  });
  if (integrity && request.integrity !== integrity) {
    throw new Error('Static asset integrity is unavailable');
  }
  return request;
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const existingCache = await caches.has(cacheName);
    const cache = await caches.open(cacheName);
    try {
      // Cache.addAll writes the complete set or none of it.
      await cache.addAll([...assets.keys()].map(assetRequest));
    } catch (error) {
      if (releaseIntegrity && !existingCache) await caches.delete(cacheName);
      throw error;
    }
    // The default activation lifecycle leaves earlier controlled clients on their release.
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
  if (!assets.has(asset)) return;

  event.respondWith((async () => {
    try {
      const response = await caches.match(asset, { cacheName });
      if (response) return response;
    } catch {
      // A disabled or evicted cache can still use the browser's network path.
    }
    return fetch(assetRequest(asset));
  })());
});
