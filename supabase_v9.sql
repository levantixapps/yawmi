-- يومي: التحديث التاسع — إدارة الحسابات والأجهزة + تنظيف تلقائي
-- شغّل هذا الملف مرة واحدة من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) تنظيف يومي تلقائي (الساعة 3 فجرًا بتوقيت UTC):
--    - الحساب الذي لم يُفتح منذ 30 يومًا يُحذف، ومعه أجهزته واشتراكات إشعاراته.
--      (فتح التطبيق في يوم جديد يحدّث الحساب تلقائيًا، فالمستخدم النشيط لا يُحذف أبدًا.)
--    - الجهاز الثانوي الذي لم يظهر منذ 30 يومًا يُفصل.
--    البيانات على أجهزة المستخدمين لا تتأثر، والسحابة للمشاركة والاسترجاع فقط.
-- ٢) الإشعارات بلا جدول سجل: لكل اشتراك عمود «أُرسل حتى» (sent_until)، ويُرسَل فقط ما وقع موعده
--    بين آخر فحص والآن (حتى 3 دقائق للخلف إن تأخر الفحص)، ثم يُحذف جدول yawmi_push_sent.
-- ٣) دوال للمشرف (تحتاج مفتاح المشرف) تعرض الإحصاءات والحسابات والأجهزة وتحذف ما تختاره.
--    لا تعرض أي كود حساب ولا أي محتوى: كل حساب يظهر برمز مختصر غير قابل للاستعمال.

-- مدة الخمول قبل الحذف (بالأيام)
create or replace function public.yawmi_idle_days() returns int language sql immutable as $$ select 30 $$;

-- ---------------------------------------------------------------------
-- التنظيف
create or replace function public.yawmi_cleanup()
returns json language plpgsql security definer set search_path = public as $$
declare a int; d int;
begin
  delete from public.yawmi_devices where last_seen < now() - make_interval(days => public.yawmi_idle_days());
  get diagnostics d = row_count;
  delete from public.yawmi_accounts where updated_at < now() - make_interval(days => public.yawmi_idle_days());
  get diagnostics a = row_count;
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  -- سجل تشغيل مهام cron: مهمة الإشعارات تضيف 1440 سطرًا كل يوم ولا يُحذف وحده أبدًا
  delete from cron.job_run_details where end_time < now() - interval '2 days';
  return json_build_object('accounts_deleted', a, 'devices_deleted', d);
end; $$;
revoke all on function public.yawmi_cleanup() from public, anon, authenticated;

select cron.unschedule('yawmi-cleanup') where exists (select 1 from cron.job where jobname = 'yawmi-cleanup');
select cron.schedule('yawmi-cleanup', '0 3 * * *', $cron$ select public.yawmi_cleanup(); $cron$);

-- ---------------------------------------------------------------------
-- رمز مختصر للحساب أو الجهاز (أول 10 أحرف من بصمته)، لا يفتح شيئًا
create or replace function public.yawmi_short(t text) returns text language sql immutable as $$
  select left(md5('yawmi:' || t), 10)
$$;

-- الإحصاءات
create or replace function public.yawmi_admin_stats(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return json_build_object(
    'accounts', (select count(*) from public.yawmi_accounts),
    'accounts_7', (select count(*) from public.yawmi_accounts where updated_at > now() - interval '7 days'),
    'accounts_30', (select count(*) from public.yawmi_accounts where updated_at > now() - interval '30 days'),
    'devices', (select count(*) from public.yawmi_devices),
    'devices_7', (select count(*) from public.yawmi_devices where last_seen > now() - interval '7 days'),
    'push', (select count(*) from public.yawmi_push),
    'db_bytes', pg_database_size(current_database()),
    'data_bytes', (select coalesce(sum(pg_column_size(a.*)), 0) from public.yawmi_accounts a),
    'idle_days', public.yawmi_idle_days()
  );
end; $$;

-- الحسابات: الأحدث نشاطًا أولًا
create or replace function public.yawmi_admin_accounts(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.updated_at desc), '[]'::json) from (
    select public.yawmi_short(a.code) as id, a.created_at, a.updated_at,
           pg_column_size(a.*) as bytes,
           (select count(*) from public.yawmi_devices d where d.code = a.code) as devices,
           (select max(d.last_seen) from public.yawmi_devices d where d.code = a.code) as devices_seen,
           (select count(*) from public.yawmi_push p where p.code = a.code) as push
    from public.yawmi_accounts a) x);
end; $$;

-- أجهزة حساب معيّن
create or replace function public.yawmi_admin_devices(p_admin text, p_id text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.num), '[]'::json) from (
    select public.yawmi_short(d.token) as id, d.num, d.label, d.created_at, d.last_seen
    from public.yawmi_devices d join public.yawmi_accounts a on a.code = d.code
    where public.yawmi_short(a.code) = p_id) x);
