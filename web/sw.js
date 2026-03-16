const CACHE = "rena-v18";
const STATIC = ["/", "/index.html", "/css/app.css", "/js/config.js", "/js/api.js", "/js/voice.js", "/js/app.js", "/worklet/audio-processor.js", "/manifest.json"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(STATIC)));
  self.skipWaiting();
});

self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});

self.addEventListener("fetch", e => {
  // Never cache API or WebSocket calls
  if (e.request.url.includes("run.app") || e.request.url.includes("accounts.google.com")) return;
  e.respondWith(
    caches.match(e.request).then(cached => cached || fetch(e.request))
  );
});
