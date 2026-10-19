-- يومي: التحديث الرابع — أسماء الجداول باسم المشروع + أسماء المستخدمين وسجل التغييرات
-- شغّل هذا الملف مرة واحدة بعد supabase_v2.sql من: Supabase ← SQL Editor ← New query ← Run.
-- (يغني عن supabase_v3.sql، فلا تحتاج تشغيله.)
--
-- الأسماء الجديدة:
--   planner          → yawmi_accounts       (صف لكل حساب، فيه الأيام السبعة والإعدادات)
--   planner_devices  → yawmi_devices        (الأجهزة الثانوية المرتبطة)
--   planner_pair     → yawmi_link_requests  (طلبات الربط المؤقتة)
--   planner_log      → yawmi_log            (سجل التغييرات)
--   الدوال planner_* → yawmi_*
-- البيانات تبقى كما هي؛ تتغير الأسماء فقط.

-- ---------- 1) إعادة تسمية الجداول (إن وُجدت بالأسماء القديمة) ----------
do $$
begin
  if to_regclass('public.planner') is not null and to_regclass('public.yawmi_accounts') is null then
    alter table public.planner rename to yawmi_accounts;
  end if;
  if to_regclass('public.planner_devices') is not null and to_regclass('public.yawmi_devices') is null then
    alter table public.planner_devices rename to yawmi_devices;
  end if;
  if to_regclass('public.planner_pair') is not null and to_regclass('public.yawmi_link_requests') is null then
    alter table public.planner_pair rename to yawmi_link_requests;
  end if;
  if to_regclass('public.planner_log') is not null and to_regclass('public.yawmi_log') is null then
    alter table public.planner_log rename to yawmi_log;
  end if;
end $$;

