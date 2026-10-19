// يومي: دالة الإرسال — تُستدعى كل دقيقة (من pg_cron)، فتجلب المهام التي حان موعدها
// من yawmi_push_due وترسل إشعارًا لكل جهاز مشترك.
//
// تحتاج هذه الأسرار في Supabase ← Edge Functions ← Secrets:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT
// أما SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY فيوفرهما Supabase تلقائيًا.

import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  "Content-Type": "application/json",
};

type Due = { endpoint: string; sub: webpush.PushSubscription; title: string; body: string; tag: string };

Deno.serve(async () => {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/yawmi_push_due`, { method: "POST", headers, body: "{}" });
  if (!res.ok) return new Response(await res.text(), { status: 500 });
  const rows: Due[] = await res.json();

  let sent = 0, gone = 0, failed = 0;
  await Promise.all(rows.map(async (row) => {
    try {
      await webpush.sendNotification(
        row.sub,
        JSON.stringify({ title: row.title, body: row.body, tag: row.tag }),
        { TTL: 600, urgency: "high" },
      );
      sent++;
    } catch (e) {
      const status = (e as { statusCode?: number }).statusCode;
      if (status === 404 || status === 410) {
        // the device unsubscribed or the app was removed: forget this subscription
        gone++;
        await fetch(`${SUPABASE_URL}/rest/v1/rpc/yawmi_push_delete`, {
          method: "POST", headers, body: JSON.stringify({ p_endpoint: row.endpoint }),
        });
      } else failed++;
    }
  }));

  return Response.json({ due: rows.length, sent, gone, failed });
});
