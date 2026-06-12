/* Service worker for the mini-OS desktop PWA.
 *
 * Caches only the shell and the lightweight static app pages so cold loads are
 * instant. Everything live or auth-sensitive is network-only and never touched:
 *   /api/*        manager API (status, notes, desktop state, uploads…)
 *   /browser/*    xpra HTML5 client + WebSocket
 *   /tN/*         ttyd terminals + WebSocket
 *   /terminals/   tabbed terminal UI (tied to live /tN/ iframes)
 *   /files/*      FileBrowser SPA + API
 *   /fileview/*   raw file passthrough
 *   /services.json host-local, changes out of band
 *   /cdn-cgi/*    Cloudflare Access challenge/redirects — caching these breaks auth
 *
 * Bump VERSION whenever the shell/static pages change; activate() drops old
 * caches. sw.js itself is served no-store (nginx `location /`), so the browser
 * re-checks it on navigation and picks up the new VERSION.
 */
const VERSION = 'v18';
const CACHE = 'shell-' + VERSION;

const PRECACHE = [
  '/',
  '/landing.html',
  '/notes.html',
  '/monitor.html',
  '/upload.html',
  '/filebrowser-patches.js',
  '/manifest.json',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/apple-touch-icon.png'
];

// Paths that must always hit the network (live data, websockets, auth).
const BYPASS = /^\/(api|browser|t\d|terminals|files|fileview|services\.json|cdn-cgi)/;

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // Don't let one failed precache (e.g. an auth hiccup) abort the install.
    await Promise.allSettled(PRECACHE.map(async (u) => {
      try {
        const r = await fetch(u, { cache: 'no-cache' });
        if (r && r.ok && !r.redirected) await cache.put(u, r);
      } catch (_) {}
    }));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;     // third-party: leave alone
  if (BYPASS.test(url.pathname)) return;           // live/auth paths: network only

  if (req.mode === 'navigate') {
    // Page loads (the shell + static app HTML): network-first with a short
    // timeout. This keeps Cloudflare Access working — an expired session
    // returns a redirect we pass straight through and never cache, so the
    // login page shows instead of a stale desktop — while still falling back
    // to the cached shell when the network STALLS (the iOS-Safari-on-flaky-
    // wifi case, where a request can hang 60-100s). Best of both.
    e.respondWith((async () => {
      const cache = await caches.open(CACHE);
      // Start the network fetch and let it update the cache WHENEVER it
      // resolves — even after we've already served the cached copy on timeout.
      // (Previously the fetch was abandoned on timeout, so a consistently-slow
      // connection would serve the same stale shell forever and never refresh.)
      const networkPromise = fetch(req).then((res) => {
        if (res && res.ok && res.type === 'basic' && !res.redirected) cache.put(req, res.clone());
        return res;
      });
      try {
        return await Promise.race([
          networkPromise,
          new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 2500))
        ]);
      } catch (_) {
        // Timed out (or errored): serve cache now; networkPromise keeps running
        // and refreshes the cache for next time.
        return (await cache.match(req)) || (await cache.match('/')) ||
               networkPromise.catch(() => Response.error());
      }
    })());
    return;
  }

  // Static sub-resources (JS/CSS/icons/manifest): cache-first, refresh in the
  // background (stale-while-revalidate). Only cache clean same-origin 200s.
  e.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req);
    const network = fetch(req).then((res) => {
      if (res && res.ok && res.type === 'basic' && !res.redirected) {
        cache.put(req, res.clone());
      }
      return res;
    }).catch(() => cached);
    return cached || network;
  })());
});
