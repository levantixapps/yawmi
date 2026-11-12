// Offline support: the app shell is served network-first (so updates arrive),
// fonts and the Supabase library cache-first. Personal data never passes through here;
// it lives in the browser's localStorage.
var CACHE = "yawmi-v125";
var CORE = ["./", "index.html", "guide.html", "alarm.html", "config.js", "manifest.webmanifest", "icon.svg", "icon-192.png", "icon-512.png"];

// Each file is stored on its own, so one failed file does not leave the app without its copy. Only the page itself is
// required: without it this version is not installed, and the previous one (with its copy) stays.
self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) {
    return Promise.all(CORE.map(function (u) { return c.add(new Request(u, { cache: "reload" })).catch(function () {}); }))
      .then(function () { return c.match("index.html"); })
      .then(function (r) { if (!r) throw new Error("index.html not stored"); });
  }).then(function () { return self.skipWaiting(); }));
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
    // Network first, but a weak or dead connection can hang for a long time:
    // after 3 seconds the saved copy opens instead, and the fresh one is still stored when it arrives.
    // The Android app opens the page with ?native=…&nv=…: the saved copy is found whatever follows "?"
    var page = req.mode === "navigate";
    var cached = function () {
      return caches.match(req, { ignoreSearch: true }).then(function (r) {
        if (r || !page) return r;
        return caches.match("index.html", { ignoreSearch: true }).then(function (x) { return x || caches.match("./", { ignoreSearch: true }); });
      });
    };
    e.respondWith(new Promise(function (resolve, reject) {
      var done = false, finish = function (r) { if (!done && r) { done = true; resolve(r); } };
      var timer = setTimeout(function () { cached().then(finish); }, 3000);
      // "no-cache" asks the server every time (a quick "not modified" when nothing changed), so an update isn't held
      // back by the browser's own 10-minute copy. A page load (navigate) can't take options, so it is fetched by its address.
      var fresh;
      try { fresh = req.mode === "navigate" ? fetch(req.url, { cache: "no-cache", credentials: "same-origin" }) : fetch(req, { cache: "no-cache" }); }
      catch (err) { fresh = fetch(req); }
      fresh.then(function (res) { return store(req, res); }).then(function (res) { clearTimeout(timer); finish(res); }, function () {
        clearTimeout(timer);
        cached().then(function (r) {
          if (r) finish(r);
          else if (page) finish(offlinePage()); // never the browser's error page
          else if (!done) { done = true; reject(new Error("offline")); }
        });
      });
    }));
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

// Only when no copy was ever saved on this device (opened for the first time without internet)
function offlinePage() {
  return new Response('<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>يومي</title><body style="font-family:system-ui,sans-serif;text-align:center;padding:48px 20px;color:#1f2a24;background:#f6f4ee">' +
    '<h1 style="font-size:1.4rem">«يومي» يحتاج الإنترنت مرة واحدة</h1><p>افتحه مرة والإنترنت متصل، فيُحفظ على جهازك ويعمل بعدها دون إنترنت.</p>' +
    '<p><button onclick="location.reload()" style="font-size:1rem;padding:10px 22px;border-radius:10px;border:0;background:#2f7d5b;color:#fff">حاول من جديد</button></p></body></html>',
    { headers: { "Content-Type": "text/html; charset=utf-8" } });
}

// Notifications sent by the yawmi-push function, even when the app is closed
self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: e.data ? e.data.text() : "يومي" }; }
  e.waitUntil(self.registration.showNotification(d.title || "يومي", {
    body: d.body || "", tag: d.tag || "yawmi", icon: "icon-192.png", badge: "icon-192.png", lang: "ar", dir: "rtl", renotify: true
  }));
});
// A task's tag is "<date>:<id>:<time>:<lead>": open that task in the app
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var m = /^(\d{4}-\d{2}-\d{2}):([^:]+):/.exec(e.notification.tag || ""), task = m ? m[1] + ":" + m[2] : "";
  var flow = /^flow:/.test(e.notification.tag || ""); // a transaction reached this person: open the transactions tab
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) {
      if ("focus" in list[i]) { if (task) list[i].postMessage({ task: task }); if (flow) list[i].postMessage({ flows: 1 }); return list[i].focus(); }
    }
    return self.clients.openWindow("./" + (task ? "#task=" + encodeURIComponent(task).replace("%3A", ":") : flow ? "#flows" : ""));
  }));
});
