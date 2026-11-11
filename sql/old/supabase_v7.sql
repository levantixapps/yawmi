-- يومي: التحديث السابع — الإشعارات لكل الحسابات على الجهاز نفسه
-- شغّل هذا الملف مرة واحدة بعد supabase_v6.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- قبل: كل جهاز مربوط بحساب واحد للإشعارات (آخر حساب فُعّلت فيه).
-- الآن: الجهاز الواحد يستقبل إشعارات كل حساباته (شخصي، العمل…)، وكل إشعار يبدأ باسم حسابه.

alter table public.yawmi_push add column if not exists label text;
alter table public.yawmi_push drop constraint if exists yawmi_push_pkey;
alter table public.yawmi_push add primary key (endpoint, code);

-- تسجيل الجهاز لحساب معيّن (مع اسم الحساب ليظهر في الإشعار)
create or replace function public.yawmi_push_save(p_key text, p_sub jsonb, p_tz int, p_lead int, p_label text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or coalesce(p_sub->>'endpoint', '') !~ '^https://' then return false; end if;
  insert into public.yawmi_push (endpoint, code, sub, tz, lead_min, label)
  values (p_sub->>'endpoint', c, p_sub, greatest(-720, least(840, coalesce(p_tz, 180))),
          greatest(0, least(60, coalesce(p_lead, 0))), left(nullif(trim(p_label), ''), 30))
  on conflict (endpoint, code) do update
    set sub = excluded.sub, tz = excluded.tz, lead_min = excluded.lead_min, label = excluded.label;
  -- the browser's keys are shared by all accounts on the device: keep them current everywhere
  update public.yawmi_push set sub = p_sub, tz = greatest(-720, least(840, coalesce(p_tz, 180)))
  where endpoint = p_sub->>'endpoint' and code <> c;
  return true;
end; $$;

-- النسخة القديمة (بلا اسم حساب) تبقى تعمل
create or replace function public.yawmi_push_save(p_key text, p_sub jsonb, p_tz int, p_lead int)
returns boolean language sql security definer set search_path = public as $$
  select public.yawmi_push_save(p_key, p_sub, p_tz, p_lead, null);
$$;

-- إيقاف الإشعارات لحساب واحد على الجهاز
create or replace function public.yawmi_push_unsub(p_key text, p_endpoint text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null then return false; end if;
  delete from public.yawmi_push where endpoint = p_endpoint and code = c;
  return found;
end; $$;

-- المهام التي حان موعدها، وكل عنوان يبدأ باسم الحساب إن وُجد
create or replace function public.yawmi_push_due()
returns table (endpoint text, sub jsonb, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  delete from public.yawmi_push_sent s0 where s0.at < now() - interval '2 days';
  return query
  with s as (
    select p.endpoint, p.sub, p.lead_min, p.label,
           (now() at time zone 'UTC') + make_interval(mins => p.tz) as lt,
           array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3] as days
    from public.yawmi_push p
    join public.yawmi_accounts a on a.code = p.code
  ), d as (
    select s.endpoint, s.sub, s.lead_min, s.label, s.lt, dd as day
    from s, unnest(s.days) dd
    where dd is not null and dd->>'date' = to_char(s.lt, 'YYYY-MM-DD')
  ), it as (
    select d.endpoint, d.sub, d.lead_min, d.label, d.lt, d.day->>'date' as dday, i
    from d, jsonb_array_elements(coalesce(d.day->'items', '[]'::jsonb)) i
    where coalesce(i->>'time', '') ~ '^\d{2}:\d{2}$'
      and coalesce(i->>'done', 'false') <> 'true'
      and coalesce(i->>'moved', 'false') <> 'true'
      and not (coalesce(i->>'important', '') = 'false' and coalesce(i->>'urgent', '') = 'false')
  ), due as (
    select it.*,
           split_part(it.i->>'time', ':', 1)::int * 60 + split_part(it.i->>'time', ':', 2)::int - it.lead_min as at_min,
           extract(hour from it.lt)::int * 60 + extract(minute from it.lt)::int as now_min
    from it
  ), pick as (
    select due.endpoint, due.sub,
           (case when due.label is not null then '[' || due.label || '] ' else '' end ||
            case when due.lead_min > 0 then 'بعد ' || due.lead_min || ' دقائق: ' else '⏰ حان الوقت: ' end ||
            coalesce(due.i->>'title', '')) as title,
           ('الساعة ' || (due.i->>'time')) as body,
           (due.dday || ':' || coalesce(due.i->>'id', '') || ':' || (due.i->>'time') || ':' || due.lead_min) as tag
    from due
    where due.now_min between due.at_min and due.at_min + 2
  ), ins as (
    insert into public.yawmi_push_sent (endpoint, tag)
    select pick.endpoint, pick.tag from pick
    on conflict do nothing
    returning yawmi_push_sent.endpoint, yawmi_push_sent.tag
  )
  select pick.endpoint, pick.sub, pick.title, pick.body, pick.tag
  from pick join ins on ins.endpoint = pick.endpoint and ins.tag = pick.tag;
end; $$;

revoke all on function public.yawmi_push_save(text, jsonb, int, int, text) from public;
revoke all on function public.yawmi_push_save(text, jsonb, int, int) from public;
revoke all on function public.yawmi_push_unsub(text, text) from public;
revoke all on function public.yawmi_push_due() from public, anon, authenticated;
grant execute on function public.yawmi_push_save(text, jsonb, int, int, text) to anon, authenticated;
grant execute on function public.yawmi_push_save(text, jsonb, int, int) to anon, authenticated;
grant execute on function public.yawmi_push_unsub(text, text) to anon, authenticated;
grant execute on function public.yawmi_push_due() to service_role;

-- إشعار تجريبي: يعيد اشتراك الجهاز إن كان مسجّلًا لهذا الحساب (تستدعيها دالة الإرسال فقط)
create or replace function public.yawmi_push_target(p_key text, p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text; n int; r jsonb;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null then return null; end if;
  select p.sub into r from public.yawmi_push p where p.endpoint = p_endpoint and p.code = c;
  return r;
end; $$;
revoke all on function public.yawmi_push_target(text, text) from public, anon, authenticated;
grant execute on function public.yawmi_push_target(text, text) to service_role;

notify pgrst, 'reload schema';
