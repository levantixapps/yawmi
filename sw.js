// Offline support: the app shell is served network-first (so updates arrive),
// fonts and the Supabase library cache-first. Personal data never passes through here;
// it lives in the browser's localStorage.
var CACHE = "yawmi-v6";
var CORE = ["./", "index.html", "config.js", "manifest.webmanifest", "icon.svg", "icon-192.png", "icon-512.png"];

self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(CORE); }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener("activate", function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (keys) { return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); })); })
      .then(function () { return self.clients.claim(); })
  );
});

function store(req, res) {
  if (res && (res.ok || res.type === "opaque")) {
    var copy = res.clone();
    caches.open(CACHE).then(function (c) { c.put(req, copy); });
  }
  return res;
}

self.addEventListener("fetch", function (e) {
  var req = e.request;
  if (req.method !== "GET") return;
  var url = new URL(req.url);

  if (url.origin === self.location.origin) {
    e.respondWith(
      fetch(req).then(function (res) { return store(req, res); }).catch(function () {
        return caches.match(req).then(function (r) { return r || caches.match("index.html"); });
      })
    );
    return;
  }

  if (/(^|\.)fonts\.(googleapis|gstatic)\.com$|^cdn\.jsdelivr\.net$|^cdnjs\.cloudflare\.com$/.test(url.hostname)) {
    e.respondWith(
      caches.match(req).then(function (r) {
        return r || fetch(req).then(function (res) { return store(req, res); });
      })
    );
  }
});
