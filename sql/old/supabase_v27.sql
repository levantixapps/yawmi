-- يومي: التحديث السابع والعشرون — المشرف يختار «معلومة اليوم» لتاريخ معيّن
-- شغّل هذا الملف مرة واحدة بعد supabase_v26.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- المعلومة المثبّتة لتاريخ (on_date) تتقدّم في ذلك اليوم على المجدولة وعلى المعتادة. لكل تاريخ معلومة مثبّتة واحدة.

alter table public.yawmi_tips add column if not exists on_date date;

create or replace function public.yawmi_tip_pinned(p_day date)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('id', t.id, 'body', t.body, 'source', t.source, 'special', true)
  from public.yawmi_tips t where t.active and t.on_date = p_day order by t.updated_at desc limit 1;
$$;
revoke all on function public.yawmi_tip_pinned(date) from public, anon, authenticated;

-- المعلومة ليوم (v26) + المثبّتة أولًا
create or replace function public.yawmi_tip_for(p_day date, p_hm int, p_hd int)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json; dow int := extract(dow from p_day)::int; i int := p_day - date '2026-01-01';
begin
  r := public.yawmi_tip_pinned(p_day);
  if r is not null then return r; end if;
  select count(*) into c from public.yawmi_tips t where t.active
    and ((t.wdays is not null and dow = any(t.wdays)) or (t.hdays is not null and p_hd = any(t.hdays) and (t.hmonth is null or t.hmonth = p_hm)));
  if c > 0 then
    select json_build_object('id', t.id, 'body', t.body, 'source', t.source, 'special', true) into r
    from public.yawmi_tips t where t.active
      and ((t.wdays is not null and dow = any(t.wdays)) or (t.hdays is not null and p_hd = any(t.hdays) and (t.hmonth is null or t.hmonth = p_hm)))
    order by t.id offset ((i % c) + c) % c limit 1;
    return r;
  end if;
  return public.yawmi_tip_for(p_day);
end; $$;

-- المعتادة (v26) + المثبّتة أولًا (للتطبيق القديم وللوحة المشرف)
create or replace function public.yawmi_tip_for(p_day date)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json;
begin
  r := public.yawmi_tip_pinned(p_day);
  if r is not null then return r; end if;
  select count(*) into c from public.yawmi_tips where active and wdays is null and hdays is null;
  if c = 0 then return null; end if;
  select json_build_object('id', t.id, 'body', t.body, 'source', t.source) into r
  from public.yawmi_tips t where t.active and t.wdays is null and t.hdays is null
  order by t.id
  offset (((p_day - date '2026-01-01') % c) + c) % c
  limit 1;
  return r;
end; $$;

-- المشرف: تثبيت معلومة لتاريخ (p_id فارغ = إلغاء تثبيت ذلك التاريخ)
create or replace function public.yawmi_tip_pin(p_admin text, p_id int, p_day date)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) or p_day is null then return false; end if;
  update public.yawmi_tips set on_date = null where on_date = p_day;
  if p_id is not null then update public.yawmi_tips set on_date = p_day, active = true, updated_at = now() where id = p_id; end if;
  return true;
end; $$;

-- المشرف: كل المعلومات المفعّلة (ليختار منها)
create or replace function public.yawmi_admin_tips_all(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(json_build_object('id', t.id, 'body', t.body, 'source', t.source, 'on_date', t.on_date,
      'planned', t.wdays is not null or t.hdays is not null) order by t.id), '[]'::json)
    from public.yawmi_tips t where t.active);
end; $$;

revoke all on function public.yawmi_tip_pin(text, int, date) from public;
revoke all on function public.yawmi_admin_tips_all(text) from public;
grant execute on function public.yawmi_tip_pin(text, int, date) to anon, authenticated;
grant execute on function public.yawmi_admin_tips_all(text) to anon, authenticated;

notify pgrst, 'reload schema';
