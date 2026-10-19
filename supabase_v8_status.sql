-- يومي: التحديث الثامن — فحص حالة الإشعارات (للتشخيص)
-- شغّل هذا الملف مرة واحدة من: Supabase ← SQL Editor ← New query ← Run.
-- يعرض حالة الفحص الآلي كل دقيقة، وعدد الأجهزة المسجّلة، وأوقات مهام اليوم القادمة
-- لكل اشتراك، دون أي عناوين أو محتوى شخصي.

create or replace function public.yawmi_push_status()
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r json;
begin
  select json_build_object(
    'now_utc', now(),
    'cron_job', (select json_build_object('active', j.active, 'schedule', j.schedule) from cron.job j where j.jobname = 'yawmi-push'),
    'cron_last_runs', (
      select coalesce(json_agg(x order by x.start_time desc), '[]'::json) from (
        select d.start_time, d.status, left(d.return_message, 120) as message
        from cron.job_run_details d join cron.job j on j.jobid = d.jobid
        where j.jobname = 'yawmi-push' order by d.start_time desc limit 5
      ) x),
    'http_last_responses', (
      select coalesce(json_agg(y order by y.created desc), '[]'::json) from (
        select h.created, h.status_code, h.timed_out, left(coalesce(h.error_msg, h.content::text), 160) as info
        from net._http_response h order by h.created desc limit 5
      ) y),
    'subscriptions', (select count(*) from public.yawmi_push),
    'per_subscription', (
      select coalesce(json_agg(z), '[]'::json) from (
        select p.label, p.tz, p.lead_min,
               to_char((now() at time zone 'UTC') + make_interval(mins => p.tz), 'YYYY-MM-DD HH24:MI') as local_now,
               (select coalesce(json_agg(json_build_object('time', i->>'time', 'done', i->>'done', 'important', i->>'important', 'urgent', i->>'urgent') order by i->>'time'), '[]'::json)
                from unnest(array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3]) dd,
                     jsonb_array_elements(coalesce(dd->'items', '[]'::jsonb)) i
                where dd->>'date' = to_char((now() at time zone 'UTC') + make_interval(mins => p.tz), 'YYYY-MM-DD')
                  and coalesce(i->>'time', '') <> '') as today_timed_tasks,
               (select count(*) from unnest(array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3]) dd
                where dd->>'date' = to_char((now() at time zone 'UTC') + make_interval(mins => p.tz), 'YYYY-MM-DD')) as today_in_cloud,
               a.base_date
        from public.yawmi_push p join public.yawmi_accounts a on a.code = p.code
      ) z),
    'sent_last_hour', (select count(*) from public.yawmi_push_sent where at > now() - interval '1 hour')
  ) into r;
  return r;
end; $$;

revoke all on function public.yawmi_push_status() from public;
grant execute on function public.yawmi_push_status() to anon, authenticated;

notify pgrst, 'reload schema';