end; $$;

-- حذف حساب (ومعه أجهزته واشتراكاته) أو جهاز
create or replace function public.yawmi_admin_delete(p_admin text, p_kind text, p_id text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) or coalesce(p_id, '') = '' then return false; end if;
  if p_kind = 'account' then
    delete from public.yawmi_accounts where public.yawmi_short(code) = p_id;
  elsif p_kind = 'device' then
    delete from public.yawmi_devices where public.yawmi_short(token) = p_id;
  else
    return false;
  end if;
  return found;
end; $$;

revoke all on function public.yawmi_admin_stats(text) from public;
revoke all on function public.yawmi_admin_accounts(text) from public;
revoke all on function public.yawmi_admin_devices(text, text) from public;
revoke all on function public.yawmi_admin_delete(text, text, text) from public;
grant execute on function public.yawmi_admin_stats(text) to anon, authenticated;
grant execute on function public.yawmi_admin_accounts(text) to anon, authenticated;
grant execute on function public.yawmi_admin_devices(text, text) to anon, authenticated;
grant execute on function public.yawmi_admin_delete(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- الإشعارات: «أُرسل حتى» بدل جدول السجل
alter table public.yawmi_push add column if not exists sent_until timestamptz;

create or replace function public.yawmi_push_due()
returns table (endpoint text, sub jsonb, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_now timestamptz := now();
begin
  -- القفل يمنع فحصين متزامنين من إرسال الإشعار نفسه مرتين
  perform 1 from public.yawmi_push for update;
  return query
  with s as (
    select p.endpoint, p.sub, p.lead_min, p.label,
           (v_now at time zone 'UTC') + make_interval(mins => p.tz) as t1,
           (greatest(coalesce(p.sent_until, v_now - interval '1 minute'), v_now - interval '3 minutes') at time zone 'UTC') + make_interval(mins => p.tz) as t0,
           array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3] as days
    from public.yawmi_push p
    join public.yawmi_accounts a on a.code = p.code
  ), it as (
    select s.endpoint, s.sub, s.lead_min, s.label, s.t0, s.t1, dd->>'date' as dday, i
    from s, unnest(s.days) dd, jsonb_array_elements(coalesce(dd->'items', '[]'::jsonb)) i
    where dd is not null and dd->>'date' in (to_char(s.t0, 'YYYY-MM-DD'), to_char(s.t1, 'YYYY-MM-DD'))
      and coalesce(i->>'time', '') ~ '^\d{2}:\d{2}$'
      and coalesce(i->>'done', 'false') <> 'true'
      and coalesce(i->>'moved', 'false') <> 'true'
      and not (coalesce(i->>'important', '') = 'false' and coalesce(i->>'urgent', '') = 'false')
  ), due as (
    select it.*, ((it.dday || ' ' || (it.i->>'time'))::timestamp - make_interval(mins => it.lead_min)) as at_ts
    from it
  )
  select due.endpoint, due.sub,
         (case when due.label is not null then '[' || due.label || '] ' else '' end ||
          case when due.lead_min > 0 then 'بعد ' || due.lead_min || ' دقائق: ' else '⏰ حان الوقت: ' end ||
          coalesce(due.i->>'title', '')) as title,
         ('الساعة ' || (due.i->>'time')) as body,
         (due.dday || ':' || coalesce(due.i->>'id', '') || ':' || (due.i->>'time') || ':' || due.lead_min) as tag
  from due
  where due.at_ts > due.t0 and due.at_ts <= due.t1;
  update public.yawmi_push set sent_until = v_now where true; -- Supabase يرفض التحديث بلا شرط
end; $$;
revoke all on function public.yawmi_push_due() from public, anon, authenticated;
grant execute on function public.yawmi_push_due() to service_role;

-- دالة التشخيص (من v8) بعد إزالة جدول السجل
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
      select coalesce(json_agg(json_build_object('label', p.label, 'tz', p.tz, 'lead_min', p.lead_min, 'sent_until', p.sent_until)), '[]'::json)
      from public.yawmi_push p)
  ) into r;
  return r;
end; $$;
revoke all on function public.yawmi_push_status() from public;
grant execute on function public.yawmi_push_status() to anon, authenticated;

drop table if exists public.yawmi_push_sent;

notify pgrst, 'reload schema';

-- للتأكد: يعرض ما سيُحذف لو جرى التنظيف الآن (لا يحذف شيئًا)
select
  (select count(*) from cron.job_run_details) as "أسطر سجل الجدولة الآن",
  pg_size_pretty(pg_total_relation_size('cron.job_run_details')) as "حجمه",
  (select count(*) from public.yawmi_accounts where updated_at < now() - interval '30 days') as "حسابات خاملة ستُحذف",
  (select count(*) from public.yawmi_devices where last_seen < now() - interval '30 days') as "أجهزة خاملة ستُفصل";
