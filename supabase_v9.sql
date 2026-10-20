-- يومي: التحديث التاسع — إدارة الحسابات والأجهزة + تنظيف تلقائي
-- شغّل هذا الملف مرة واحدة من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) تنظيف يومي تلقائي (الساعة 3 فجرًا بتوقيت UTC):
--    - الحساب الذي لم يُفتح منذ 30 يومًا يُحذف، ومعه أجهزته واشتراكات إشعاراته.
--      (فتح التطبيق في يوم جديد يحدّث الحساب تلقائيًا، فالمستخدم النشيط لا يُحذف أبدًا.)
--    - الجهاز الثانوي الذي لم يظهر منذ 30 يومًا يُفصل.
--    البيانات على أجهزة المستخدمين لا تتأثر، والسحابة للمشاركة والاسترجاع فقط.
-- ٢) دوال للمشرف (تحتاج مفتاح المشرف) تعرض الإحصاءات والحسابات والأجهزة وتحذف ما تختاره.
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
  delete from public.yawmi_push_sent where at < now() - interval '2 days';
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

notify pgrst, 'reload schema';

-- للتأكد: يعرض ما سيُحذف لو جرى التنظيف الآن (لا يحذف شيئًا)
select
  (select count(*) from public.yawmi_accounts where updated_at < now() - interval '30 days') as "حسابات خاملة ستُحذف",
  (select count(*) from public.yawmi_devices where last_seen < now() - interval '30 days') as "أجهزة خاملة ستُفصل";
