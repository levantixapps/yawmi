// Offline support: the app shell is served network-first (so updates arrive),
// fonts and the Supabase library cache-first. Personal data never passes through here;
// it lives in the browser's localStorage.
var CACHE = "yawmi-v73";
var CORE = ["./", "index.html", "guide.html", "config.js", "manifest.webmanifest", "icon.svg", "icon-192.png", "icon-512.png"];

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
    // Network first, but a weak or dead connection can hang for a long time:
    // after 3 seconds the saved copy opens instead, and the fresh one is still stored when it arrives.
    var cached = function () { return caches.match(req).then(function (r) { return r || caches.match("index.html"); }); };
    e.respondWith(new Promise(function (resolve, reject) {
      var done = false, finish = function (r) { if (!done && r) { done = true; resolve(r); } };
      var timer = setTimeout(function () { cached().then(finish); }, 3000);
      fetch(req).then(function (res) { return store(req, res); }).then(function (res) { clearTimeout(timer); finish(res); }, function () {
        clearTimeout(timer);
        cached().then(function (r) { if (r) finish(r); else if (!done) { done = true; reject(new Error("offline")); } });
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
