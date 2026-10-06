// Service worker: שומר את קבצי האפליקציה כדי שתיפתח מהר וגם בלי חיבור.
// הנתונים עצמם נשמרים ב-Supabase ולא כאן.
const CACHE = "baby-shell-v1";
const SHELL = ["./", "index.html", "config.js", "manifest.webmanifest", "vendor/supabase.js", "icon-192.png", "icon-512.png", "apple-touch-icon.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return; // בקשות ל-Supabase ולפונטים עוברות ישר לרשת
  // רשת קודם (כדי שעדכונים יגיעו), ואם אין חיבור אז מהמטמון
  e.respondWith(
    fetch(req).then(res => {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match(req).then(r => r || caches.match("index.html")))
  );
});