-- ---------- 2) الجداول (تُنشأ إن لم تكن موجودة) ----------
create table if not exists public.yawmi_accounts (
  code       text primary key,
  base_date  date not null default current_date,
  day_m3 jsonb, day_m2 jsonb, day_m1 jsonb, day_0 jsonb, day_p1 jsonb, day_p2 jsonb, day_p3 jsonb,
  settings   jsonb,
  chan       text default replace(gen_random_uuid()::text, '-', ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.yawmi_accounts add column if not exists chan text;
update public.yawmi_accounts set chan = replace(gen_random_uuid()::text, '-', '') where chan is null;
alter table public.yawmi_accounts alter column chan set default replace(gen_random_uuid()::text, '-', '');

create table if not exists public.yawmi_devices (
  token      text primary key,
  code       text not null references public.yawmi_accounts(code) on delete cascade,
  num        int  not null,
  label      text,
  uname      text,
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
alter table public.yawmi_devices add column if not exists uname text;

create table if not exists public.yawmi_link_requests (
  token      text primary key,
  code       text references public.yawmi_accounts(code) on delete cascade,
  kind       text not null default 'scan',
  created_at timestamptz not null default now()
);
alter table public.yawmi_link_requests add column if not exists kind text not null default 'scan';

create table if not exists public.yawmi_log (
  id     bigserial primary key,
  code   text not null references public.yawmi_accounts(code) on delete cascade,
  num    int  not null,
  name   text,
  action text not null,
  title  text,
  day    date,
  at     timestamptz not null default now()
);
create index if not exists yawmi_log_code_at on public.yawmi_log (code, at desc);

-- كل الجداول مغلقة؛ الوصول فقط عبر الدوال أدناه
alter table public.yawmi_accounts      enable row level security;
alter table public.yawmi_devices       enable row level security;
alter table public.yawmi_link_requests enable row level security;
alter table public.yawmi_log           enable row level security;
revoke all on public.yawmi_accounts, public.yawmi_devices, public.yawmi_link_requests, public.yawmi_log from anon, authenticated;

-- ---------- 3) حذف الدوال القديمة ----------
drop function if exists public.planner_create();
drop function if exists public.planner_get(text);
drop function if exists public.planner_save(text, jsonb);
drop function if exists public.planner_pair_start();
drop function if exists public.planner_pair_approve(text, text);
drop function if exists public.planner_pair_take(text);
drop function if exists public.planner_pair_take(text, text);
drop function if exists public.planner_rand(int);
drop function if exists public.planner_resolve(text);
drop function if exists public.planner_add_device(text, text);
drop function if exists public.planner_invite(text);
drop function if exists public.planner_join(text, text);
drop function if exists public.planner_devices_list(text);
drop function if exists public.planner_device_revoke(text, text);
drop function if exists public.planner_device_name(text, text);
drop function if exists public.planner_log_add(text, jsonb);
drop function if exists public.planner_log_list(text);

-- ---------- 4) الدوال الداخلية ----------
create or replace function public.yawmi_rand(n int)
returns text language plpgsql set search_path = public as $$
declare
  alphabet text := 'abcdefghjkmnpqrstuvwxyz23456789';
  b bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  t text := '';
  i int;
begin
  for i in 0..n - 1 loop
    t := t || substr(alphabet, 1 + (get_byte(b, i) % length(alphabet)), 1);
  end loop;
  return t;
end; $$;

-- المفتاح (كود رئيسي أو رقم جهاز) ← الحساب ورقم الجهاز (1 = المسؤول الأول)
create or replace function public.yawmi_resolve(p_key text, out r_code text, out r_num int)
language plpgsql security definer set search_path = public as $$
begin
  select code, 1 into r_code, r_num from public.yawmi_accounts where code = p_key;
  if r_code is not null then return; end if;
  update public.yawmi_devices set last_seen = now() where token = p_key
  returning code, num into r_code, r_num;
end; $$;

create or replace function public.yawmi_add_device(p_code text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare t text; n int;
begin
  loop
    t := 'd' || public.yawmi_rand(23);
    exit when not exists (select 1 from public.yawmi_devices where token = t);
  end loop;
  select coalesce(max(num), 1) + 1 into n from public.yawmi_devices where code = p_code;
  insert into public.yawmi_devices (token, code, num, label) values (t, p_code, n, left(coalesce(p_label, ''), 40));
  return json_build_object('token', t, 'num', n);
end; $$;

-- ---------- 5) الدوال العامة ----------
-- حساب جديد: يعيد الكود الرئيسي
create or replace function public.yawmi_create()
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  loop
    c := public.yawmi_rand(12);
    exit when not exists (select 1 from public.yawmi_accounts where code = c);
  end loop;
  insert into public.yawmi_accounts (code) values (c);
  return c;
end; $$;

create or replace function public.yawmi_get(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int; r json;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_code);
  if c is null then return null; end if;
  select json_build_object(
    'base_date', a.base_date,
    'day_m3', a.day_m3, 'day_m2', a.day_m2, 'day_m1', a.day_m1, 'day_0', a.day_0,
    'day_p1', a.day_p1, 'day_p2', a.day_p2, 'day_p3', a.day_p3,
    'settings', a.settings, 'chan', a.chan,
    'role', case when n = 1 then 'primary' else 'secondary' end,
    'num', n
  ) into r from public.yawmi_accounts a where a.code = c;
  return r;
end; $$;

create or replace function public.yawmi_save(p_code text, p_data jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_code);
  if c is null then return false; end if;
  update public.yawmi_accounts set
    base_date  = coalesce((p_data->>'base_date')::date, base_date),
    day_m3 = p_data->'day_m3', day_m2 = p_data->'day_m2', day_m1 = p_data->'day_m1', day_0 = p_data->'day_0',
    day_p1 = p_data->'day_p1', day_p2 = p_data->'day_p2', day_p3 = p_data->'day_p3',
    settings   = coalesce(p_data->'settings', settings),
    updated_at = now()
  where code = c;
  return found;
end; $$;

-- المسؤول الأول ينشئ رمز ربط (٨ أحرف، ١٠ دقائق، مرة واحدة)
create or replace function public.yawmi_invite(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if not exists (select 1 from public.yawmi_accounts where code = p_code) then return null; end if;
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  loop
    t := public.yawmi_rand(8);
    exit when not exists (select 1 from public.yawmi_link_requests where token = t);
  end loop;
  insert into public.yawmi_link_requests (token, code, kind) values (t, p_code, 'invite');
  return t;
end; $$;

create or replace function public.yawmi_join(p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  delete from public.yawmi_link_requests
  where token = p_token and kind = 'invite' and code is not null and created_at > now() - interval '10 minutes'
  returning code into c;
  if c is null then return null; end if;
  return public.yawmi_add_device(c, p_label);
end; $$;

-- الجهاز الجديد يعرض QR، والمسؤول الأول يمسحه
create or replace function public.yawmi_pair_start()
returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  loop
    t := public.yawmi_rand(16);
    exit when not exists (select 1 from public.yawmi_link_requests where token = t);
  end loop;
  insert into public.yawmi_link_requests (token, kind) values (t, 'scan');
  return t;
end; $$;

create or replace function public.yawmi_pair_approve(p_token text, p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.yawmi_accounts where code = p_code) then return false; end if;
  update public.yawmi_link_requests set code = p_code
  where token = p_token and kind = 'scan' and code is null and created_at > now() - interval '10 minutes';
  return found;
end; $$;

create or replace function public.yawmi_pair_take(p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  delete from public.yawmi_link_requests where token = p_token and kind = 'scan' and code is not null
  returning code into c;
  if c is null then return null; end if;
  return public.yawmi_add_device(c, p_label);
end; $$;

-- المسؤول الأول: الأجهزة، وإلغاء الربط
create or replace function public.yawmi_devices_list(p_code text)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('token', d.token, 'num', d.num, 'label', d.label, 'uname', d.uname, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.num), '[]'::json)
  from public.yawmi_devices d
  where d.code = p_code and exists (select 1 from public.yawmi_accounts where code = p_code);
$$;

create or replace function public.yawmi_device_revoke(p_code text, p_token text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from public.yawmi_devices where code = p_code and token = p_token;
  return found;
end; $$;

-- الجهاز الثانوي يحفظ اسم صاحبه
create or replace function public.yawmi_device_name(p_code text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.yawmi_devices set uname = left(nullif(trim(p_name), ''), 40) where token = p_code;
  return found;
end; $$;

-- سجل التغييرات: أي جهاز يضيف، والمسؤول الأول يقرأ (يُحذف ما مضى عليه ١٤ يومًا)
create or replace function public.yawmi_log_add(p_code text, p_events jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; e jsonb; k int := 0;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_code);
  if c is null or jsonb_typeof(p_events) <> 'array' then return false; end if;
  for e in select value from jsonb_array_elements(p_events) loop
    k := k + 1;
    exit when k > 100;
    insert into public.yawmi_log (code, num, name, action, title, day, at)
    values (
      c, n,
      left(e->>'name', 40),
      left(coalesce(e->>'action', 'عدّل'), 30),
      left(e->>'title', 120),
      case when (e->>'day') ~ '^\d{4}-\d{2}-\d{2}$' then (e->>'day')::date end,
      case when (e->>'at') ~ '^\d{4}-\d{2}-\d{2}T' then least((e->>'at')::timestamptz, now()) else now() end
    );
  end loop;
  delete from public.yawmi_log where code = c and at < now() - interval '14 days';
  return true;
end; $$;

create or replace function public.yawmi_log_list(p_code text)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('num', l.num, 'name', l.name, 'action', l.action, 'title', l.title, 'day', l.day, 'at', l.at) order by l.at desc), '[]'::json)
  from (
    select * from public.yawmi_log
    where code = p_code and exists (select 1 from public.yawmi_accounts where code = p_code)
    order by at desc limit 200
  ) l;
$$;

-- ---------- 6) الصلاحيات ----------
revoke all on function public.yawmi_rand(int) from public, anon, authenticated;
revoke all on function public.yawmi_resolve(text) from public, anon, authenticated;
revoke all on function public.yawmi_add_device(text, text) from public, anon, authenticated;
revoke all on function public.yawmi_create() from public;
revoke all on function public.yawmi_get(text) from public;
revoke all on function public.yawmi_save(text, jsonb) from public;
revoke all on function public.yawmi_invite(text) from public;
revoke all on function public.yawmi_join(text, text) from public;
revoke all on function public.yawmi_pair_start() from public;
revoke all on function public.yawmi_pair_approve(text, text) from public;
revoke all on function public.yawmi_pair_take(text, text) from public;
revoke all on function public.yawmi_devices_list(text) from public;
revoke all on function public.yawmi_device_revoke(text, text) from public;
revoke all on function public.yawmi_device_name(text, text) from public;
revoke all on function public.yawmi_log_add(text, jsonb) from public;
revoke all on function public.yawmi_log_list(text) from public;
grant execute on function public.yawmi_create() to anon, authenticated;
grant execute on function public.yawmi_get(text) to anon, authenticated;
grant execute on function public.yawmi_save(text, jsonb) to anon, authenticated;
grant execute on function public.yawmi_invite(text) to anon, authenticated;
grant execute on function public.yawmi_join(text, text) to anon, authenticated;
grant execute on function public.yawmi_pair_start() to anon, authenticated;
grant execute on function public.yawmi_pair_approve(text, text) to anon, authenticated;
grant execute on function public.yawmi_pair_take(text, text) to anon, authenticated;
grant execute on function public.yawmi_devices_list(text) to anon, authenticated;
grant execute on function public.yawmi_device_revoke(text, text) to anon, authenticated;
grant execute on function public.yawmi_device_name(text, text) to anon, authenticated;
grant execute on function public.yawmi_log_add(text, jsonb) to anon, authenticated;
grant execute on function public.yawmi_log_list(text) to anon, authenticated;

-- تحديث ذاكرة واجهة Supabase حتى تظهر الدوال الجديدة فورًا
notify pgrst, 'reload schema';
