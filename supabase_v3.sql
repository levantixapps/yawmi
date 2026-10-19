-- يومي: التحديث الثالث — أسماء المستخدمين وسجل التغييرات
-- شغّل هذا الملف مرة واحدة بعد supabase_v2.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- • كل جهاز ثانوي يحفظ اسم صاحبه، فيظهر للمسؤول الأول في قائمة الأجهزة.
-- • كل تغيير (إضافة، إنجاز، تعديل، حذف) يُسجَّل باسم من عمله ورقم جهازه.
-- • المسؤول الأول وحده يقرأ السجل، ويُحذف ما مضى عليه ١٤ يومًا.

alter table public.planner_devices add column if not exists uname text;

create table if not exists public.planner_log (
  id     bigserial primary key,
  code   text not null references public.planner(code) on delete cascade,
  num    int  not null,
  name   text,
  action text not null,
  title  text,
  day    date,
  at     timestamptz not null default now()
);
create index if not exists planner_log_code_at on public.planner_log (code, at desc);
alter table public.planner_log enable row level security;
revoke all on public.planner_log from anon, authenticated;

-- الجهاز الثانوي يحفظ اسم صاحبه
create or replace function public.planner_device_name(p_code text, p_name text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.planner_devices set uname = left(nullif(trim(p_name), ''), 40) where token = p_code;
  return found;
end;
$$;

-- أي جهاز مرتبط يضيف تغييراته إلى السجل (رقم الجهاز يُحدَّد من مفتاحه، لا مما يرسله)
create or replace function public.planner_log_add(p_code text, p_events jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  n int;
  e jsonb;
  k int := 0;
begin
  select r_code, r_num into c, n from public.planner_resolve(p_code);
  if c is null or jsonb_typeof(p_events) <> 'array' then return false; end if;
  for e in select value from jsonb_array_elements(p_events) loop
    k := k + 1;
    exit when k > 100;
    insert into public.planner_log (code, num, name, action, title, day, at)
    values (
      c, n,
      left(e->>'name', 40),
      left(coalesce(e->>'action', 'عدّل'), 30),
      left(e->>'title', 120),
      case when (e->>'day') ~ '^\d{4}-\d{2}-\d{2}$' then (e->>'day')::date end,
      case when (e->>'at') ~ '^\d{4}-\d{2}-\d{2}T' then least((e->>'at')::timestamptz, now()) else now() end
    );
  end loop;
  delete from public.planner_log where code = c and at < now() - interval '14 days';
  return true;
end;
$$;

-- المسؤول الأول: آخر ٢٠٠ تغيير
create or replace function public.planner_log_list(p_code text)
returns json
language sql
security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object('num', l.num, 'name', l.name, 'action', l.action, 'title', l.title, 'day', l.day, 'at', l.at) order by l.at desc), '[]'::json)
  from (
    select * from public.planner_log
    where code = p_code and exists (select 1 from public.planner where code = p_code)
    order by at desc limit 200
  ) l;
$$;

-- قائمة الأجهزة مع أسماء أصحابها
create or replace function public.planner_devices_list(p_code text)
returns json
language sql
security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object('token', d.token, 'num', d.num, 'label', d.label, 'uname', d.uname, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.num), '[]'::json)
  from public.planner_devices d
  where d.code = p_code and exists (select 1 from public.planner where code = p_code);
$$;

revoke all on function public.planner_device_name(text, text) from public;
revoke all on function public.planner_log_add(text, jsonb) from public;
revoke all on function public.planner_log_list(text) from public;
grant execute on function public.planner_device_name(text, text) to anon, authenticated;
grant execute on function public.planner_log_add(text, jsonb) to anon, authenticated;
grant execute on function public.planner_log_list(text) to anon, authenticated;
grant execute on function public.planner_devices_list(text) to anon, authenticated;
