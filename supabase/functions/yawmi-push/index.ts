// @ts-nocheck — Deno (Supabase Edge) runtime; editor type checks for Node do not apply
// يومي: دالة الإرسال — تُستدعى كل دقيقة (من pg_cron)، فتجلب المهام التي حان موعدها
// من yawmi_push_due وترسل إشعارًا لكل جهاز مشترك.
//
// تحتاج هذه الأسرار في Supabase ← Edge Functions ← Secrets:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT
// أما SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY فيوفرهما Supabase تلقائيًا.
//
// Web Push without libraries (the npm web-push package exceeds the free plan's compute):
// message encryption per RFC 8291 (aes128gcm, RFC 8188) and VAPID per RFC 8292, using WebCrypto.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";

const enc = new TextEncoder();

function fromB64u(s: string): Uint8Array {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const raw = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
function toB64u(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}
async function hkdf(salt: Uint8Array, ikm: Uint8Array, info: Uint8Array, bytes: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, bytes * 8));
}

// ---- VAPID: an ES256-signed JWT per push service origin, reused for 12 hours ----
let signingKey: CryptoKey | null = null;
const jwtCache = new Map<string, { jwt: string; exp: number }>();
async function vapidAuth(endpoint: string): Promise<string> {
  const aud = new URL(endpoint).origin;
  const now = Math.floor(Date.now() / 1000);
  const hit = jwtCache.get(aud);
  if (hit && hit.exp - now > 3600) return `vapid t=${hit.jwt}, k=${VAPID_PUBLIC}`;
  if (!signingKey) {
    const pub = fromB64u(VAPID_PUBLIC);
    signingKey = await crypto.subtle.importKey("jwk", {
      kty: "EC", crv: "P-256", x: toB64u(pub.slice(1, 33)), y: toB64u(pub.slice(33, 65)), d: VAPID_PRIVATE, ext: true,
    }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  }
  const exp = now + 12 * 3600;
  const head = toB64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = toB64u(enc.encode(JSON.stringify({ aud, exp, sub: VAPID_SUBJECT })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingKey, enc.encode(`${head}.${body}`)));
  const jwt = `${head}.${body}.${toB64u(sig)}`;
  jwtCache.set(aud, { jwt, exp });
  return `vapid t=${jwt}, k=${VAPID_PUBLIC}`;
}

// ---- RFC 8291: encrypt the payload for one subscription ----
type Sub = { endpoint: string; keys: { p256dh: string; auth: string } };
export async function encrypt(sub: Sub, payload: string): Promise<Uint8Array> {
  const uaPublic = fromB64u(sub.keys.p256dh);
  const authSecret = fromB64u(sub.keys.auth);
  const local = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]) as CryptoKeyPair;
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", local.publicKey));
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, local.privateKey, 256));

  const ikm = await hkdf(authSecret, ecdh, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);

  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const plain = concat(enc.encode(payload), new Uint8Array([2])); // 0x02: last (and only) record
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, tagLength: 128 }, aes, plain));

  const rs = new Uint8Array([0, 0, 16, 0]); // record size 4096
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}

async function sendPush(sub: Sub, payload: string): Promise<number> {
  const res = await fetch(sub.endpoint, {
    method: "POST",
    headers: {
      Authorization: await vapidAuth(sub.endpoint),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      TTL: "600",
      Urgency: "high",
    },
    body: await encrypt(sub, payload),
  });
  await res.body?.cancel();
  return res.status;
}

const headers = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" };
type Due = { endpoint: string; sub: Sub; title: string; body: string; tag: string };

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let input: { test?: boolean; key?: string; endpoint?: string } = {};
  try { input = await req.json(); } catch { /* the minute job sends {} */ }

  // Test button in the app: send one notification to this device right away
  if (input.test) {
    const t = await fetch(`${SUPABASE_URL}/rest/v1/rpc/yawmi_push_target`, {
      method: "POST", headers, body: JSON.stringify({ p_key: input.key ?? "", p_endpoint: input.endpoint ?? "" }),
    });
    const sub = t.ok ? await t.json() : null;
    if (!sub) return Response.json({ ok: false, reason: t.ok ? "not_registered" : "db_" + t.status }, { headers: CORS });
    try {
      const status = await sendPush(sub, JSON.stringify({ title: "🔔 تجربة من «يومي»", body: "الإشعارات تعمل على هذا الجهاز ✓", tag: "test-" + Date.now() }));
      return Response.json({ ok: status >= 200 && status < 300, reason: "push_" + status }, { headers: CORS });
    } catch (e) {
      return Response.json({ ok: false, reason: "error: " + String(e) }, { headers: CORS });
    }
  }

  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/yawmi_push_due`, { method: "POST", headers, body: "{}" });
  if (!res.ok) return new Response(await res.text(), { status: 500 });
  const rows: Due[] = await res.json();

  let sent = 0, gone = 0, failed = 0;
  await Promise.all(rows.map(async (row) => {
    try {
      const status = await sendPush(row.sub, JSON.stringify({ title: row.title, body: row.body, tag: row.tag }));
      if (status >= 200 && status < 300) sent++;
      else if (status === 404 || status === 410) {
        // the device unsubscribed or the app was removed: forget this subscription
        gone++;
        await fetch(`${SUPABASE_URL}/rest/v1/rpc/yawmi_push_delete`, {
          method: "POST", headers, body: JSON.stringify({ p_endpoint: row.endpoint }),
        });
      } else failed++;
    } catch {
      failed++;
    }
  }));

  return Response.json({ due: rows.length, sent, gone, failed });
});
