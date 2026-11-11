-- «يومي»: قاعدة البيانات كاملة لمشروع Supabase جديد.
-- الصق هذا الملف كله في SQL Editor ثم اضغط Run مرة واحدة.
-- هو الملفات القديمة (sql/old) بترتيب تشغيلها نفسه، ملصقة كما هي دون تعديل.
-- لا تشغّله على المشروع الحالي: كل ما فيه مُشغَّل هناك من قبل.
-- في آخره يظهر «مفتاح المشرف»: احفظه.


-- ════════════════ supabase.sql ════════════════

-- دفتر يومي: جدول Supabase
-- صف واحد لكل مستخدم، يُفتح بكود يولّده Supabase.
-- سبعة حقول للأيام: day_m3 و day_m2 و day_m1 (الأيام الثلاثة السابقة)، day_0 (اليوم)،
-- day_p1 و day_p2 و day_p3 (الأيام الثلاثة اللاحقة). base_date هو التاريخ الذي يقابل day_0.
-- شغّل هذا الملف كاملًا مرة واحدة من: Supabase ← SQL Editor ← New query ← Run.

create table if not exists public.planner (
  code       text primary key,
  base_date  date not null default current_date,
  day_m3     jsonb,
  day_m2     jsonb,
  day_m1     jsonb,
  day_0      jsonb,
  day_p1     jsonb,
  day_p2     jsonb,
  day_p3     jsonb,
  settings   jsonb,            -- التقسيمات والمهام الدائمة
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- الجدول مغلق أمام القراءة والكتابة المباشرة؛ الوصول فقط عبر الدوال الثلاث أدناه،
-- ولا يصل أحد إلى صف إلا إذا عرف كوده.
alter table public.planner enable row level security;
revoke all on public.planner from anon, authenticated;

-- ينشئ صفًا جديدًا ويعيد كوده (12 حرفًا ورقمًا، بلا أحرف متشابهة)
create or replace function public.planner_create()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  alphabet text := 'abcdefghjkmnpqrstuvwxyz23456789';
  b bytea;
  c text;
  i int;
begin
  loop
    b := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
    c := '';
    for i in 0..11 loop
      c := c || substr(alphabet, 1 + (get_byte(b, i * 2 + 1) % length(alphabet)), 1);
    end loop;
    exit when not exists (select 1 from public.planner where code = c);
  end loop;
  insert into public.planner (code) values (c);
  return c;
end;
$$;

-- يعيد صف الكود، أو null إن لم يوجد
create or replace function public.planner_get(p_code text)
returns json
language sql
security definer
set search_path = public
as $$
  select row_to_json(p) from public.planner p where p.code = p_code;
$$;

-- يحفظ الحقول السبعة والإعدادات دفعة واحدة، ويعيد false إن لم يوجد الكود
create or replace function public.planner_save(p_code text, p_data jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.planner set
    base_date  = coalesce((p_data->>'base_date')::date, base_date),
    day_m3     = p_data->'day_m3',
    day_m2     = p_data->'day_m2',
    day_m1     = p_data->'day_m1',
    day_0      = p_data->'day_0',
    day_p1     = p_data->'day_p1',
    day_p2     = p_data->'day_p2',
    day_p3     = p_data->'day_p3',
    settings   = coalesce(p_data->'settings', settings),
    updated_at = now()
  where code = p_code;
  return found;
end;
$$;

revoke all on function public.planner_create() from public;
revoke all on function public.planner_get(text) from public;
revoke all on function public.planner_save(text, jsonb) from public;
grant execute on function public.planner_create() to anon, authenticated;
grant execute on function public.planner_get(text) to anon, authenticated;
grant execute on function public.planner_save(text, jsonb) to anon, authenticated;

-- ============================================================
-- الربط برمز QR (مثل واتساب): الجهاز الجديد يعرض رمزًا، والجوال الذي عليه
-- البيانات يمسحه فيسلّمه الكود. الطلب صالح ١٠ دقائق ثم يُحذف.
create table if not exists public.planner_pair (
  token      text primary key,
  code       text references public.planner(code) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.planner_pair enable row level security;
revoke all on public.planner_pair from anon, authenticated;

create or replace function public.planner_pair_start()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  alphabet text := 'abcdefghjkmnpqrstuvwxyz23456789';
  b bytea := uuid_send(gen_random_uuid()) || uuid_send(gen_random_uuid());
  t text := '';
  i int;
begin
  delete from public.planner_pair where created_at < now() - interval '10 minutes';
  for i in 0..15 loop
    t := t || substr(alphabet, 1 + (get_byte(b, i * 2 + 1) % length(alphabet)), 1);
  end loop;
  insert into public.planner_pair (token) values (t);
  return t;
end;
$$;

create or replace function public.planner_pair_approve(p_token text, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.planner where code = p_code) then
    return false;
  end if;
  update public.planner_pair set code = p_code
  where token = p_token and code is null and created_at > now() - interval '10 minutes';
  return found;
end;
$$;

create or replace function public.planner_pair_take(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare c text;
begin
  delete from public.planner_pair where token = p_token and code is not null returning code into c;
  return c;
end;
$$;

revoke all on function public.planner_pair_start() from public;
revoke all on function public.planner_pair_approve(text, text) from public;
revoke all on function public.planner_pair_take(text) from public;
grant execute on function public.planner_pair_start() to anon, authenticated;
grant execute on function public.planner_pair_approve(text, text) to anon, authenticated;
grant execute on function public.planner_pair_take(text) to anon, authenticated;


-- ════════════════ supabase_v2.sql ════════════════

-- يومي: التحديث الثاني — المسؤول الأول والأجهزة الثانوية
-- شغّل هذا الملف مرة واحدة بعد supabase.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- الفكرة:
-- • الكود الرئيسي (planner.code) يملكه المسؤول الأول فقط.
-- • كل جهاز يُربط بعده يحصل على رقم ثانوي خاص به (planner_devices.token) ولا يعرف الكود الرئيسي.
-- • الربط يكون برمز ربط مؤقت يُنشئه المسؤول الأول (يُكتب أو يُمسح QR)، أو بمسح QR يعرضه الجهاز الجديد.
-- • المسؤول الأول يرى الأجهزة ويلغي ربط أي منها.

-- قناة التنبيه الفوري لكل صف (بدل استعمال الكود في اسم القناة)
alter table public.planner add column if not exists chan text;
update public.planner set chan = replace(gen_random_uuid()::text, '-', '') where chan is null;
alter table public.planner alter column chan set default replace(gen_random_uuid()::text, '-', '');

-- الأجهزة الثانوية
create table if not exists public.planner_devices (
  token      text primary key,
  code       text not null references public.planner(code) on delete cascade,
  num        int  not null,
  label      text,
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
alter table public.planner_devices enable row level security;
revoke all on public.planner_devices from anon, authenticated;

-- نوع طلب الربط: scan = الجهاز الجديد يعرض QR والمسؤول يمسحه، invite = المسؤول يعطي رمز ربط
alter table public.planner_pair add column if not exists kind text not null default 'scan';

-- رمز عشوائي بلا أحرف متشابهة
create or replace function public.planner_rand(n int)
returns text
language plpgsql
set search_path = public
as $$
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
end;
$$;

-- يحوّل المفتاح (كود رئيسي أو رقم جهاز ثانوي) إلى الصف ورقم الجهاز (1 = المسؤول الأول)
create or replace function public.planner_resolve(p_key text, out r_code text, out r_num int)
language plpgsql
security definer
set search_path = public
as $$
begin
  select code, 1 into r_code, r_num from public.planner where code = p_key;
  if r_code is not null then return; end if;
  update public.planner_devices set last_seen = now() where token = p_key
  returning code, num into r_code, r_num;
end;
$$;

-- ينشئ جهازًا ثانويًا جديدًا ويعيد رقمه ومفتاحه
create or replace function public.planner_add_device(p_code text, p_label text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  t text;
  n int;
begin
  loop
    t := 'd' || public.planner_rand(23);
    exit when not exists (select 1 from public.planner_devices where token = t);
  end loop;
  select coalesce(max(num), 1) + 1 into n from public.planner_devices where code = p_code;
  insert into public.planner_devices (token, code, num, label) values (t, p_code, n, left(coalesce(p_label, ''), 40));
  return json_build_object('token', t, 'num', n);
end;
$$;

-- يعيد بيانات الصف للمفتاح (بدون الكود الرئيسي)، أو null إن لم يوجد أو أُلغي ربط الجهاز
create or replace function public.planner_get(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  n int;
  r json;
begin
  select r_code, r_num into c, n from public.planner_resolve(p_code);
  if c is null then return null; end if;
  select json_build_object(
    'base_date', p.base_date,
    'day_m3', p.day_m3, 'day_m2', p.day_m2, 'day_m1', p.day_m1, 'day_0', p.day_0,
    'day_p1', p.day_p1, 'day_p2', p.day_p2, 'day_p3', p.day_p3,
    'settings', p.settings, 'chan', p.chan,
    'role', case when n = 1 then 'primary' else 'secondary' end,
    'num', n
  ) into r from public.planner p where p.code = c;
  return r;
end;
$$;

-- يحفظ الحقول السبعة والإعدادات (يقبل الكود الرئيسي أو رقم جهاز ثانوي)
create or replace function public.planner_save(p_code text, p_data jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  n int;
begin
  select r_code, r_num into c, n from public.planner_resolve(p_code);
  if c is null then return false; end if;
  update public.planner set
    base_date  = coalesce((p_data->>'base_date')::date, base_date),
    day_m3     = p_data->'day_m3',
    day_m2     = p_data->'day_m2',
    day_m1     = p_data->'day_m1',
    day_0      = p_data->'day_0',
    day_p1     = p_data->'day_p1',
    day_p2     = p_data->'day_p2',
    day_p3     = p_data->'day_p3',
    settings   = coalesce(p_data->'settings', settings),
    updated_at = now()
  where code = c;
  return found;
end;
$$;

-- المسؤول الأول ينشئ رمز ربط مؤقتًا (١٠ دقائق) يكتبه الجهاز الجديد أو يمسحه
create or replace function public.planner_invite(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare t text;
begin
  if not exists (select 1 from public.planner where code = p_code) then return null; end if;
  delete from public.planner_pair where created_at < now() - interval '10 minutes';
  loop
    t := public.planner_rand(8);
    exit when not exists (select 1 from public.planner_pair where token = t);
  end loop;
  insert into public.planner_pair (token, code, kind) values (t, p_code, 'invite');
  return t;
end;
$$;

-- الجهاز الجديد يستعمل رمز الربط فيحصل على رقمه الثانوي
create or replace function public.planner_join(p_token text, p_label text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare c text;
begin
  delete from public.planner_pair
  where token = p_token and kind = 'invite' and code is not null and created_at > now() - interval '10 minutes'
  returning code into c;
  if c is null then return null; end if;
  return public.planner_add_device(c, p_label);
end;
$$;

-- الجهاز الجديد يعرض QR: الموافقة لا تكون إلا من المسؤول الأول (بالكود الرئيسي)
create or replace function public.planner_pair_approve(p_token text, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.planner where code = p_code) then
    return false;
  end if;
  update public.planner_pair set code = p_code
  where token = p_token and kind = 'scan' and code is null and created_at > now() - interval '10 minutes';
  return found;
end;
$$;

-- الجهاز الجديد يستلم رقمه الثانوي بعد موافقة المسؤول الأول
drop function if exists public.planner_pair_take(text);
create or replace function public.planner_pair_take(p_token text, p_label text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare c text;
begin
  delete from public.planner_pair where token = p_token and kind = 'scan' and code is not null
  returning code into c;
  if c is null then return null; end if;
  return public.planner_add_device(c, p_label);
end;
$$;

-- المسؤول الأول: قائمة الأجهزة الثانوية
create or replace function public.planner_devices_list(p_code text)
returns json
language sql
security definer
set search_path = public
as $$
  select coalesce(json_agg(json_build_object('token', d.token, 'num', d.num, 'label', d.label, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.num), '[]'::json)
  from public.planner_devices d
  where d.code = p_code and exists (select 1 from public.planner where code = p_code);
$$;

-- المسؤول الأول: إلغاء ربط جهاز
create or replace function public.planner_device_revoke(p_code text, p_token text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.planner_devices where code = p_code and token = p_token;
  return found;
end;
$$;

-- الصلاحيات: الدوال الداخلية مغلقة، والدوال العامة متاحة للتطبيق
revoke all on function public.planner_rand(int) from public, anon, authenticated;
revoke all on function public.planner_resolve(text) from public, anon, authenticated;
revoke all on function public.planner_add_device(text, text) from public, anon, authenticated;
revoke all on function public.planner_get(text) from public;
revoke all on function public.planner_save(text, jsonb) from public;
revoke all on function public.planner_invite(text) from public;
revoke all on function public.planner_join(text, text) from public;
revoke all on function public.planner_pair_approve(text, text) from public;
revoke all on function public.planner_pair_take(text, text) from public;
revoke all on function public.planner_devices_list(text) from public;
revoke all on function public.planner_device_revoke(text, text) from public;
grant execute on function public.planner_get(text) to anon, authenticated;
grant execute on function public.planner_save(text, jsonb) to anon, authenticated;
grant execute on function public.planner_invite(text) to anon, authenticated;
grant execute on function public.planner_join(text, text) to anon, authenticated;
grant execute on function public.planner_pair_approve(text, text) to anon, authenticated;
grant execute on function public.planner_pair_take(text, text) to anon, authenticated;
grant execute on function public.planner_devices_list(text) to anon, authenticated;
grant execute on function public.planner_device_revoke(text, text) to anon, authenticated;


-- ════════════════ supabase_v4.sql ════════════════

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


-- ════════════════ supabase_v5.sql ════════════════

-- يومي: التحديث الخامس — سجل التغييرات في خانة واحدة لكل مستخدم ثانوي
-- شغّل هذا الملف مرة واحدة بعد supabase_v4.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- • يُحذف جدول yawmi_log.
-- • لكل جهاز ثانوي خانة واحدة (yawmi_devices.changes) تُضاف إليها تغييراته سطرًا تحت سطر،
--   مثل: «19/10 08:42 — حذف «دراسة جغرافية» (ليوم 19/10)». للاطلاع فقط.
-- • تحتفظ الخانة بآخر ٣٠٠ سطر، والأقدم يُحذف تلقائيًا.

alter table public.yawmi_devices add column if not exists changes text;

drop function if exists public.yawmi_log_list(text);
drop table if exists public.yawmi_log;

-- يضيف سطور التغييرات إلى خانة الجهاز الثانوي (تغييرات المسؤول الأول لا تُسجَّل)
create or replace function public.yawmi_log_add(p_code text, p_events jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  lines text[] := '{}';
  e jsonb;
  k int := 0;
  cur text[];
begin
  if not exists (select 1 from public.yawmi_devices where token = p_code) then
    return exists (select 1 from public.yawmi_accounts where code = p_code);
  end if;
  if jsonb_typeof(p_events) <> 'array' then return false; end if;
  for e in select value from jsonb_array_elements(p_events) loop
    k := k + 1;
    exit when k > 100;
    if jsonb_typeof(e) = 'string' then
      lines := lines || left(replace(e #>> '{}', E'\n', ' '), 200);
    elsif jsonb_typeof(e) = 'object' then
      lines := lines || left(trim(coalesce(e->>'action', '') || ' «' || coalesce(e->>'title', '') || '»'), 200);
    end if;
  end loop;
  select coalesce(string_to_array(nullif(changes, ''), E'\n'), '{}') into cur from public.yawmi_devices where token = p_code;
  cur := cur || lines;
  if array_length(cur, 1) > 300 then
    cur := cur[array_length(cur, 1) - 299 : array_length(cur, 1)];
  end if;
  update public.yawmi_devices set changes = array_to_string(cur, E'\n') where token = p_code;
  return true;
end; $$;

-- قائمة الأجهزة مع اسم صاحب كل جهاز وخانة تغييراته
create or replace function public.yawmi_devices_list(p_code text)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('token', d.token, 'num', d.num, 'label', d.label, 'uname', d.uname, 'changes', d.changes, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.num), '[]'::json)
  from public.yawmi_devices d
  where d.code = p_code and exists (select 1 from public.yawmi_accounts where code = p_code);
$$;

revoke all on function public.yawmi_log_add(text, jsonb) from public;
grant execute on function public.yawmi_log_add(text, jsonb) to anon, authenticated;
grant execute on function public.yawmi_devices_list(text) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v6.sql ════════════════

-- يومي: التحديث السادس — إشعارات حتى والتطبيق مغلق + معلومة اليوم
-- شغّل هذا الملف مرة واحدة بعد supabase_v5.sql من: Supabase ← SQL Editor ← New query ← Run.
-- في آخر التشغيل يظهر «مفتاح المشرف»: احفظه، فبه تعدّل معلومة اليوم من داخل التطبيق.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- =====================================================================
-- 1) الإشعارات (Web Push)
-- =====================================================================
-- اشتراك كل جهاز في الإشعارات، مربوط بحسابه
create table if not exists public.yawmi_push (
  endpoint   text primary key,
  code       text not null references public.yawmi_accounts(code) on delete cascade,
  sub        jsonb not null,
  tz         int  not null default 180,  -- فرق التوقيت عن UTC بالدقائق
  lead_min   int  not null default 0,    -- التنبيه قبل الموعد بكم دقيقة
  created_at timestamptz not null default now()
);
-- ما أُرسل، حتى لا يتكرر الإشعار (يُحذف بعد يومين)
create table if not exists public.yawmi_push_sent (
  endpoint text not null,
  tag      text not null,
  at       timestamptz not null default now(),
  primary key (endpoint, tag)
);
alter table public.yawmi_push      enable row level security;
alter table public.yawmi_push_sent enable row level security;
revoke all on public.yawmi_push, public.yawmi_push_sent from anon, authenticated;

-- الجهاز يسجّل اشتراكه (بمفتاحه: الكود الرئيسي أو رقمه الثانوي)
create or replace function public.yawmi_push_save(p_key text, p_sub jsonb, p_tz int, p_lead int)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or coalesce(p_sub->>'endpoint', '') !~ '^https://' then return false; end if;
  insert into public.yawmi_push (endpoint, code, sub, tz, lead_min)
  values (p_sub->>'endpoint', c, p_sub, greatest(-720, least(840, coalesce(p_tz, 180))), greatest(0, least(60, coalesce(p_lead, 0))))
  on conflict (endpoint) do update
    set code = excluded.code, sub = excluded.sub, tz = excluded.tz, lead_min = excluded.lead_min;
  return true;
end; $$;

create or replace function public.yawmi_push_delete(p_endpoint text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from public.yawmi_push where endpoint = p_endpoint;
  return found;
end; $$;

-- المهام التي حان موعدها الآن لكل مشترك (تستدعيها دالة الإرسال فقط)
create or replace function public.yawmi_push_due()
returns table (endpoint text, sub jsonb, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  delete from public.yawmi_push_sent s0 where s0.at < now() - interval '2 days';
  return query
  with s as (
    select p.endpoint, p.sub, p.lead_min,
           (now() at time zone 'UTC') + make_interval(mins => p.tz) as lt,
           array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3] as days
    from public.yawmi_push p
    join public.yawmi_accounts a on a.code = p.code
  ), d as (
    select s.endpoint, s.sub, s.lead_min, s.lt, dd as day
    from s, unnest(s.days) dd
    where dd is not null and dd->>'date' = to_char(s.lt, 'YYYY-MM-DD')
  ), it as (
    select d.endpoint, d.sub, d.lead_min, d.lt, d.day->>'date' as dday, i
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
           (case when due.lead_min > 0 then 'بعد ' || due.lead_min || ' دقائق: ' else '⏰ حان الوقت: ' end || coalesce(due.i->>'title', '')) as title,
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

revoke all on function public.yawmi_push_save(text, jsonb, int, int) from public;
revoke all on function public.yawmi_push_delete(text) from public;
revoke all on function public.yawmi_push_due() from public, anon, authenticated;
grant execute on function public.yawmi_push_save(text, jsonb, int, int) to anon, authenticated;
grant execute on function public.yawmi_push_delete(text) to anon, authenticated;
grant execute on function public.yawmi_push_due() to service_role;

-- فحص كل دقيقة: يستدعي دالة الإرسال yawmi-push
do $$
begin
  if exists (select 1 from cron.job where jobname = 'yawmi-push') then
    perform cron.unschedule('yawmi-push');
  end if;
end $$;
select cron.schedule('yawmi-push', '* * * * *', $cron$
  select net.http_post(
    url := 'https://nkcngzsjevgzurwxkjqn.supabase.co/functions/v1/yawmi-push',
    headers := '{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5rY25nenNqZXZnenVyd3hranFuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU3NTQyMTEsImV4cCI6MjEwMTMzMDIxMX0.2UlqfEPT-TCBGnIfHqn1sArX1AOkhRr6zvnQt4evD0U"}'::jsonb,
    body := '{}'::jsonb
  );
$cron$);

-- =====================================================================
-- 2) معلومة اليوم (يراها كل مستخدمي التطبيق، ويعدّلها المشرف)
-- =====================================================================
create table if not exists public.yawmi_tips (
  id         serial primary key,
  body       text not null,
  source     text,
  active     boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.yawmi_admin (key text primary key);
alter table public.yawmi_tips  enable row level security;
alter table public.yawmi_admin enable row level security;
revoke all on public.yawmi_tips, public.yawmi_admin from anon, authenticated;

insert into public.yawmi_admin (key)
select public.yawmi_rand(16) where not exists (select 1 from public.yawmi_admin);

-- معلومة يوم معيّن: تدور على المعلومات المفعّلة بالترتيب، يومًا بعد يوم
create or replace function public.yawmi_tip_for(p_day date)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json;
begin
  select count(*) into c from public.yawmi_tips where active;
  if c = 0 then return null; end if;
  select json_build_object('id', t.id, 'body', t.body, 'source', t.source) into r
  from public.yawmi_tips t where t.active
  order by t.id
  offset (((p_day - date '2026-01-01') % c) + c) % c
  limit 1;
  return r;
end; $$;

create or replace function public.yawmi_admin_check(p_admin text)
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from public.yawmi_admin where key = p_admin);
$$;

-- المشرف: إضافة معلومة (p_id فارغ) أو تعديلها
create or replace function public.yawmi_tip_save(p_admin text, p_id int, p_body text, p_source text)
returns json language plpgsql security definer set search_path = public as $$
declare r public.yawmi_tips;
begin
  if not public.yawmi_admin_check(p_admin) or coalesce(trim(p_body), '') = '' then return null; end if;
  if p_id is null then
    insert into public.yawmi_tips (body, source) values (left(trim(p_body), 600), left(nullif(trim(p_source), ''), 120)) returning * into r;
  else
    update public.yawmi_tips set body = left(trim(p_body), 600), source = left(nullif(trim(p_source), ''), 120), updated_at = now()
    where id = p_id returning * into r;
  end if;
  return json_build_object('id', r.id, 'body', r.body, 'source', r.source);
end; $$;

-- المشرف: إيقاف معلومة (لا تُحذف، فلا يختل ترتيب الأيام إلا بقدرها)
create or replace function public.yawmi_tip_hide(p_admin text, p_id int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_tips set active = false, updated_at = now() where id = p_id;
  return found;
end; $$;

revoke all on function public.yawmi_tip_for(date) from public;
revoke all on function public.yawmi_admin_check(text) from public;
revoke all on function public.yawmi_tip_save(text, int, text, text) from public;
revoke all on function public.yawmi_tip_hide(text, int) from public;
grant execute on function public.yawmi_tip_for(date) to anon, authenticated;
grant execute on function public.yawmi_admin_check(text) to anon, authenticated;
grant execute on function public.yawmi_tip_save(text, int, text, text) to anon, authenticated;
grant execute on function public.yawmi_tip_hide(text, int) to anon, authenticated;

-- معلومات أولية (تُضاف مرة واحدة فقط إن كان الجدول فارغًا)
insert into public.yawmi_tips (body, source)
select v.body, v.source from (values
  ('«نعمتان مغبون فيهما كثير من الناس: الصحة والفراغ».', 'صحيح البخاري'),
  ('«اللهم بارك لأمتي في بكورها». أفضل ساعات العمل والحفظ هي ساعات الصباح الأولى.', 'سنن أبي داود والترمذي'),
  ('«أحب الأعمال إلى الله أدومها وإن قل». صفحة يوميًا خير من عشر صفحات مرة في الأسبوع.', 'صحيح البخاري ومسلم'),
  ('﴿وَالْعَصْرِ ۝ إِنَّ الْإِنسَانَ لَفِي خُسْرٍ﴾. أقسم الله بالوقت لعظيم قيمته.', 'سورة العصر'),
  ('﴿فَإِذَا فَرَغْتَ فَانصَبْ﴾: إذا انتهيت من عمل فابدأ بالذي بعده.', 'سورة الشرح، الآية ٧'),
  ('«احرص على ما ينفعك، واستعن بالله، ولا تعجز».', 'صحيح مسلم'),
  ('«إن الله يحب إذا عمل أحدكم عملًا أن يتقنه».', 'رواه الطبراني والبيهقي، وحسّنه الألباني'),
  ('ابدأ يومك بأصعب مهمة وأهمها، قبل أن تستهلك الرسائل والاجتماعات طاقتك.', 'نصيحة في إدارة الوقت'),
  ('قاعدة الدقيقتين: إن كانت المهمة تأخذ أقل من دقيقتين، فافعلها الآن ولا تؤجلها.', 'نصيحة في إدارة الوقت'),
  ('العمل ٢٥ دقيقة بتركيز كامل ثم راحة ٥ دقائق يحافظ على نشاط ذهنك طوال اليوم.', 'طريقة بومودورو'),
  ('المهام المهمة غير العاجلة هي التي تبني مستقبلك، فخصّص لها وقتًا ثابتًا كل يوم.', 'مصفوفة أيزنهاور'),
  ('العمل يتمدد ليملأ الوقت المتاح له. ضع لكل مهمة وقتًا محددًا تنتهي فيه.', 'قانون باركنسون'),
  ('التنقل بين المهام يهدر جزءًا كبيرًا من تركيزك. أنجز مهمة واحدة ثم انتقل للتالية.', 'نصيحة في التركيز'),
  ('ضع الجوال بعيدًا عنك وقت الدراسة؛ مجرد وجوده أمامك يشتت الانتباه.', 'نصيحة في التركيز'),
  ('يحتاج البالغ عادة من ٧ إلى ٩ ساعات نوم. قلة النوم تضعف الحفظ والتركيز.', 'معلومة صحية'),
  ('النوم المبكر بعد العشاء يعطيك صباحًا مباركًا دون أن تنقص من حاجة جسمك للنوم.', 'نصيحة في النوم'),
  ('القيلولة القصيرة (١٠ إلى ٣٠ دقيقة) بعد الظهر تجدد النشاط وتحسن التركيز.', 'معلومة صحية'),
  ('اشرب الماء بانتظام؛ نقص الماء ولو قليلًا يسبب التعب وضعف التركيز.', 'معلومة صحية'),
  ('المشي ٢٠ دقيقة يوميًا يحسّن المزاج والذاكرة ويقوي القلب.', 'معلومة صحية'),
  ('راجع ما حفظته في اليوم التالي، ثم بعد أسبوع، ثم بعد شهر؛ فالمراجعة المتباعدة تثبّت الحفظ.', 'التكرار المتباعد'),
  ('اشرح ما درسته لغيرك أو لنفسك بصوت مسموع؛ الشرح من أقوى طرق الفهم.', 'نصيحة في الدراسة'),
  ('اختبر نفسك بأسئلة بدل إعادة القراءة فقط؛ الاسترجاع يثبّت المعلومة أكثر.', 'نصيحة في الدراسة'),
  ('اكتب أهم ٣ مهام لليوم قبل أن تنام، فتستيقظ وأنت تعرف من أين تبدأ.', 'نصيحة في التخطيط'),
  ('قسّم المهمة الكبيرة إلى خطوات صغيرة، وابدأ بأول خطوة الآن.', 'نصيحة في الإنجاز'),
  ('اترك ١٠ دقائق راحة بين المهام؛ الجدول المضغوط بلا فراغات ينهار عند أول تأخير.', 'نصيحة في التخطيط'),
  ('راجع يومك مساءً: ما الذي نجح؟ وما الذي ستحسّنه غدًا؟ دقيقتان تصنعان فرقًا كبيرًا.', 'نصيحة في المراجعة'),
  ('الإنجاز الصغير المتكرر يبني العادة؛ ابدأ بخمس دقائق يوميًا ثم زِد.', 'نصيحة في بناء العادات'),
  ('اربط العادة الجديدة بعادة ثابتة، مثل قراءة صفحة من القرآن بعد صلاة الفجر مباشرة.', 'نصيحة في بناء العادات'),
  ('قول «لا» لما لا يهم هو ما يعطيك الوقت لقول «نعم» لما يهم.', 'نصيحة في إدارة الوقت'),
  ('حدد وقتين في اليوم لقراءة الرسائل بدل فتحها كل بضع دقائق.', 'نصيحة في التركيز'),
  ('رتّب مكان عملك قبل أن تبدأ؛ المكان المرتب يساعد على التركيز.', 'نصيحة في الإنجاز'),
  ('أوقات الصلاة محطات طبيعية لتقسيم يومك: خطط لما بين كل صلاتين.', 'نصيحة في التخطيط'),
  ('كافئ نفسك بعد إنجاز المهمة الصعبة؛ المكافأة الصغيرة تشجعك على الاستمرار.', 'نصيحة في التحفيز'),
  ('لا تنتظر الحماس لتبدأ؛ ابدأ، فيأتي الحماس بعد البداية.', 'نصيحة في التحفيز'),
  ('اكتب ما يشغل بالك على ورقة أو في «أفرغ ذهنك»؛ تفريغ الذهن يخفف التوتر.', 'نصيحة في التخطيط'),
  ('«بادروا بالأعمال».', 'صحيح مسلم'),
  ('الوقت أنفس ما عُني بحفظه، وأراه أسهل ما عليك يضيع.', 'من الحكمة العربية'),
  ('الإفراط في التخطيط دون تنفيذ نوع من التسويف؛ خطّط بقدر، ثم ابدأ.', 'نصيحة في الإنجاز'),
  ('الصباح الهادئ يبدأ من ليلة منظمة: جهّز ملابسك وأدواتك قبل النوم.', 'نصيحة في التخطيط'),
  ('قِس تقدمك أسبوعيًا لا يوميًا؛ الأيام تتفاوت، والاتجاه العام هو المهم.', 'نصيحة في المتابعة')
) as v(body, source)
where not exists (select 1 from public.yawmi_tips);

notify pgrst, 'reload schema';

-- مفتاح المشرف: انسخه واحفظه (به تعدّل معلومة اليوم من داخل التطبيق ← ⚙ ← وضع المشرف)
select key as "مفتاح المشرف — احفظه" from public.yawmi_admin;


-- ════════════════ supabase_v7.sql ════════════════

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


-- ════════════════ supabase_v8_status.sql ════════════════

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


-- ════════════════ supabase_v9.sql ════════════════

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


-- ════════════════ supabase_v10.sql ════════════════

-- يومي: التحديث العاشر — الفرق: المشرف يربط الأشخاص (مسؤول وتابعون)
-- شغّل هذا الملف مرة واحدة بعد supabase_v9.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) كل حساب يحفظ اسم صاحبه ونوع جهازه (مثل HUAWEI P30)، فيراهما المشرف في لوحة الإدارة.
-- ٢) المشرف يختار مسؤولًا وتابعًا ويضغط «ربط»:
--    - يُنشأ للمسؤول (أول مرة فقط) حساب فريق مستقل عن حسابه الشخصي، ويصل إلى جهازه تلقائيًا باسم «فريقي».
--    - يُضاف التابع جهازًا ثانويًا في حساب الفريق، ويصله تلقائيًا باسم «فريق <اسم المسؤول>».
--    - الحساب الشخصي لكلٍّ منهما يبقى كما هو. والتابع يمكن أن يكون مسؤولًا عن فريقه الخاص.
-- ٣) فك الربط يحذف جهاز التابع من حساب الفريق. وحذف حساب المسؤول يحذف فريقه معه.
-- ٤) التنظيف اليومي لا يحذف حساب مسؤول ما دام فريقه نشيطًا.

alter table public.yawmi_accounts add column if not exists uname text;
alter table public.yawmi_accounts add column if not exists label text;
-- حساب الفريق: مسؤوله، وهل وصل كوده إلى جهاز المسؤول
alter table public.yawmi_accounts add column if not exists team_leader text references public.yawmi_accounts(code) on delete cascade;
alter table public.yawmi_accounts add column if not exists team_taken boolean not null default false;
-- (كان هنا فهرس «فريق واحد لكل مسؤول»، وأُلغي في v11 حيث صار للمسؤول أكثر من فريق)

-- التابعون: كل تابع له جهاز ثانوي في حساب الفريق، ويصل مفتاحه إلى جهازه مرة واحدة
create table if not exists public.yawmi_team_members (
  team       text not null references public.yawmi_accounts(code) on delete cascade,
  member     text not null references public.yawmi_accounts(code) on delete cascade,
  token      text not null references public.yawmi_devices(token) on delete cascade,
  taken      boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (team, member)
);
alter table public.yawmi_team_members enable row level security;
revoke all on public.yawmi_team_members from anon, authenticated;

-- ---------------------------------------------------------------------
-- الجهاز يحفظ اسم صاحبه ونوعه (المسؤول الأول في صف الحساب، والثانوي في صف جهازه)
create or replace function public.yawmi_whoami(p_key text, p_name text, p_label text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; nm text := left(nullif(trim(p_name), ''), 40); lb text := left(nullif(trim(p_label), ''), 40);
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null then return false; end if;
  if n = 1 then
    update public.yawmi_accounts set uname = coalesce(nm, uname), label = coalesce(lb, label) where code = c;
  else
    update public.yawmi_devices set uname = coalesce(nm, uname), label = coalesce(lb, label) where token = p_key;
  end if;
  return true;
end; $$;

-- ما ينتظر هذا الشخص من حسابات فرق (يسأل عنه جهازه المسؤول عن حسابه الشخصي)
create or replace function public.yawmi_team_inbox(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return '[]'::json; end if;
  return (select coalesce(json_agg(x), '[]'::json) from (
    select 'lead' as kind, t.code as key, 1 as num, l.uname as leader, public.yawmi_short(t.code) as team
    from public.yawmi_accounts t join public.yawmi_accounts l on l.code = t.team_leader
    where t.team_leader = c and not t.team_taken
    union all
    select 'member', m.token, d.num, l.uname, public.yawmi_short(m.team)
    from public.yawmi_team_members m
    join public.yawmi_devices d on d.token = m.token
    join public.yawmi_accounts t on t.code = m.team
    join public.yawmi_accounts l on l.code = t.team_leader
    where m.member = c and not m.taken) x);
end; $$;

-- الجهاز يؤكد أنه أضاف حساب الفريق، فلا يُرسل إليه ثانية
create or replace function public.yawmi_team_ack(p_key text, p_team text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return false; end if;
  update public.yawmi_accounts set team_taken = true where team_leader = c and public.yawmi_short(code) = p_team;
  update public.yawmi_team_members set taken = true where member = c and public.yawmi_short(team) = p_team;
  return true;
end; $$;

revoke all on function public.yawmi_whoami(text, text, text) from public;
revoke all on function public.yawmi_team_inbox(text) from public;
revoke all on function public.yawmi_team_ack(text, text) from public;
grant execute on function public.yawmi_whoami(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_team_inbox(text) to anon, authenticated;
grant execute on function public.yawmi_team_ack(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- المشرف: ربط تابع بمسؤول. إعادة الربط ترسل حساب الفريق إليهما من جديد (إن ضاع من جهاز)
create or replace function public.yawmi_admin_link(p_admin text, p_leader text, p_member text)
returns boolean language plpgsql security definer set search_path = public as $$
declare l text; m text; t text; nm text; lb text; dv json;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  select code into l from public.yawmi_accounts where public.yawmi_short(code) = p_leader and team_leader is null;
  select code, uname, label into m, nm, lb from public.yawmi_accounts where public.yawmi_short(code) = p_member and team_leader is null;
  if l is null or m is null or l = m then return false; end if;
  select code into t from public.yawmi_accounts where team_leader = l;
  if t is null then
    t := public.yawmi_create();
    update public.yawmi_accounts set team_leader = l, uname = (select uname from public.yawmi_accounts where code = l) where code = t;
  end if;
  update public.yawmi_accounts set team_taken = false where code = t;
  if exists (select 1 from public.yawmi_team_members where team = t and member = m) then
    update public.yawmi_team_members set taken = false where team = t and member = m;
    return true;
  end if;
  dv := public.yawmi_add_device(t, lb);
  update public.yawmi_devices set uname = nm where token = dv->>'token';
  insert into public.yawmi_team_members (team, member, token) values (t, m, dv->>'token');
  return true;
end; $$;

-- المشرف: فك ربط تابع (يُحذف جهازه من حساب الفريق)
create or replace function public.yawmi_admin_unlink(p_admin text, p_leader text, p_member text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  delete from public.yawmi_devices where token in (
    select m.token from public.yawmi_team_members m join public.yawmi_accounts t on t.code = m.team
    where public.yawmi_short(t.team_leader) = p_leader and public.yawmi_short(m.member) = p_member);
  return found;
end; $$;

revoke all on function public.yawmi_admin_link(text, text, text) from public;
revoke all on function public.yawmi_admin_unlink(text, text, text) from public;
grant execute on function public.yawmi_admin_link(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_admin_unlink(text, text, text) to anon, authenticated;

-- الإحصاءات: الأشخاص والفرق كلٌّ على حدة
create or replace function public.yawmi_admin_stats(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return json_build_object(
    'accounts', (select count(*) from public.yawmi_accounts where team_leader is null),
    'accounts_7', (select count(*) from public.yawmi_accounts where team_leader is null and updated_at > now() - interval '7 days'),
    'accounts_30', (select count(*) from public.yawmi_accounts where team_leader is null and updated_at > now() - interval '30 days'),
    'teams', (select count(*) from public.yawmi_accounts where team_leader is not null),
    'devices', (select count(*) from public.yawmi_devices),
    'devices_7', (select count(*) from public.yawmi_devices where last_seen > now() - interval '7 days'),
    'push', (select count(*) from public.yawmi_push),
    'db_bytes', pg_database_size(current_database()),
    'data_bytes', (select coalesce(sum(pg_column_size(a.*)), 0) from public.yawmi_accounts a),
    'idle_days', public.yawmi_idle_days()
  );
end; $$;

-- الأشخاص (بلا حسابات الفرق): الاسم ونوع الجهاز، ومن يتبعه، ومن يتبع هو
create or replace function public.yawmi_admin_accounts(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.updated_at desc), '[]'::json) from (
    select public.yawmi_short(a.code) as id, a.uname as name, a.label, a.created_at, a.updated_at,
           pg_column_size(a.*) as bytes,
           (select count(*) from public.yawmi_devices d where d.code = a.code) as devices,
           (select max(d.last_seen) from public.yawmi_devices d where d.code = a.code) as devices_seen,
           (select count(*) from public.yawmi_push p where p.code = a.code) as push,
           (select t.updated_at from public.yawmi_accounts t where t.team_leader = a.code) as team_seen,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(m.member), 'name', ma.uname, 'num', d.num, 'label', d.label, 'seen', d.last_seen, 'taken', m.taken) order by d.num), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts t on t.code = m.team and t.team_leader = a.code
            join public.yawmi_accounts ma on ma.code = m.member
            join public.yawmi_devices d on d.token = m.token) as members,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(t.team_leader), 'name', la.uname)), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts t on t.code = m.team
            join public.yawmi_accounts la on la.code = t.team_leader
            where m.member = a.code) as leaders
    from public.yawmi_accounts a where a.team_leader is null) x);
end; $$;

-- التنظيف: لا يُحذف حساب مسؤول ما دام فريقه نشيطًا
create or replace function public.yawmi_cleanup()
returns json language plpgsql security definer set search_path = public as $$
declare a int; d int;
begin
  delete from public.yawmi_devices where last_seen < now() - make_interval(days => public.yawmi_idle_days());
  get diagnostics d = row_count;
  delete from public.yawmi_accounts x where x.updated_at < now() - make_interval(days => public.yawmi_idle_days())
    and not exists (select 1 from public.yawmi_accounts t where t.team_leader = x.code and t.updated_at >= now() - make_interval(days => public.yawmi_idle_days()));
  get diagnostics a = row_count;
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  delete from cron.job_run_details where end_time < now() - interval '2 days';
  return json_build_object('accounts_deleted', a, 'devices_deleted', d);
end; $$;
revoke all on function public.yawmi_cleanup() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- للتأكد
select (select count(*) from public.yawmi_accounts where team_leader is null) as "الأشخاص",
       (select count(*) from public.yawmi_accounts where team_leader is not null) as "الفرق";


-- ════════════════ supabase_v11.sql ════════════════

-- يومي: التحديث الحادي عشر — فرق بأسماء، وأكثر من فريق للمسؤول، ورابط دعوة لكل فريق
-- شغّل هذا الملف مرة واحدة بعد supabase_v10.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) المشرف ينشئ فريقًا باسم (مثل «فريق المبيعات») ويختار مسؤوله. للمسؤول أن يدير أكثر من فريق.
-- ٢) لكل فريق رابط دعوة ينتهي بعد مدة يختارها المشرف (من ساعة إلى ٧ أيام)، ويستطيع إيقافه متى شاء.
--    من فتح الرابط وكتب اسمه: يبقى له حسابه الشخصي، ويُضاف إليه حساب الفريق وهو تابع فيه.
-- ٣) يبقى الربط اليدوي من اللوحة: إضافة شخص إلى فريق أو إزالته.

drop index if exists public.yawmi_accounts_team_leader;
alter table public.yawmi_accounts add column if not exists team_name text;
alter table public.yawmi_accounts add column if not exists invite_token text;
alter table public.yawmi_accounts add column if not exists invite_until timestamptz;
create unique index if not exists yawmi_accounts_invite on public.yawmi_accounts (invite_token) where invite_token is not null;

-- داخلية: يضيف الشخص تابعًا في الفريق (جهازًا ثانويًا فيه) ويعيد مفتاحه، أو مفتاحه القديم إن كان تابعًا
create or replace function public.yawmi_team_add_member(p_team text, p_member text)
returns text language plpgsql security definer set search_path = public as $$
declare tk text; nm text; lb text; dv json;
begin
  select token into tk from public.yawmi_team_members where team = p_team and member = p_member;
  if tk is not null then return tk; end if;
  select uname, label into nm, lb from public.yawmi_accounts where code = p_member;
  dv := public.yawmi_add_device(p_team, lb);
  update public.yawmi_devices set uname = nm where token = dv->>'token';
  insert into public.yawmi_team_members (team, member, token) values (p_team, p_member, dv->>'token');
  return dv->>'token';
end; $$;
revoke all on function public.yawmi_team_add_member(text, text) from public, anon, authenticated;

-- اسم الفريق كما يظهر على الأجهزة
create or replace function public.yawmi_team_title(p_team text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(t.team_name, 'فريق ' || coalesce(l.uname, 'المسؤول'))
  from public.yawmi_accounts t left join public.yawmi_accounts l on l.code = t.team_leader where t.code = p_team;
$$;
revoke all on function public.yawmi_team_title(text) from public, anon, authenticated;

-- ما ينتظر هذا الشخص من حسابات فرق (الآن مع اسم الفريق)
create or replace function public.yawmi_team_inbox(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return '[]'::json; end if;
  return (select coalesce(json_agg(x), '[]'::json) from (
    select 'lead' as kind, t.code as key, 1 as num, l.uname as leader, public.yawmi_short(t.code) as team, t.team_name as name
    from public.yawmi_accounts t join public.yawmi_accounts l on l.code = t.team_leader
    where t.team_leader = c and not t.team_taken
    union all
    select 'member', m.token, d.num, l.uname, public.yawmi_short(m.team), public.yawmi_team_title(m.team)
    from public.yawmi_team_members m
    join public.yawmi_devices d on d.token = m.token
    join public.yawmi_accounts t on t.code = m.team
    join public.yawmi_accounts l on l.code = t.team_leader
    where m.member = c and not m.taken) x);
end; $$;

-- الانضمام برابط الدعوة: p_key مفتاح الحساب الشخصي على هذا الجهاز
create or replace function public.yawmi_team_join(p_key text, p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int; t text; l text; tk text;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 or coalesce(p_token, '') = '' then return null; end if;
  if exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null) then return null; end if;
  select code, team_leader into t, l from public.yawmi_accounts where invite_token = p_token and invite_until > now();
  if t is null then return null; end if;
  if l = c then -- المسؤول فتح رابط فريقه
    update public.yawmi_accounts set team_taken = true where code = t;
    return json_build_object('kind', 'lead', 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
  end if;
  tk := public.yawmi_team_add_member(t, c);
  update public.yawmi_devices set label = coalesce(left(nullif(trim(p_label), ''), 40), label) where token = tk;
  update public.yawmi_team_members set taken = true where team = t and member = c;
  return json_build_object('kind', 'member', 'key', tk, 'num', (select num from public.yawmi_devices where token = tk),
    'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;
revoke all on function public.yawmi_team_join(text, text, text) from public;
grant execute on function public.yawmi_team_join(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- المشرف: الفرق مع مسؤوليها وتابعيها ورابط الدعوة الساري
create or replace function public.yawmi_admin_teams(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.created_at), '[]'::json) from (
    select public.yawmi_short(t.code) as id, public.yawmi_team_title(t.code) as name, t.created_at, t.updated_at,
           public.yawmi_short(t.team_leader) as leader_id, l.uname as leader_name, t.team_taken as leader_taken,
           case when t.invite_until > now() then t.invite_token end as invite,
           case when t.invite_until > now() then t.invite_until end as invite_until,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(m.member), 'name', ma.uname, 'num', d.num, 'label', d.label, 'seen', d.last_seen, 'taken', m.taken) order by d.num), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts ma on ma.code = m.member
            join public.yawmi_devices d on d.token = m.token
            where m.team = t.code) as members
    from public.yawmi_accounts t join public.yawmi_accounts l on l.code = t.team_leader) x);
end; $$;

-- المشرف: فريق جديد باسم ومسؤول
create or replace function public.yawmi_admin_team_new(p_admin text, p_leader text, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare l text; t text;
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  select code into l from public.yawmi_accounts where public.yawmi_short(code) = p_leader and team_leader is null;
  if l is null then return null; end if;
  t := public.yawmi_create();
  update public.yawmi_accounts set team_leader = l, team_name = left(nullif(trim(p_name), ''), 40),
    uname = (select uname from public.yawmi_accounts where code = l) where code = t;
  return public.yawmi_short(t);
end; $$;

-- المشرف: إضافة شخص إلى فريق. إعادة الإضافة ترسل الفريق إليه وإلى المسؤول من جديد (إن ضاع من جهاز)
create or replace function public.yawmi_admin_team_add(p_admin text, p_team text, p_member text)
returns boolean language plpgsql security definer set search_path = public as $$
declare t text; l text; m text;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  select code, team_leader into t, l from public.yawmi_accounts where public.yawmi_short(code) = p_team and team_leader is not null;
  select code into m from public.yawmi_accounts where public.yawmi_short(code) = p_member and team_leader is null;
  if t is null or m is null or m = l then return false; end if;
  perform public.yawmi_team_add_member(t, m);
  update public.yawmi_team_members set taken = false where team = t and member = m;
  update public.yawmi_accounts set team_taken = false where code = t;
  return true;
end; $$;

-- المشرف: إزالة شخص من فريق (يُحذف جهازه من حساب الفريق)
create or replace function public.yawmi_admin_team_remove(p_admin text, p_team text, p_member text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  delete from public.yawmi_devices where token in (
    select m.token from public.yawmi_team_members m
    where public.yawmi_short(m.team) = p_team and public.yawmi_short(m.member) = p_member);
  return found;
end; $$;

-- المشرف: رابط دعوة جديد صالح p_hours ساعة (حتى ٧ أيام)، أو إيقافه بـ 0
create or replace function public.yawmi_admin_team_invite(p_admin text, p_team text, p_hours int)
returns text language plpgsql security definer set search_path = public as $$
declare t text; tk text;
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  select code into t from public.yawmi_accounts where public.yawmi_short(code) = p_team and team_leader is not null;
  if t is null then return null; end if;
  if coalesce(p_hours, 0) <= 0 then
    update public.yawmi_accounts set invite_token = null, invite_until = null where code = t;
    return '';
  end if;
  loop
    tk := public.yawmi_rand(12);
    exit when not exists (select 1 from public.yawmi_accounts where invite_token = tk);
  end loop;
  update public.yawmi_accounts set invite_token = tk, invite_until = now() + make_interval(hours => least(p_hours, 168)) where code = t;
  return tk;
end; $$;

revoke all on function public.yawmi_admin_teams(text) from public;
revoke all on function public.yawmi_admin_team_new(text, text, text) from public;
revoke all on function public.yawmi_admin_team_add(text, text, text) from public;
revoke all on function public.yawmi_admin_team_remove(text, text, text) from public;
revoke all on function public.yawmi_admin_team_invite(text, text, int) from public;
grant execute on function public.yawmi_admin_teams(text) to anon, authenticated;
grant execute on function public.yawmi_admin_team_new(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_admin_team_add(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_admin_team_remove(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_admin_team_invite(text, text, int) to anon, authenticated;

-- الربط القديم (v10) لم يعد يُستعمل من التطبيق
drop function if exists public.yawmi_admin_link(text, text, text);
drop function if exists public.yawmi_admin_unlink(text, text, text);

notify pgrst, 'reload schema';

select (select count(*) from public.yawmi_accounts where team_leader is not null) as "الفرق";


-- ════════════════ supabase_v12.sql ════════════════

-- يومي: التحديث الثاني عشر — كل مستخدم ينشئ فريقه ورابط دعوته بنفسه
-- شغّل هذا الملف مرة واحدة بعد supabase_v11.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) من التطبيق: ⚙ ← الحسابات ← «أنشئ فريقًا»: يصبح صاحب الحساب مسؤول الفريق، ويُضاف حساب الفريق إلى جهازه.
--    (حتى ١٠ فرق لكل شخص.)
-- ٢) مسؤول الفريق ينشئ رابط دعوة من داخل حساب الفريق (من ساعة إلى ٧ أيام) أو يوقفه.
-- ٣) المشرف يبقى يرى كل الفرق ويديرها من لوحته كما في v11.

-- فريق جديد: p_key مفتاح الحساب الشخصي (المسؤول الأول فيه)
create or replace function public.yawmi_team_create(p_key text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int; t text;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 or coalesce(trim(p_name), '') = '' then return null; end if;
  if exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null) then return null; end if;
  if (select count(*) from public.yawmi_accounts where team_leader = c) >= 10 then return json_build_object('err', 'limit'); end if;
  t := public.yawmi_create();
  update public.yawmi_accounts set team_leader = c, team_name = left(trim(p_name), 40), team_taken = true,
    uname = (select uname from public.yawmi_accounts where code = c) where code = t;
  return json_build_object('kind', 'lead', 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;

-- معلومات الفريق لمسؤوله: p_key كود حساب الفريق (null إن لم يكن حساب فريق)
create or replace function public.yawmi_team_info(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  select json_build_object('name', public.yawmi_team_title(t.code),
    'invite', case when t.invite_until > now() then t.invite_token end,
    'invite_until', case when t.invite_until > now() then t.invite_until end) into r
  from public.yawmi_accounts t where t.code = p_key and t.team_leader is not null;
  return r;
end; $$;

-- رابط الدعوة من مسؤول الفريق: p_hours ساعة (حتى ٧ أيام)، أو 0 لإيقافه
create or replace function public.yawmi_team_link(p_key text, p_hours int)
returns text language plpgsql security definer set search_path = public as $$
declare tk text;
begin
  if not exists (select 1 from public.yawmi_accounts where code = p_key and team_leader is not null) then return null; end if;
  if coalesce(p_hours, 0) <= 0 then
    update public.yawmi_accounts set invite_token = null, invite_until = null where code = p_key;
    return '';
  end if;
  loop
    tk := public.yawmi_rand(12);
    exit when not exists (select 1 from public.yawmi_accounts where invite_token = tk);
  end loop;
  update public.yawmi_accounts set invite_token = tk, invite_until = now() + make_interval(hours => least(p_hours, 168)) where code = p_key;
  return tk;
end; $$;

revoke all on function public.yawmi_team_create(text, text) from public;
revoke all on function public.yawmi_team_info(text) from public;
revoke all on function public.yawmi_team_link(text, int) from public;
grant execute on function public.yawmi_team_create(text, text) to anon, authenticated;
grant execute on function public.yawmi_team_info(text) to anon, authenticated;
grant execute on function public.yawmi_team_link(text, int) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v13.sql ════════════════

-- يومي: التحديث الثالث عشر — حدود الحسابات والفرق، وطلبات الصلاحية من المشرف
-- شغّل هذا الملف مرة واحدة بعد supabase_v12.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) لكل شخص حساب شخصي واحد (يطبّقه التطبيق على الجهاز)، وفريقان على الأكثر بين ما يكون مسؤوله وما ينضم إليه
--    (يطبّقه الخادم). من تجاوز الحد قبل هذا التحديث تبقى له فرقه، ويُمنع من الزيادة فقط.
-- ٢) عند الوصول إلى الحد يرسل الشخص «طلبًا إلى المشرف» مع سبب قصير.
-- ٣) المشرف يرى الطلبات في لوحته ويوافق أو يرفض. الموافقة ترفع حدّ ذلك الشخص وحده درجة واحدة.
-- ٤) المشرف نفسه يستطيع إضافة أي شخص إلى أي فريق من لوحته متجاوزًا الحد.

alter table public.yawmi_accounts add column if not exists max_personal int not null default 1;
alter table public.yawmi_accounts add column if not exists max_teams int not null default 2;

create table if not exists public.yawmi_requests (
  id         bigserial primary key,
  code       text not null references public.yawmi_accounts(code) on delete cascade,
  kind       text not null check (kind in ('personal', 'teams')),
  note       text,
  status     text not null default 'pending' check (status in ('pending', 'ok', 'no')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create unique index if not exists yawmi_requests_pending on public.yawmi_requests (code, kind) where status = 'pending';
alter table public.yawmi_requests enable row level security;
revoke all on public.yawmi_requests from anon, authenticated;

-- كم فريقًا لهذا الشخص: ما يكون مسؤوله + ما هو تابع فيه
create or replace function public.yawmi_teams_used(p_code text)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*) from public.yawmi_accounts where team_leader = p_code)::int
       + (select count(*) from public.yawmi_team_members where member = p_code)::int;
$$;
revoke all on function public.yawmi_teams_used(text) from public, anon, authenticated;

-- الحساب الشخصي (المسؤول الأول فيه، وليس حساب فريق) من مفتاحه، وإلا null
create or replace function public.yawmi_person(p_key text)
returns text language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return null; end if;
  if exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null) then return null; end if;
  return c;
end; $$;
revoke all on function public.yawmi_person(text) from public, anon, authenticated;

-- حدود هذا الشخص وما استعمله، وطلباته المعلّقة
create or replace function public.yawmi_limits(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select json_build_object('max_personal', a.max_personal, 'max_teams', a.max_teams, 'teams_used', public.yawmi_teams_used(c),
    'pending', (select coalesce(json_agg(r.kind), '[]'::json) from public.yawmi_requests r where r.code = c and r.status = 'pending'))
    from public.yawmi_accounts a where a.code = c);
end; $$;

-- طلب إلى المشرف: حساب شخصي إضافي أو فريق إضافي
create or replace function public.yawmi_request(p_key text, p_kind text, p_note text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or p_kind not in ('personal', 'teams') then return false; end if;
  insert into public.yawmi_requests (code, kind, note) values (c, p_kind, left(nullif(trim(p_note), ''), 200))
  on conflict (code, kind) where status = 'pending' do update set note = excluded.note, created_at = now();
  return true;
end; $$;

-- إنشاء فريق (v12) مع حد الفرق
create or replace function public.yawmi_team_create(p_key text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text;
begin
  if c is null or coalesce(trim(p_name), '') = '' then return null; end if;
  if public.yawmi_teams_used(c) >= (select max_teams from public.yawmi_accounts where code = c) then return json_build_object('err', 'limit'); end if;
  t := public.yawmi_create();
  update public.yawmi_accounts set team_leader = c, team_name = left(trim(p_name), 40), team_taken = true,
    uname = (select uname from public.yawmi_accounts where code = c) where code = t;
  return json_build_object('kind', 'lead', 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;

-- الانضمام برابط (v11) مع حد الفرق
create or replace function public.yawmi_team_join(p_key text, p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text; l text; tk text;
begin
  if c is null or coalesce(p_token, '') = '' then return null; end if;
  select code, team_leader into t, l from public.yawmi_accounts where invite_token = p_token and invite_until > now();
  if t is null then return null; end if;
  if l = c then
    update public.yawmi_accounts set team_taken = true where code = t;
    return json_build_object('kind', 'lead', 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
  end if;
  if not exists (select 1 from public.yawmi_team_members where team = t and member = c)
     and public.yawmi_teams_used(c) >= (select max_teams from public.yawmi_accounts where code = c) then
    return json_build_object('err', 'limit', 'name', public.yawmi_team_title(t));
  end if;
  tk := public.yawmi_team_add_member(t, c);
  update public.yawmi_devices set label = coalesce(left(nullif(trim(p_label), ''), 40), label) where token = tk;
  update public.yawmi_team_members set taken = true where team = t and member = c;
  return json_build_object('kind', 'member', 'key', tk, 'num', (select num from public.yawmi_devices where token = tk),
    'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;

revoke all on function public.yawmi_limits(text) from public;
revoke all on function public.yawmi_request(text, text, text) from public;
grant execute on function public.yawmi_limits(text) to anon, authenticated;
grant execute on function public.yawmi_request(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- المشرف: الطلبات المعلّقة
create or replace function public.yawmi_admin_requests(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.created_at), '[]'::json) from (
    select r.id, r.kind, r.note, r.created_at, public.yawmi_short(a.code) as person, a.uname as name, a.label,
           a.max_personal, a.max_teams, public.yawmi_teams_used(a.code) as teams_used
    from public.yawmi_requests r join public.yawmi_accounts a on a.code = r.code
    where r.status = 'pending') x);
end; $$;

-- المشرف: موافقة (ترفع الحد درجة) أو رفض
create or replace function public.yawmi_admin_request_decide(p_admin text, p_id bigint, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; k text;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_requests set status = case when p_ok then 'ok' else 'no' end, decided_at = now()
  where id = p_id and status = 'pending' returning code, kind into c, k;
  if c is null then return false; end if;
  if p_ok and k = 'personal' then update public.yawmi_accounts set max_personal = max_personal + 1 where code = c; end if;
  if p_ok and k = 'teams' then update public.yawmi_accounts set max_teams = greatest(max_teams, public.yawmi_teams_used(c)) + 1 where code = c; end if;
  -- القرارات القديمة لا حاجة لها
  delete from public.yawmi_requests where status <> 'pending' and decided_at < now() - interval '30 days';
  return true;
end; $$;

revoke all on function public.yawmi_admin_requests(text) from public;
revoke all on function public.yawmi_admin_request_decide(text, bigint, boolean) from public;
grant execute on function public.yawmi_admin_requests(text) to anon, authenticated;
grant execute on function public.yawmi_admin_request_decide(text, bigint, boolean) to anon, authenticated;

notify pgrst, 'reload schema';

select (select count(*) from public.yawmi_requests where status = 'pending') as "طلبات معلّقة";


-- ════════════════ supabase_v14.sql ════════════════

-- يومي: التحديث الرابع عشر — زر «تصفير المنصة» في لوحة المشرف
-- شغّل هذا الملف مرة واحدة بعد supabase_v13.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- التصفير يحذف كل الحسابات (الشخصية والفرق)، ومعها بالتسلسل: الأجهزة، واشتراكات الإشعارات، والتابعون، والطلبات، ورموز الربط.
-- يبقى: معلومات اليوم (yawmi_tips) ومفتاح المشرف (yawmi_admin).
-- لا رجعة فيه. يحتاج مفتاح المشرف، وكلمة «صفر» تأكيدًا.

create or replace function public.yawmi_admin_reset(p_admin text, p_word text)
returns json language plpgsql security definer set search_path = public as $$
declare a int;
begin
  if not public.yawmi_admin_check(p_admin) or replace(trim(coalesce(p_word, '')), 'ّ', '') <> 'صفر' then return null; end if;
  delete from public.yawmi_accounts where true; -- Supabase يرفض الحذف بلا شرط
  get diagnostics a = row_count;
  delete from public.yawmi_link_requests where true;
  return json_build_object('accounts', a);
end; $$;
revoke all on function public.yawmi_admin_reset(text, text) from public;
grant execute on function public.yawmi_admin_reset(text, text) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v15.sql ════════════════

-- يومي: التحديث الخامس عشر — تخفيف الحمل على الخطة المجانية، وحدود المشاركة
-- شغّل هذا الملف مرة واحدة بعد supabase_v14.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) مزامنة ذكية: يسأل التطبيق أولًا عن «ختم» الحساب (وقت آخر تعديل، بضعة بايتات)،
--    ولا ينزّل الحساب كاملًا إلا إن تغيّر. yawmi_get يعيد الختم، وyawmi_save يعيد الختم الجديد.
-- ٢) فحص وجود الحسابات بالختم نفسه بدل تنزيلها.
-- ٣) سجل تغييرات كل جهاز: آخر ٢٥ سطرًا بدل ٣٠٠.
-- ٤) الإشعارات للأجهزة الفعّالة فقط: جهاز فتح التطبيق خلال آخر ٣ أيام. ومن عاد تعود إشعاراته وحدها.
-- ٥) حدود المشاركة: كل شخص ينضم إلى حساب مشترك واحد (يطبّقه التطبيق)، وكل حساب شخصي يُشارَك مع ٣ أجهزة
--    على الأكثر (يطبّقه الخادم). وكلاهما يُرفع بطلب إلى المشرف.

-- ---------------------------------------------------------------------
-- ١) المزامنة الذكية
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
    'num', n, 'stamp', a.updated_at
  ) into r from public.yawmi_accounts a where a.code = c;
  return r;
end; $$;

-- الحفظ يعيد الختم الجديد (أو null إن لم يوجد الحساب)
drop function if exists public.yawmi_save(text, jsonb);
create function public.yawmi_save(p_code text, p_data jsonb)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare c text; n int; s timestamptz;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_code);
  if c is null then return null; end if;
  update public.yawmi_accounts set
    base_date  = coalesce((p_data->>'base_date')::date, base_date),
    day_m3 = p_data->'day_m3', day_m2 = p_data->'day_m2', day_m1 = p_data->'day_m1', day_0 = p_data->'day_0',
    day_p1 = p_data->'day_p1', day_p2 = p_data->'day_p2', day_p3 = p_data->'day_p3',
    settings   = coalesce(p_data->'settings', settings),
    updated_at = now()
  where code = c returning updated_at into s;
  return s;
end; $$;
revoke all on function public.yawmi_save(text, jsonb) from public;
grant execute on function public.yawmi_save(text, jsonb) to anon, authenticated;

-- الختم: وقت آخر تعديل للحساب وتاريخ أساسه، أو null إن لم يعد موجودًا
create or replace function public.yawmi_stamp(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int; r json;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null then return null; end if;
  select json_build_object('stamp', a.updated_at, 'base_date', a.base_date) into r from public.yawmi_accounts a where a.code = c;
  return r;
end; $$;
revoke all on function public.yawmi_stamp(text) from public;
grant execute on function public.yawmi_stamp(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- ٣) سجل التغييرات: آخر ٢٥ سطرًا
create or replace function public.yawmi_log_add(p_code text, p_events jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  lines text[] := '{}';
  e jsonb;
  k int := 0;
  cur text[];
begin
  if not exists (select 1 from public.yawmi_devices where token = p_code) then
    return exists (select 1 from public.yawmi_accounts where code = p_code);
  end if;
  if jsonb_typeof(p_events) <> 'array' then return false; end if;
  for e in select value from jsonb_array_elements(p_events) loop
    k := k + 1;
    exit when k > 25;
    if jsonb_typeof(e) = 'string' then
      lines := lines || left(replace(e #>> '{}', E'\n', ' '), 200);
    elsif jsonb_typeof(e) = 'object' then
      lines := lines || left(trim(coalesce(e->>'action', '') || ' «' || coalesce(e->>'title', '') || '»'), 200);
    end if;
  end loop;
  select coalesce(string_to_array(nullif(changes, ''), E'\n'), '{}') into cur from public.yawmi_devices where token = p_code;
  cur := cur || lines;
  if array_length(cur, 1) > 25 then
    cur := cur[array_length(cur, 1) - 24 : array_length(cur, 1)];
  end if;
  update public.yawmi_devices set changes = array_to_string(cur, E'\n') where token = p_code;
  return true;
end; $$;
-- تقصير السجلات الموجودة
update public.yawmi_devices
set changes = array_to_string((string_to_array(changes, E'\n'))[array_length(string_to_array(changes, E'\n'), 1) - 24 :], E'\n')
where array_length(string_to_array(changes, E'\n'), 1) > 25;

-- ---------------------------------------------------------------------
-- ٤) الإشعارات للأجهزة الفعّالة: كل فتح للتطبيق يجدّد «آخر ظهور» لكل حسابات الجهاز
alter table public.yawmi_push add column if not exists seen timestamptz not null default now();

create or replace function public.yawmi_push_save(p_key text, p_sub jsonb, p_tz int, p_lead int, p_label text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or coalesce(p_sub->>'endpoint', '') !~ '^https://' then return false; end if;
  insert into public.yawmi_push (endpoint, code, sub, tz, lead_min, label, seen)
  values (p_sub->>'endpoint', c, p_sub, greatest(-720, least(840, coalesce(p_tz, 180))),
          greatest(0, least(60, coalesce(p_lead, 0))), left(nullif(trim(p_label), ''), 30), now())
  on conflict (endpoint, code) do update
    set sub = excluded.sub, tz = excluded.tz, lead_min = excluded.lead_min, label = excluded.label, seen = now();
  -- مفاتيح المتصفح ووقت ظهوره مشتركة بين كل حسابات الجهاز
  update public.yawmi_push set sub = p_sub, tz = greatest(-720, least(840, coalesce(p_tz, 180))), seen = now()
  where endpoint = p_sub->>'endpoint' and code <> c;
  return true;
end; $$;

create or replace function public.yawmi_push_due()
returns table (endpoint text, sub jsonb, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_now timestamptz := now();
begin
  perform 1 from public.yawmi_push for update;
  return query
  with s as (
    select p.endpoint, p.sub, p.lead_min, p.label,
           (v_now at time zone 'UTC') + make_interval(mins => p.tz) as t1,
           (greatest(coalesce(p.sent_until, v_now - interval '1 minute'), v_now - interval '3 minutes') at time zone 'UTC') + make_interval(mins => p.tz) as t0,
           array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3] as days
    from public.yawmi_push p
    join public.yawmi_accounts a on a.code = p.code
    where p.seen > v_now - interval '3 days' -- الأجهزة الفعّالة فقط
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

-- ---------------------------------------------------------------------
-- ٥) حدود المشاركة
alter table public.yawmi_accounts add column if not exists max_shared int not null default 1;
alter table public.yawmi_accounts add column if not exists max_devices int not null default 3;
alter table public.yawmi_requests drop constraint if exists yawmi_requests_kind_check;
alter table public.yawmi_requests add constraint yawmi_requests_kind_check check (kind in ('personal', 'teams', 'shared', 'devices'));

-- هل يقبل هذا الحساب جهازًا آخر؟ (حسابات الفرق بلا حد: أعضاؤها يدخلون برابط الدعوة)
create or replace function public.yawmi_device_room(p_code text)
returns boolean language sql stable security definer set search_path = public as $$
  select a.team_leader is not null or (select count(*) from public.yawmi_devices d where d.code = a.code) < a.max_devices
  from public.yawmi_accounts a where a.code = p_code;
$$;
revoke all on function public.yawmi_device_room(text) from public, anon, authenticated;

create or replace function public.yawmi_join(p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  select code into c from public.yawmi_link_requests
  where token = p_token and kind = 'invite' and code is not null and created_at > now() - interval '10 minutes';
  if c is null then return null; end if;
  if not public.yawmi_device_room(c) then return json_build_object('err', 'limit'); end if;
  delete from public.yawmi_link_requests where token = p_token;
  return public.yawmi_add_device(c, p_label);
end; $$;

create or replace function public.yawmi_pair_take(p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  select code into c from public.yawmi_link_requests where token = p_token and kind = 'scan' and code is not null;
  if c is null then return null; end if;
  if not public.yawmi_device_room(c) then
    delete from public.yawmi_link_requests where token = p_token;
    return json_build_object('err', 'limit');
  end if;
  delete from public.yawmi_link_requests where token = p_token;
  return public.yawmi_add_device(c, p_label);
end; $$;

-- الحدود وما استُعمل منها (v13 + المشاركة والأجهزة)
create or replace function public.yawmi_limits(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select json_build_object('max_personal', a.max_personal, 'max_teams', a.max_teams, 'teams_used', public.yawmi_teams_used(c),
    'max_shared', a.max_shared, 'max_devices', a.max_devices,
    'devices_used', (select count(*) from public.yawmi_devices d where d.code = c),
    'pending', (select coalesce(json_agg(r.kind), '[]'::json) from public.yawmi_requests r where r.code = c and r.status = 'pending'))
    from public.yawmi_accounts a where a.code = c);
end; $$;

create or replace function public.yawmi_request(p_key text, p_kind text, p_note text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or p_kind not in ('personal', 'teams', 'shared', 'devices') then return false; end if;
  insert into public.yawmi_requests (code, kind, note) values (c, p_kind, left(nullif(trim(p_note), ''), 200))
  on conflict (code, kind) where status = 'pending' do update set note = excluded.note, created_at = now();
  return true;
end; $$;

create or replace function public.yawmi_admin_requests(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.created_at), '[]'::json) from (
    select r.id, r.kind, r.note, r.created_at, public.yawmi_short(a.code) as person, a.uname as name, a.label,
           a.max_personal, a.max_teams, public.yawmi_teams_used(a.code) as teams_used, a.max_shared, a.max_devices,
           (select count(*) from public.yawmi_devices d where d.code = a.code) as devices_used
    from public.yawmi_requests r join public.yawmi_accounts a on a.code = r.code
    where r.status = 'pending') x);
end; $$;

create or replace function public.yawmi_admin_request_decide(p_admin text, p_id bigint, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; k text;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_requests set status = case when p_ok then 'ok' else 'no' end, decided_at = now()
  where id = p_id and status = 'pending' returning code, kind into c, k;
  if c is null then return false; end if;
  if p_ok then
    if k = 'personal' then update public.yawmi_accounts set max_personal = max_personal + 1 where code = c; end if;
    if k = 'teams' then update public.yawmi_accounts set max_teams = greatest(max_teams, public.yawmi_teams_used(c)) + 1 where code = c; end if;
    if k = 'shared' then update public.yawmi_accounts set max_shared = max_shared + 1 where code = c; end if;
    if k = 'devices' then update public.yawmi_accounts set max_devices = greatest(max_devices, (select count(*) from public.yawmi_devices d where d.code = c)::int) + 1 where code = c; end if;
  end if;
  delete from public.yawmi_requests where status <> 'pending' and decided_at < now() - interval '30 days';
  return true;
end; $$;

notify pgrst, 'reload schema';

select (select count(*) from public.yawmi_push where seen > now() - interval '3 days') as "اشتراكات فعّالة",
       (select count(*) from public.yawmi_push) as "كل الاشتراكات";


-- ════════════════ supabase_v16.sql ════════════════

-- يومي: التحديث السادس عشر — أجهزتي، والحذف من المنصة
-- شغّل هذا الملف مرة واحدة بعد supabase_v15.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) الحساب للشخص لا للجهاز: من يربط جهازه الثاني تظهر عليه كل حساباته (الشخصي وحساباته الأخرى والفرق).
--    الجهاز الجديد يعرض رمزًا (٨ أحرف وQR)، والجهاز القديم يمسحه أو يكتبه. لكل شخص ٣ أجهزة (max_devices).
-- ٢) الحسابات الشخصية الأخرى (العمل…) تُنشأ على الخادم باسم صاحبها (owner)، فتنتقل معه إلى أجهزته.
-- ٣) حذف حساب من التطبيق يحذفه من المنصة: الفريق يُحذف لكل أعضائه إن حذفه مسؤوله، ويخرج منه العضو إن حذفه.
-- ٤) أُلغيت مشاركة الحساب الشخصي برمز الربط. الأجهزة المربوطة قبل هذا التحديث تبقى حتى تُزال.

-- ---------------------------------------------------------------------
-- ١) أجهزة الشخص
create table if not exists public.yawmi_my_devices (
  person     text not null references public.yawmi_accounts(code) on delete cascade,
  dev        text not null,                    -- رقم عشوائي يحفظه الجهاز
  label      text,
  revoked    boolean not null default false,   -- أُزيل من «أجهزتي»، فلا يعود إلا بربط جديد
  created_at timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  primary key (person, dev)
);
alter table public.yawmi_my_devices enable row level security;
revoke all on public.yawmi_my_devices from anon, authenticated;

alter table public.yawmi_accounts add column if not exists owner text references public.yawmi_accounts(code) on delete cascade;
alter table public.yawmi_accounts add column if not exists pname text; -- اسم الحساب الشخصي الآخر كما يظهر على الأجهزة

-- الشخص (v13) من مفتاح حسابه الأول فقط: لا حساب فريق، ولا حساب شخصي آخر له صاحب
create or replace function public.yawmi_person(p_key text)
returns text language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return null; end if;
  if exists (select 1 from public.yawmi_accounts where code = c and (team_leader is not null or owner is not null)) then return null; end if;
  return c;
end; $$;
revoke all on function public.yawmi_person(text) from public, anon, authenticated;

create or replace function public.yawmi_my_count(p_person text)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.yawmi_my_devices where person = p_person and not revoked;
$$;
revoke all on function public.yawmi_my_count(text) from public, anon, authenticated;

-- كل حسابات الشخص: فرقه (مسؤولًا أو عضوًا) وحساباته الشخصية الأخرى
create or replace function public.yawmi_my_accounts(p_person text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x), '[]'::json) from (
    select 'lead' as kind, t.code as key, 1 as num, public.yawmi_team_title(t.code) as name
    from public.yawmi_accounts t where t.team_leader = p_person
    union all
    select 'member', m.token, d.num, public.yawmi_team_title(m.team)
    from public.yawmi_team_members m join public.yawmi_devices d on d.token = m.token
    where m.member = p_person
    union all
    select 'own', o.code, 1, coalesce(o.pname, 'حساب')
    from public.yawmi_accounts o where o.owner = p_person and o.team_leader is null) x;
$$;
revoke all on function public.yawmi_my_accounts(text) from public, anon, authenticated;

-- عند كل فتح: يسجّل الجهاز (أول مرة) ويجدّد ظهوره، ويعيد حسابات الشخص، أو revoked إن أُزيل
create or replace function public.yawmi_me(p_key text, p_dev text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); rv boolean;
begin
  if c is null or coalesce(p_dev, '') = '' then return null; end if;
  select revoked into rv from public.yawmi_my_devices where person = c and dev = left(p_dev, 40);
  if rv then return json_build_object('revoked', true); end if;
  insert into public.yawmi_my_devices (person, dev, label) values (c, left(p_dev, 40), left(nullif(trim(p_label), ''), 40))
  on conflict (person, dev) do update set last_seen = now(), label = coalesce(excluded.label, public.yawmi_my_devices.label);
  return json_build_object('accounts', public.yawmi_my_accounts(c), 'uname', (select uname from public.yawmi_accounts where code = c));
end; $$;

create or replace function public.yawmi_my_devices_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select coalesce(json_agg(json_build_object('dev', d.dev, 'label', d.label, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.created_at), '[]'::json)
    from public.yawmi_my_devices d where d.person = c and not d.revoked);
end; $$;

create or replace function public.yawmi_my_device_remove(p_key text, p_dev text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return false; end if;
  update public.yawmi_my_devices set revoked = true where person = c and dev = p_dev;
  return found;
end; $$;

-- ربط جهاز جديد: الجديد يعرض رمزًا، والقديم يوافق عليه، ثم يأخذ الجديدُ مفتاحَ الشخص
create or replace function public.yawmi_mine_start()
returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  loop
    t := public.yawmi_rand(8);
    exit when not exists (select 1 from public.yawmi_link_requests where token = t);
  end loop;
  insert into public.yawmi_link_requests (token, kind) values (t, 'mine');
  return t;
end; $$;

-- يعيد ok، أو limit إن وصل الشخص إلى حد أجهزته، أو null إن كان الرمز غير صحيح
create or replace function public.yawmi_mine_approve(p_token text, p_key text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  if public.yawmi_my_count(c) >= (select max_devices from public.yawmi_accounts where code = c) then return 'limit'; end if;
  update public.yawmi_link_requests set code = c
  where token = p_token and kind = 'mine' and code is null and created_at > now() - interval '10 minutes';
  return case when found then 'ok' end;
end; $$;

create or replace function public.yawmi_mine_take(p_token text, p_dev text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if coalesce(p_dev, '') = '' then return null; end if;
  delete from public.yawmi_link_requests where token = p_token and kind = 'mine' and code is not null
  returning code into c;
  if c is null then return null; end if;
  insert into public.yawmi_my_devices (person, dev, label) values (c, left(p_dev, 40), left(nullif(trim(p_label), ''), 40))
  on conflict (person, dev) do update set revoked = false, last_seen = now(), label = coalesce(excluded.label, public.yawmi_my_devices.label);
  return json_build_object('key', c, 'uname', (select uname from public.yawmi_accounts where code = c));
end; $$;

-- ---------------------------------------------------------------------
-- ٢) الحسابات الشخصية الأخرى: تُنشأ باسم صاحبها (مع حد max_personal)
create or replace function public.yawmi_own_create(p_key text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text;
begin
  if c is null or coalesce(trim(p_name), '') = '' then return null; end if;
  if (select count(*) from public.yawmi_accounts where owner = c) + 1 >= (select max_personal from public.yawmi_accounts where code = c) then
    return json_build_object('err', 'limit');
  end if;
  t := public.yawmi_create();
  update public.yawmi_accounts set owner = c, pname = left(trim(p_name), 30),
    uname = (select uname from public.yawmi_accounts where code = c) where code = t;
  return json_build_object('kind', 'own', 'key', t, 'num', 1, 'name', left(trim(p_name), 30));
end; $$;

-- حساب شخصي آخر أُنشئ قبل هذا التحديث يُنسب إلى صاحبه، ومنه يُحدَّث الاسم عند تغييره
create or replace function public.yawmi_own_claim(p_key text, p_code text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or p_code = c then return false; end if;
  update public.yawmi_accounts set owner = c, pname = coalesce(left(nullif(trim(p_name), ''), 30), pname)
  where code = p_code and team_leader is null and (owner is null or owner = c);
  return found;
end; $$;

-- ---------------------------------------------------------------------
-- ٣) الحذف من المنصة. p_key مفتاح الحساب على هذا الجهاز:
--    فريق (مسؤوله) أو حساب شخصي آخر ← يُحذف كليًا. عضو في فريق أو جهاز مربوط ← يخرج منه.
--    والحساب الشخصي الأول لا يُحذف من هنا.
create or replace function public.yawmi_remove(p_key text, p_endpoint text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; who text;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null then return true; end if; -- لم يعد موجودًا
  if n = 1 then
    if not exists (select 1 from public.yawmi_accounts where code = c and (team_leader is not null or owner is not null)) then return false; end if;
    delete from public.yawmi_accounts where code = c;
    return true;
  end if;
  -- إشعارات هذا الحساب تتوقف على هذا الجهاز، وعلى كل أجهزة العضو
  select member into who from public.yawmi_team_members where token = p_key;
  delete from public.yawmi_push where code = c and (endpoint = p_endpoint
    or (who is not null and endpoint in (select endpoint from public.yawmi_push where code = who)));
  delete from public.yawmi_devices where token = p_key;
  return true;
end; $$;

-- ---------------------------------------------------------------------
-- ٤) الحدود: «الأجهزة» صارت أجهزة الشخص نفسه
create or replace function public.yawmi_limits(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select json_build_object('max_personal', a.max_personal, 'max_teams', a.max_teams, 'teams_used', public.yawmi_teams_used(c),
    'max_shared', a.max_shared, 'max_devices', a.max_devices,
    'devices_used', public.yawmi_my_count(c),
    'pending', (select coalesce(json_agg(r.kind), '[]'::json) from public.yawmi_requests r where r.code = c and r.status = 'pending'))
    from public.yawmi_accounts a where a.code = c);
end; $$;

create or replace function public.yawmi_admin_requests(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.created_at), '[]'::json) from (
    select r.id, r.kind, r.note, r.created_at, public.yawmi_short(a.code) as person, a.uname as name, a.label,
           a.max_personal, a.max_teams, public.yawmi_teams_used(a.code) as teams_used, a.max_shared, a.max_devices,
           public.yawmi_my_count(a.code) as devices_used
    from public.yawmi_requests r join public.yawmi_accounts a on a.code = r.code
    where r.status = 'pending') x);
end; $$;

create or replace function public.yawmi_admin_request_decide(p_admin text, p_id bigint, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; k text;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_requests set status = case when p_ok then 'ok' else 'no' end, decided_at = now()
  where id = p_id and status = 'pending' returning code, kind into c, k;
  if c is null then return false; end if;
  if p_ok then
    if k = 'personal' then update public.yawmi_accounts set max_personal = greatest(max_personal, (select count(*) from public.yawmi_accounts where owner = c)::int + 1) + 1 where code = c; end if;
    if k = 'teams' then update public.yawmi_accounts set max_teams = greatest(max_teams, public.yawmi_teams_used(c)) + 1 where code = c; end if;
    if k = 'shared' then update public.yawmi_accounts set max_shared = max_shared + 1 where code = c; end if;
    if k = 'devices' then update public.yawmi_accounts set max_devices = greatest(max_devices, public.yawmi_my_count(c)) + 1 where code = c; end if;
  end if;
  delete from public.yawmi_requests where status <> 'pending' and decided_at < now() - interval '30 days';
  return true;
end; $$;

-- التنظيف اليومي (v10) + أجهزة الشخص الخاملة (المُزالة تبقى حتى لا تعود وحدها)
create or replace function public.yawmi_cleanup()
returns json language plpgsql security definer set search_path = public as $$
declare a int; d int;
begin
  delete from public.yawmi_devices where last_seen < now() - make_interval(days => public.yawmi_idle_days());
  get diagnostics d = row_count;
  delete from public.yawmi_my_devices where not revoked and last_seen < now() - make_interval(days => public.yawmi_idle_days());
  delete from public.yawmi_accounts x where x.updated_at < now() - make_interval(days => public.yawmi_idle_days())
    and not exists (select 1 from public.yawmi_accounts t where t.team_leader = x.code and t.updated_at >= now() - make_interval(days => public.yawmi_idle_days()))
    and not exists (select 1 from public.yawmi_accounts o where o.owner = x.code and o.updated_at >= now() - make_interval(days => public.yawmi_idle_days()));
  get diagnostics a = row_count;
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  delete from cron.job_run_details where end_time < now() - interval '2 days';
  return json_build_object('accounts_deleted', a, 'devices_deleted', d);
end; $$;
revoke all on function public.yawmi_cleanup() from public, anon, authenticated;

-- ---------------------------------------------------------------------
revoke all on function public.yawmi_me(text, text, text) from public;
revoke all on function public.yawmi_my_devices_list(text) from public;
revoke all on function public.yawmi_my_device_remove(text, text) from public;
revoke all on function public.yawmi_mine_start() from public;
revoke all on function public.yawmi_mine_approve(text, text) from public;
revoke all on function public.yawmi_mine_take(text, text, text) from public;
revoke all on function public.yawmi_own_create(text, text) from public;
revoke all on function public.yawmi_own_claim(text, text, text) from public;
revoke all on function public.yawmi_remove(text, text) from public;
grant execute on function public.yawmi_me(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_my_devices_list(text) to anon, authenticated;
grant execute on function public.yawmi_my_device_remove(text, text) to anon, authenticated;
grant execute on function public.yawmi_mine_start() to anon, authenticated;
grant execute on function public.yawmi_mine_approve(text, text) to anon, authenticated;
grant execute on function public.yawmi_mine_take(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_own_create(text, text) to anon, authenticated;
grant execute on function public.yawmi_own_claim(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_remove(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

select (select count(*) from public.yawmi_accounts where team_leader is null and owner is null) as "أشخاص",
       (select count(*) from public.yawmi_my_devices where not revoked) as "أجهزتهم";


-- ════════════════ supabase_v17.sql ════════════════

-- يومي: التحديث السابع عشر — الحساب المشترك والفريق، وإنشاء ما وافق عليه المشرف تلقائيًا
-- شغّل هذا الملف مرة واحدة بعد supabase_v16.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) نوعان من الحسابات التي يدخلها الآخرون برابط دعوة (team_kind):
--    team   = فريق: مسؤول وأتباع، ويرى المسؤول سجل تغييرات كل تابع. حد الفرق max_teams.
--    shared = حساب مشترك (للعائلة): أعضاؤه متساوون، بلا سجل تغييرات، وفيه «أبنائي». حده max_shared.
--    الفرق الموجودة قبل هذا التحديث تبقى «فريقًا».
-- ٢) طلب فريق أو حساب مشترك من المشرف يحمل اسمه، فإن وافق المشرف أُنشئ تلقائيًا وظهر على أجهزة صاحبه.

alter table public.yawmi_accounts add column if not exists team_kind text not null default 'team';
alter table public.yawmi_accounts drop constraint if exists yawmi_accounts_team_kind_check;
alter table public.yawmi_accounts add constraint yawmi_accounts_team_kind_check check (team_kind in ('team', 'shared'));
alter table public.yawmi_requests add column if not exists name text;

-- كم فريقًا (أو حسابًا مشتركًا) لهذا الشخص: ما يكون مسؤوله + ما هو عضو فيه
create or replace function public.yawmi_kind_used(p_code text, p_kind text)
returns int language sql stable security definer set search_path = public as $$
  select (select count(*) from public.yawmi_accounts where team_leader = p_code and team_kind = p_kind)::int
       + (select count(*) from public.yawmi_team_members m join public.yawmi_accounts t on t.code = m.team
          where m.member = p_code and t.team_kind = p_kind)::int;
$$;
revoke all on function public.yawmi_kind_used(text, text) from public, anon, authenticated;

create or replace function public.yawmi_teams_used(p_code text)
returns int language sql stable security definer set search_path = public as $$
  select public.yawmi_kind_used(p_code, 'team');
$$;
revoke all on function public.yawmi_teams_used(text) from public, anon, authenticated;

-- داخلية: هل بقي لهذا الشخص مكان لفريق أو حساب مشترك آخر؟
create or replace function public.yawmi_kind_room(p_code text, p_kind text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.yawmi_kind_used(p_code, p_kind) < (select case when p_kind = 'shared' then max_shared else max_teams end from public.yawmi_accounts where code = p_code);
$$;
revoke all on function public.yawmi_kind_room(text, text) from public, anon, authenticated;

-- داخلية: ينشئ الفريق أو الحساب المشترك ويجعل الشخص مسؤوله
create or replace function public.yawmi_kind_new(p_code text, p_name text, p_kind text)
returns text language plpgsql security definer set search_path = public as $$
declare t text := public.yawmi_create();
begin
  update public.yawmi_accounts set team_leader = p_code, team_name = left(trim(p_name), 40), team_kind = p_kind, team_taken = true,
    uname = (select uname from public.yawmi_accounts where code = p_code) where code = t;
  return t;
end; $$;
revoke all on function public.yawmi_kind_new(text, text, text) from public, anon, authenticated;

create or replace function public.yawmi_team_create(p_key text, p_name text, p_kind text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); k text := case when p_kind = 'shared' then 'shared' else 'team' end; t text;
begin
  if c is null or coalesce(trim(p_name), '') = '' then return null; end if;
  if not public.yawmi_kind_room(c, k) then return json_build_object('err', 'limit', 'tk', k); end if;
  t := public.yawmi_kind_new(c, p_name, k);
  return json_build_object('kind', 'lead', 'tk', k, 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;

-- النسخة القديمة (التطبيق قبل هذا التحديث) تنشئ فريقًا
create or replace function public.yawmi_team_create(p_key text, p_name text)
returns json language sql security definer set search_path = public as $$
  select public.yawmi_team_create(p_key, p_name, 'team');
$$;

-- الانضمام برابط الدعوة، مع حد النوع
create or replace function public.yawmi_team_join(p_key text, p_token text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text; l text; k text; tk text;
begin
  if c is null or coalesce(p_token, '') = '' then return null; end if;
  select code, team_leader, team_kind into t, l, k from public.yawmi_accounts where invite_token = p_token and invite_until > now();
  if t is null then return null; end if;
  if l = c then
    update public.yawmi_accounts set team_taken = true where code = t;
    return json_build_object('kind', 'lead', 'tk', k, 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
  end if;
  if not exists (select 1 from public.yawmi_team_members where team = t and member = c) and not public.yawmi_kind_room(c, k) then
    return json_build_object('err', 'limit', 'tk', k, 'name', public.yawmi_team_title(t));
  end if;
  tk := public.yawmi_team_add_member(t, c);
  update public.yawmi_devices set label = coalesce(left(nullif(trim(p_label), ''), 40), label) where token = tk;
  update public.yawmi_team_members set taken = true where team = t and member = c;
  return json_build_object('kind', 'member', 'tk', k, 'key', tk, 'num', (select num from public.yawmi_devices where token = tk),
    'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;

-- حسابات الشخص (v16) مع نوع كل فريق
create or replace function public.yawmi_my_accounts(p_person text)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x), '[]'::json) from (
    select 'lead' as kind, t.code as key, 1 as num, public.yawmi_team_title(t.code) as name, t.team_kind as tk
    from public.yawmi_accounts t where t.team_leader = p_person
    union all
    select 'member', m.token, d.num, public.yawmi_team_title(m.team), t.team_kind
    from public.yawmi_team_members m join public.yawmi_devices d on d.token = m.token join public.yawmi_accounts t on t.code = m.team
    where m.member = p_person
    union all
    select 'own', o.code, 1, coalesce(o.pname, 'حساب'), null
    from public.yawmi_accounts o where o.owner = p_person and o.team_leader is null) x;
$$;
revoke all on function public.yawmi_my_accounts(text) from public, anon, authenticated;

-- معلومات الفريق لمسؤوله (v12) مع نوعه
create or replace function public.yawmi_team_info(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  select json_build_object('name', public.yawmi_team_title(t.code), 'tk', t.team_kind,
    'invite', case when t.invite_until > now() then t.invite_token end,
    'invite_until', case when t.invite_until > now() then t.invite_until end) into r
  from public.yawmi_accounts t where t.code = p_key and t.team_leader is not null;
  return r;
end; $$;

-- سجل التغييرات (v15): لا يُحفظ في الحساب المشترك
create or replace function public.yawmi_log_add(p_code text, p_events jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  lines text[] := '{}';
  e jsonb;
  k int := 0;
  cur text[];
begin
  if not exists (select 1 from public.yawmi_devices where token = p_code) then
    return exists (select 1 from public.yawmi_accounts where code = p_code);
  end if;
  if exists (select 1 from public.yawmi_devices d join public.yawmi_accounts a on a.code = d.code where d.token = p_code and a.team_kind = 'shared') then
    return true;
  end if;
  if jsonb_typeof(p_events) <> 'array' then return false; end if;
  for e in select value from jsonb_array_elements(p_events) loop
    k := k + 1;
    exit when k > 25;
    if jsonb_typeof(e) = 'string' then
      lines := lines || left(replace(e #>> '{}', E'\n', ' '), 200);
    elsif jsonb_typeof(e) = 'object' then
      lines := lines || left(trim(coalesce(e->>'action', '') || ' «' || coalesce(e->>'title', '') || '»'), 200);
    end if;
  end loop;
  select coalesce(string_to_array(nullif(changes, ''), E'\n'), '{}') into cur from public.yawmi_devices where token = p_code;
  cur := cur || lines;
  if array_length(cur, 1) > 25 then
    cur := cur[array_length(cur, 1) - 24 : array_length(cur, 1)];
  end if;
  update public.yawmi_devices set changes = array_to_string(cur, E'\n') where token = p_code;
  return true;
end; $$;

-- ---------------------------------------------------------------------
-- ٢) الطلبات مع الاسم
create or replace function public.yawmi_request(p_key text, p_kind text, p_note text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or p_kind not in ('personal', 'teams', 'shared', 'devices') then return false; end if;
  insert into public.yawmi_requests (code, kind, note, name) values (c, p_kind, left(nullif(trim(p_note), ''), 200), left(nullif(trim(p_name), ''), 40))
  on conflict (code, kind) where status = 'pending' do update set note = excluded.note, name = excluded.name, created_at = now();
  return true;
end; $$;

create or replace function public.yawmi_limits(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select json_build_object('max_personal', a.max_personal, 'max_teams', a.max_teams, 'teams_used', public.yawmi_teams_used(c),
    'max_shared', a.max_shared, 'shared_used', public.yawmi_kind_used(c, 'shared'), 'max_devices', a.max_devices,
    'devices_used', public.yawmi_my_count(c),
    'pending', (select coalesce(json_agg(r.kind), '[]'::json) from public.yawmi_requests r where r.code = c and r.status = 'pending'))
    from public.yawmi_accounts a where a.code = c);
end; $$;

create or replace function public.yawmi_admin_requests(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.created_at), '[]'::json) from (
    select r.id, r.kind, r.note, r.name as want, r.created_at, public.yawmi_short(a.code) as person, a.uname as name, a.label,
           a.max_personal, a.max_teams, public.yawmi_teams_used(a.code) as teams_used, a.max_shared,
           public.yawmi_kind_used(a.code, 'shared') as shared_used, a.max_devices, public.yawmi_my_count(a.code) as devices_used
    from public.yawmi_requests r join public.yawmi_accounts a on a.code = r.code
    where r.status = 'pending') x);
end; $$;

-- الموافقة ترفع الحد درجة، وإن كان الطلب فريقًا أو حسابًا مشتركًا باسمه أُنشئ له
create or replace function public.yawmi_admin_request_decide(p_admin text, p_id bigint, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; k text; nm text;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_requests set status = case when p_ok then 'ok' else 'no' end, decided_at = now()
  where id = p_id and status = 'pending' returning code, kind, name into c, k, nm;
  if c is null then return false; end if;
  if p_ok then
    if k = 'personal' then update public.yawmi_accounts set max_personal = greatest(max_personal, (select count(*) from public.yawmi_accounts where owner = c)::int + 1) + 1 where code = c; end if;
    if k = 'teams' then update public.yawmi_accounts set max_teams = greatest(max_teams, public.yawmi_teams_used(c)) + 1 where code = c; end if;
    if k = 'shared' then update public.yawmi_accounts set max_shared = greatest(max_shared, public.yawmi_kind_used(c, 'shared')) + 1 where code = c; end if;
    if k = 'devices' then update public.yawmi_accounts set max_devices = greatest(max_devices, public.yawmi_my_count(c)) + 1 where code = c; end if;
    if k in ('teams', 'shared') and nm is not null then
      perform public.yawmi_kind_new(c, nm, case when k = 'shared' then 'shared' else 'team' end);
    end if;
  end if;
  delete from public.yawmi_requests where status <> 'pending' and decided_at < now() - interval '30 days';
  return true;
end; $$;

revoke all on function public.yawmi_team_create(text, text, text) from public;
revoke all on function public.yawmi_request(text, text, text, text) from public;
grant execute on function public.yawmi_team_create(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_request(text, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

select (select count(*) from public.yawmi_accounts where team_kind = 'team' and team_leader is not null) as "فرق",
       (select count(*) from public.yawmi_accounts where team_kind = 'shared' and team_leader is not null) as "حسابات مشتركة";


-- ════════════════ supabase_v18.sql ════════════════

-- يومي: التحديث الثامن عشر — الجهاز الأساسي، ورابط ربط الجهاز
-- شغّل هذا الملف مرة واحدة بعد supabase_v17.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) لكل شخص جهاز أساسي ⭐ (أول جهاز سُجّل له): وحده يضيف الأجهزة ويزيلها، ولا يُزال هو.
--    ويستطيع أن يجعل جهازًا آخر هو الأساسي.
-- ٢) رابط ربط: الجهاز الأساسي يرسل رابطًا (مرة واحدة، ١٠ دقائق)، فمن فتحه على جهازه الجديد رُبط مباشرة.

alter table public.yawmi_my_devices add column if not exists is_main boolean not null default false;

-- لكل شخص ليس له جهاز أساسي: أقدم أجهزته الفعّالة
create or replace function public.yawmi_main_fix(p_person text)
returns void language sql security definer set search_path = public as $$
  update public.yawmi_my_devices d set is_main = true
  where d.person = p_person and not d.revoked
    and not exists (select 1 from public.yawmi_my_devices m where m.person = p_person and m.is_main and not m.revoked)
    and d.dev = (select x.dev from public.yawmi_my_devices x where x.person = p_person and not x.revoked order by x.created_at limit 1);
$$;
revoke all on function public.yawmi_main_fix(text) from public, anon, authenticated;
select public.yawmi_main_fix(p) from (select distinct person as p from public.yawmi_my_devices) s;

-- هل هذا الجهاز هو الأساسي؟
create or replace function public.yawmi_is_main(p_person text, p_dev text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.yawmi_my_devices where person = p_person and dev = p_dev and is_main and not revoked);
$$;
revoke all on function public.yawmi_is_main(text, text) from public, anon, authenticated;

-- عند كل فتح (v16) + هل هو الأساسي
create or replace function public.yawmi_me(p_key text, p_dev text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); rv boolean;
begin
  if c is null or coalesce(p_dev, '') = '' then return null; end if;
  select revoked into rv from public.yawmi_my_devices where person = c and dev = left(p_dev, 40);
  if rv then return json_build_object('revoked', true); end if;
  insert into public.yawmi_my_devices (person, dev, label) values (c, left(p_dev, 40), left(nullif(trim(p_label), ''), 40))
  on conflict (person, dev) do update set last_seen = now(), label = coalesce(excluded.label, public.yawmi_my_devices.label);
  perform public.yawmi_main_fix(c);
  return json_build_object('accounts', public.yawmi_my_accounts(c), 'uname', (select uname from public.yawmi_accounts where code = c),
    'main', public.yawmi_is_main(c, left(p_dev, 40)));
end; $$;

create or replace function public.yawmi_my_devices_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select coalesce(json_agg(json_build_object('dev', d.dev, 'label', d.label, 'main', d.is_main, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.is_main desc, d.created_at), '[]'::json)
    from public.yawmi_my_devices d where d.person = c and not d.revoked);
end; $$;

-- الإزالة من الجهاز الأساسي فقط، ولا يُزال الأساسي
drop function if exists public.yawmi_my_device_remove(text, text);
create or replace function public.yawmi_my_device_remove(p_key text, p_dev text, p_me text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or not public.yawmi_is_main(c, p_me) or p_dev = p_me then return false; end if;
  update public.yawmi_my_devices set revoked = true, is_main = false where person = c and dev = p_dev;
  return found;
end; $$;

-- الأساسي يجعل جهازًا آخر هو الأساسي
create or replace function public.yawmi_my_device_main(p_key text, p_dev text, p_me text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or not public.yawmi_is_main(c, p_me) then return false; end if;
  if not exists (select 1 from public.yawmi_my_devices where person = c and dev = p_dev and not revoked) then return false; end if;
  update public.yawmi_my_devices set is_main = (dev = p_dev) where person = c;
  return true;
end; $$;

-- الموافقة على رمز الجهاز الجديد: من الأساسي فقط (notmain)
drop function if exists public.yawmi_mine_approve(text, text);
create or replace function public.yawmi_mine_approve(p_token text, p_key text, p_me text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  if not public.yawmi_is_main(c, p_me) then return 'notmain'; end if;
  if public.yawmi_my_count(c) >= (select max_devices from public.yawmi_accounts where code = c) then return 'limit'; end if;
  update public.yawmi_link_requests set code = c
  where token = p_token and kind = 'mine' and code is null and created_at > now() - interval '10 minutes';
  return case when found then 'ok' end;
end; $$;

-- رابط ربط من الأساسي: رمز موافَق عليه مسبقًا، يأخذه الجهاز الجديد بـ yawmi_mine_take
create or replace function public.yawmi_mine_link(p_key text, p_me text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text;
begin
  if c is null then return null; end if;
  if not public.yawmi_is_main(c, p_me) then return 'notmain'; end if;
  if public.yawmi_my_count(c) >= (select max_devices from public.yawmi_accounts where code = c) then return 'limit'; end if;
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  loop
    t := public.yawmi_rand(12);
    exit when not exists (select 1 from public.yawmi_link_requests where token = t);
  end loop;
  insert into public.yawmi_link_requests (token, code, kind) values (t, c, 'mine');
  return t;
end; $$;

-- الأخذ (v16) مع صلاحية ١٠ دقائق
create or replace function public.yawmi_mine_take(p_token text, p_dev text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if coalesce(p_dev, '') = '' then return null; end if;
  delete from public.yawmi_link_requests where token = p_token and kind = 'mine' and code is not null and created_at > now() - interval '10 minutes'
  returning code into c;
  if c is null then return null; end if;
  insert into public.yawmi_my_devices (person, dev, label) values (c, left(p_dev, 40), left(nullif(trim(p_label), ''), 40))
  on conflict (person, dev) do update set revoked = false, last_seen = now(), label = coalesce(excluded.label, public.yawmi_my_devices.label);
  perform public.yawmi_main_fix(c);
  return json_build_object('key', c, 'uname', (select uname from public.yawmi_accounts where code = c));
end; $$;

revoke all on function public.yawmi_my_device_remove(text, text, text) from public;
revoke all on function public.yawmi_my_device_main(text, text, text) from public;
revoke all on function public.yawmi_mine_approve(text, text, text) from public;
revoke all on function public.yawmi_mine_link(text, text) from public;
grant execute on function public.yawmi_my_device_remove(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_my_device_main(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_mine_approve(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_mine_link(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

select left(md5(person), 6) as "الشخص", label as "الجهاز", is_main as "أساسي", revoked as "أُزيل", last_seen as "آخر ظهور"
from public.yawmi_my_devices order by person, created_at;


-- ════════════════ supabase_v19.sql ════════════════

-- يومي: التحديث التاسع عشر — «ابدأ من جديد»: تصفير الحساب على كل أجهزته
-- شغّل هذا الملف مرة واحدة بعد supabase_v18.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- يحذف أيام الحساب ومهامه وتقاريره (واختياريًا إعداداته) من السحابة، ويضع «وقت التصفير» reset_at،
-- فكل جهاز يرى وقتًا أحدث مما يعرفه يمسح نسخته هو أيضًا (حتى لا يعيد رفع القديم).
-- من يستطيع: الحساب الشخصي وحسابات الشخص الأخرى من جهازه الأساسي ⭐، والفريق والحساب المشترك من مسؤوله.

alter table public.yawmi_accounts add column if not exists reset_at timestamptz;
alter table public.yawmi_accounts add column if not exists reset_set boolean not null default false;

-- الجلب (v15) + وقت التصفير
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
    'num', n, 'stamp', a.updated_at, 'reset_at', a.reset_at, 'reset_set', a.reset_set
  ) into r from public.yawmi_accounts a where a.code = c;
  return r;
end; $$;

-- التصفير: يعيد وقته، أو null إن لم يكن مسموحًا
create or replace function public.yawmi_reset(p_key text, p_dev text, p_settings boolean)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare c text; n int; l text; o text; ok boolean; t timestamptz := now();
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return null; end if;
  select team_leader, owner into l, o from public.yawmi_accounts where code = c;
  if l is not null then ok := true; -- فريق أو حساب مشترك: مسؤوله يحمل كوده
  elsif o is not null then ok := public.yawmi_is_main(o, p_dev);
  else ok := public.yawmi_is_main(c, p_dev) or not exists (select 1 from public.yawmi_my_devices where person = c and not revoked);
  end if;
  if not ok then return null; end if;
  update public.yawmi_accounts set
    day_m3 = null, day_m2 = null, day_m1 = null, day_0 = null, day_p1 = null, day_p2 = null, day_p3 = null,
    settings = case when p_settings then null else settings end,
    reset_at = t, reset_set = coalesce(p_settings, false), updated_at = t
  where code = c;
  update public.yawmi_devices set changes = null where code = c;
  return t;
end; $$;
revoke all on function public.yawmi_reset(text, text, boolean) from public;
grant execute on function public.yawmi_reset(text, text, boolean) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v20.sql ════════════════

-- يومي: التحديث العشرون — «📨 المعاملات» في الفريق
-- شغّل هذا الملف مرة واحدة بعد supabase_v19.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- معاملة تمرّ على أدوار الفريق بالترتيب (مثل: الديوان ← مدير المكتب ← المالية ← المدير ← الديوان).
-- الأدوار والمسارات الجاهزة ومن يرفض: في إعدادات حساب الفريق (settings.roles / paths / rejecters) يعدّلها المسؤول.
-- صاحب الخطوة الحالية (أو المسؤول) وحده: يرسلها للتالي، أو يرجعها، أو يحوّلها إلى دور آخر، أو يرفضها (إن كان دوره ممن يرفض).
-- كل الأعضاء يرون أين وصلت كل معاملة. ويصل إشعار لصاحب الخطوة الجديدة إن فعّل إشعارات الخادم.

create table if not exists public.yawmi_flows (
  id         bigserial primary key,
  team       text not null references public.yawmi_accounts(code) on delete cascade,
  no         int  not null,
  title      text not null,
  ref        text,
  steps      jsonb not null,                       -- أسماء الأدوار بالترتيب
  pos        int  not null default 0,              -- الخطوة الحالية
  status     text not null default 'open' check (status in ('open', 'done', 'rejected')),
  days       int,                                  -- مهلة كل خطوة بالأيام (اختيارية)
  step_at    timestamptz not null default now(),   -- متى وصلت الخطوة الحالية
  log        jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists yawmi_flows_team on public.yawmi_flows (team, status, updated_at desc);
alter table public.yawmi_flows enable row level security;
revoke all on public.yawmi_flows from anon, authenticated;

-- إشعارات المعاملات تنتظر هنا حتى تأخذها دالة الإرسال مع إشعارات المهام (كل دقيقة)
create table if not exists public.yawmi_flow_pings (
  id       bigserial primary key,
  endpoint text not null,
  sub      jsonb not null,
  title    text not null,
  body     text not null,
  tag      text not null,
  at       timestamptz not null default now()
);
alter table public.yawmi_flow_pings enable row level security;
revoke all on public.yawmi_flow_pings from anon, authenticated;

-- كل اشتراك إشعارات يعرف رقم الجهاز في حسابه، ليصل إشعار المعاملة لصاحب الدور وحده
alter table public.yawmi_push add column if not exists num int;

create or replace function public.yawmi_push_save(p_key text, p_sub jsonb, p_tz int, p_lead int, p_label text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or coalesce(p_sub->>'endpoint', '') !~ '^https://' then return false; end if;
  insert into public.yawmi_push (endpoint, code, sub, tz, lead_min, label, seen, num)
  values (p_sub->>'endpoint', c, p_sub, greatest(-720, least(840, coalesce(p_tz, 180))),
          greatest(0, least(60, coalesce(p_lead, 0))), left(nullif(trim(p_label), ''), 30), now(), n)
  on conflict (endpoint, code) do update
    set sub = excluded.sub, tz = excluded.tz, lead_min = excluded.lead_min, label = excluded.label, seen = now(), num = excluded.num;
  update public.yawmi_push set sub = p_sub, tz = greatest(-720, least(840, coalesce(p_tz, 180))), seen = now()
  where endpoint = p_sub->>'endpoint' and code <> c;
  return true;
end; $$;

-- داخلية: حساب الفريق ورقم الجهاز من المفتاح، أو null إن لم يكن فريقًا
create or replace function public.yawmi_flow_who(p_key text, out r_team text, out r_num int)
language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or not exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null and team_kind = 'team') then return; end if;
  r_team := c; r_num := n;
end; $$;
revoke all on function public.yawmi_flow_who(text) from public, anon, authenticated;

create or replace function public.yawmi_role_of(p_team text, p_num int)
returns text language sql stable security definer set search_path = public as $$
  select nullif(trim(settings->'roles'->>(p_num::text)), '') from public.yawmi_accounts where code = p_team;
$$;
revoke all on function public.yawmi_role_of(text, int) from public, anon, authenticated;

create or replace function public.yawmi_member_name(p_team text, p_num int)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(case when p_num = 1 then (select uname from public.yawmi_accounts where code = p_team)
                       else (select uname from public.yawmi_devices where code = p_team and num = p_num) end, 'جهاز ' || p_num);
$$;
revoke all on function public.yawmi_member_name(text, int) from public, anon, authenticated;

-- داخلية: إشعار لأصحاب الدور الحالي
create or replace function public.yawmi_flow_ping(p_id bigint, p_from text)
returns void language plpgsql security definer set search_path = public as $$
declare f public.yawmi_flows; r text;
begin
  select * into f from public.yawmi_flows where id = p_id;
  if f.id is null or f.status <> 'open' then return; end if;
  r := f.steps->>f.pos;
  insert into public.yawmi_flow_pings (endpoint, sub, title, body, tag)
  select p.endpoint, p.sub, '📨 معاملة وصلتك: ' || left(f.title, 60), 'رقم ' || f.no || ' · من ' || coalesce(p_from, ''), 'flow:' || f.id || ':' || f.pos
  from public.yawmi_push p, public.yawmi_accounts a
  where p.code = f.team and a.code = f.team and p.seen > now() - interval '3 days'
    and p.num is not null and nullif(trim(a.settings->'roles'->>(p.num::text)), '') = r;
end; $$;
revoke all on function public.yawmi_flow_ping(bigint, text) from public, anon, authenticated;

-- المعاملات: المفتوحة كلها، والمنتهية في آخر ٣٠ يومًا
create or replace function public.yawmi_flows_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null then return null; end if;
  return (select coalesce(json_agg(json_build_object('id', f.id, 'no', f.no, 'title', f.title, 'ref', f.ref, 'steps', f.steps, 'pos', f.pos,
      'status', f.status, 'days', f.days, 'step_at', f.step_at, 'created_at', f.created_at, 'updated_at', f.updated_at, 'log', f.log)
      order by (f.status = 'open') desc, f.updated_at desc), '[]'::json)
    from public.yawmi_flows f where f.team = w.r_team and (f.status = 'open' or f.updated_at > now() - interval '30 days'));
end; $$;

create or replace function public.yawmi_flow_new(p_key text, p_title text, p_ref text, p_steps jsonb, p_days int)
returns bigint language plpgsql security definer set search_path = public as $$
declare w record; me text; st jsonb; p int := 0; i bigint; nm text;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null or coalesce(trim(p_title), '') = '' or jsonb_typeof(p_steps) <> 'array' then return null; end if;
  select coalesce(jsonb_agg(left(trim(x), 30)), '[]'::jsonb) into st from jsonb_array_elements_text(p_steps) x where trim(x) <> '';
  if jsonb_array_length(st) = 0 or jsonb_array_length(st) > 20 then return null; end if;
  me := public.yawmi_role_of(w.r_team, w.r_num); nm := public.yawmi_member_name(w.r_team, w.r_num);
  if me is not null and st->>0 = me and jsonb_array_length(st) > 1 then p := 1; end if; -- من يسجّلها في أول المسار أنجز خطوته
  delete from public.yawmi_flows where team = w.r_team and status <> 'open' and updated_at < now() - interval '90 days';
  insert into public.yawmi_flows (team, no, title, ref, steps, pos, days, log)
  values (w.r_team, coalesce((select max(no) from public.yawmi_flows where team = w.r_team), 0) + 1, left(trim(p_title), 120),
          left(nullif(trim(p_ref), ''), 40), st, p, case when p_days > 0 then least(p_days, 60) end,
          jsonb_build_array(jsonb_build_object('at', now(), 'n', w.r_num, 'who', nm, 'role', me, 'act', 'start')))
  returning id into i;
  perform public.yawmi_flow_ping(i, nm);
  return i;
end; $$;

-- p_act: next (أرسلها للتالي، أو تنتهي بعد آخر خطوة) · back (أرجعها) · route (حوّلها إلى p_role) · reject (ارفضها)
create or replace function public.yawmi_flow_act(p_key text, p_id bigint, p_act text, p_note text, p_role text)
returns text language plpgsql security definer set search_path = public as $$
declare w record; f public.yawmi_flows; me text; nm text; last int; e jsonb; rj boolean;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null then return 'no'; end if;
  select * into f from public.yawmi_flows where id = p_id and team = w.r_team for update;
  if f.id is null or f.status <> 'open' then return 'gone'; end if;
  me := public.yawmi_role_of(w.r_team, w.r_num); nm := public.yawmi_member_name(w.r_team, w.r_num);
  if w.r_num <> 1 and coalesce(me, '') <> coalesce(f.steps->>f.pos, '-') then return 'notyours'; end if;
  last := jsonb_array_length(f.steps) - 1;
  e := jsonb_build_object('at', now(), 'n', w.r_num, 'who', nm, 'role', me, 'act', p_act, 'note', left(nullif(trim(p_note), ''), 300), 'from', f.steps->>f.pos);
  if p_act = 'next' then
    if f.pos >= last then update public.yawmi_flows set status = 'done', log = log || e, updated_at = now() where id = f.id;
    else update public.yawmi_flows set pos = pos + 1, step_at = now(), log = log || e, updated_at = now() where id = f.id;
    end if;
  elsif p_act = 'back' then
    if f.pos = 0 then return 'first'; end if;
    update public.yawmi_flows set pos = pos - 1, step_at = now(), log = log || e, updated_at = now() where id = f.id;
  elsif p_act = 'route' then
    if coalesce(trim(p_role), '') = '' then return 'no'; end if;
    update public.yawmi_flows set steps = (select coalesce(jsonb_agg(v order by o), '[]'::jsonb) from (
        select v, (o - 1) * 2 as o from jsonb_array_elements(f.steps) with ordinality t(v, o)
        union all select to_jsonb(left(trim(p_role), 30)), f.pos * 2 + 1) s),
      pos = pos + 1, step_at = now(), log = log || (e || jsonb_build_object('to', left(trim(p_role), 30))), updated_at = now() where id = f.id;
  elsif p_act = 'reject' then
    select coalesce(a.settings->'rejecters' ? me, false) into rj from public.yawmi_accounts a where a.code = w.r_team;
    if w.r_num <> 1 and not rj then return 'norej'; end if;
    update public.yawmi_flows set status = 'rejected', log = log || e, updated_at = now() where id = f.id;
  else
    return 'no';
  end if;
  perform public.yawmi_flow_ping(f.id, nm);
  return 'ok';
end; $$;

-- الإرسال كل دقيقة (v15) + إشعارات المعاملات المنتظرة
create or replace function public.yawmi_push_due()
returns table (endpoint text, sub jsonb, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_now timestamptz := now();
begin
  perform 1 from public.yawmi_push for update;
  return query
  with s as (
    select p.endpoint, p.sub, p.lead_min, p.label,
           (v_now at time zone 'UTC') + make_interval(mins => p.tz) as t1,
           (greatest(coalesce(p.sent_until, v_now - interval '1 minute'), v_now - interval '3 minutes') at time zone 'UTC') + make_interval(mins => p.tz) as t0,
           array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3] as days
    from public.yawmi_push p
    join public.yawmi_accounts a on a.code = p.code
    where p.seen > v_now - interval '3 days'
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
  where due.at_ts > due.t0 and due.at_ts <= due.t1
  union all
  select q.endpoint, q.sub, q.title, q.body, q.tag from public.yawmi_flow_pings q;
  delete from public.yawmi_flow_pings where at <= v_now;
  update public.yawmi_push set sent_until = v_now where true; -- Supabase يرفض التحديث بلا شرط
end; $$;
revoke all on function public.yawmi_push_due() from public, anon, authenticated;
grant execute on function public.yawmi_push_due() to service_role;

revoke all on function public.yawmi_flows_list(text) from public;
revoke all on function public.yawmi_flow_new(text, text, text, jsonb, int) from public;
revoke all on function public.yawmi_flow_act(text, bigint, text, text, text) from public;
grant execute on function public.yawmi_flows_list(text) to anon, authenticated;
grant execute on function public.yawmi_flow_new(text, text, text, jsonb, int) to anon, authenticated;
grant execute on function public.yawmi_flow_act(text, bigint, text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v21.sql ════════════════

-- يومي: التحديث الحادي والعشرون — إصلاح تسجيل المعاملات («column reference "r_num" is ambiguous»)
-- شغّل هذا الملف مرة واحدة بعد supabase_v20.sql من: Supabase ← SQL Editor ← New query ← Run.

create or replace function public.yawmi_flow_who(p_key text, out r_team text, out r_num int)
language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or not exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null and team_kind = 'team') then return; end if;
  r_team := c; r_num := n;
end; $$;
revoke all on function public.yawmi_flow_who(text) from public, anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v22.sql ════════════════

-- يومي: التحديث الثاني والعشرون — «👑 اجعله المسؤول»: نقل مسؤولية الفريق أو الحساب المشترك إلى عضو
-- شغّل هذا الملف مرة واحدة بعد supabase_v21.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- العضو (ممن انضم برابط الدعوة) يصبح المسؤول، والمسؤول السابق يصبح عضوًا. وتنتقل الأدوار في المعاملات مع أصحابها:
-- المسؤول دائمًا رقم ١، فيأخذ الجديد دور رقم ١، ويأخذ السابق رقمه الجديد بدوره القديم.
-- كل جهاز يبدّل الحساب عند تحققه التالي (yawmi_me).

create or replace function public.yawmi_team_handover(p_key text, p_num int)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; l text; m text; tk text; nt text; nn int; ro jsonb; r jsonb;
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or n <> 1 then return false; end if;
  select team_leader, settings->'roles' into l, ro from public.yawmi_accounts where code = c;
  if l is null then return false; end if;
  select tm.member, tm.token into m, tk
  from public.yawmi_team_members tm join public.yawmi_devices d on d.token = tm.token
  where tm.team = c and d.num = p_num;
  if m is null or m = l then return false; end if; -- عضو بالطريقة القديمة (بلا شخص) لا يُنقل إليه
  delete from public.yawmi_devices where token = tk; -- يحذف عضويته معه
  update public.yawmi_accounts set team_leader = m, team_taken = true, uname = (select uname from public.yawmi_accounts where code = m) where code = c;
  nt := public.yawmi_team_add_member(c, l);
  update public.yawmi_team_members set taken = true where team = c and member = l;
  select num into nn from public.yawmi_devices where token = nt;
  if ro is not null and jsonb_typeof(ro) = 'object' then
    r := ro - '1' - (p_num::text);
    if ro ? (p_num::text) then r := r || jsonb_build_object('1', ro->(p_num::text)); end if;
    if ro ? '1' then r := r || jsonb_build_object(nn::text, ro->'1'); end if;
    update public.yawmi_accounts set settings = jsonb_set(jsonb_set(settings, '{roles}', r), '{updatedAt}', to_jsonb((extract(epoch from now()) * 1000)::bigint)),
      updated_at = now() where code = c;
  end if;
  return true;
end; $$;
revoke all on function public.yawmi_team_handover(text, int) from public;
grant execute on function public.yawmi_team_handover(text, int) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v23.sql ════════════════

-- يومي: التحديث الثالث والعشرون — موافقة المشرف على طلب الانضمام تضيف الشخص إلى الفريق مباشرة
-- شغّل هذا الملف مرة واحدة بعد supabase_v22.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- من وصل إلى حد الفرق (أو الحسابات المشتركة) وهو يفتح رابط دعوة، يُحفظ الفريق مع طلبه،
-- فإن وافق المشرف أُضيف إليه تلقائيًا، وظهر على أجهزته عند تحققها التالي.

alter table public.yawmi_requests add column if not exists team text references public.yawmi_accounts(code) on delete set null;

create or replace function public.yawmi_request(p_key text, p_kind text, p_note text, p_name text, p_invite text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text;
begin
  if c is null or p_kind not in ('personal', 'teams', 'shared', 'devices') then return false; end if;
  if coalesce(p_invite, '') <> '' then
    select code into t from public.yawmi_accounts where invite_token = p_invite and invite_until > now() and team_leader is not null;
  end if;
  insert into public.yawmi_requests (code, kind, note, name, team) values (c, p_kind, left(nullif(trim(p_note), ''), 200), left(nullif(trim(p_name), ''), 40), t)
  on conflict (code, kind) where status = 'pending' do update set note = excluded.note, name = excluded.name, team = coalesce(excluded.team, public.yawmi_requests.team), created_at = now();
  return true;
end; $$;
revoke all on function public.yawmi_request(text, text, text, text, text) from public;
grant execute on function public.yawmi_request(text, text, text, text, text) to anon, authenticated;

create or replace function public.yawmi_admin_requests(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.created_at), '[]'::json) from (
    select r.id, r.kind, r.note, r.name as want, case when r.team is not null then public.yawmi_team_title(r.team) end as joins,
           r.created_at, public.yawmi_short(a.code) as person, a.uname as name, a.label,
           a.max_personal, a.max_teams, public.yawmi_teams_used(a.code) as teams_used, a.max_shared,
           public.yawmi_kind_used(a.code, 'shared') as shared_used, a.max_devices, public.yawmi_my_count(a.code) as devices_used
    from public.yawmi_requests r join public.yawmi_accounts a on a.code = r.code
    where r.status = 'pending') x);
end; $$;

-- الموافقة (v17) + الانضمام إلى الفريق المحفوظ مع الطلب
create or replace function public.yawmi_admin_request_decide(p_admin text, p_id bigint, p_ok boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; k text; nm text; t text;
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_requests set status = case when p_ok then 'ok' else 'no' end, decided_at = now()
  where id = p_id and status = 'pending' returning code, kind, name, team into c, k, nm, t;
  if c is null then return false; end if;
  if p_ok then
    if k = 'personal' then update public.yawmi_accounts set max_personal = greatest(max_personal, (select count(*) from public.yawmi_accounts where owner = c)::int + 1) + 1 where code = c; end if;
    if k = 'teams' then update public.yawmi_accounts set max_teams = greatest(max_teams, public.yawmi_teams_used(c)) + 1 where code = c; end if;
    if k = 'shared' then update public.yawmi_accounts set max_shared = greatest(max_shared, public.yawmi_kind_used(c, 'shared')) + 1 where code = c; end if;
    if k = 'devices' then update public.yawmi_accounts set max_devices = greatest(max_devices, public.yawmi_my_count(c)) + 1 where code = c; end if;
    if k in ('teams', 'shared') and t is not null and exists (select 1 from public.yawmi_accounts where code = t and team_leader is not null and team_leader <> c) then
      perform public.yawmi_team_add_member(t, c);
      update public.yawmi_team_members set taken = true where team = t and member = c;
    elsif k in ('teams', 'shared') and nm is not null then
      perform public.yawmi_kind_new(c, nm, case when k = 'shared' then 'shared' else 'team' end);
    end if;
  end if;
  delete from public.yawmi_requests where status <> 'pending' and decided_at < now() - interval '30 days';
  return true;
end; $$;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v24.sql ════════════════

-- يومي: التحديث الرابع والعشرون — تاريخ المعاملة وموعدها النهائي، وتنزيل المعاملات عند تغيّرها فقط
-- شغّل هذا الملف مرة واحدة بعد supabase_v23.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) لكل معاملة تاريخ اختياري (مثل تاريخ الكتاب الوارد) وموعد نهائي اختياري للمعاملة كلها.
-- ٢) «ختم» المعاملات: يسأل التطبيق أولًا هل تغيّر شيء (بضعة بايتات)، ولا ينزّل القائمة إلا إن تغيّرت.

alter table public.yawmi_flows add column if not exists doc_date date;
alter table public.yawmi_flows add column if not exists due date;

-- الختم: آخر تعديل وعدد المعاملات الظاهرة، أو null إن لم يكن فريقًا
create or replace function public.yawmi_flows_stamp(p_key text)
returns text language plpgsql security definer set search_path = public as $$
declare w record; r text;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null then return null; end if;
  select coalesce(max(f.updated_at)::text, '-') || '#' || count(*) into r
  from public.yawmi_flows f where f.team = w.r_team and (f.status = 'open' or f.updated_at > now() - interval '30 days');
  return r;
end; $$;

create or replace function public.yawmi_flows_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null then return null; end if;
  return (select coalesce(json_agg(json_build_object('id', f.id, 'no', f.no, 'title', f.title, 'ref', f.ref, 'steps', f.steps, 'pos', f.pos,
      'status', f.status, 'days', f.days, 'doc_date', f.doc_date, 'due', f.due, 'step_at', f.step_at, 'created_at', f.created_at, 'updated_at', f.updated_at, 'log', f.log)
      order by (f.status = 'open') desc, f.updated_at desc), '[]'::json)
    from public.yawmi_flows f where f.team = w.r_team and (f.status = 'open' or f.updated_at > now() - interval '30 days'));
end; $$;

-- التسجيل (v20) مع التاريخين
create or replace function public.yawmi_flow_new(p_key text, p_title text, p_ref text, p_steps jsonb, p_days int, p_doc date, p_due date)
returns bigint language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  i := public.yawmi_flow_new(p_key, p_title, p_ref, p_steps, p_days);
  if i is not null then update public.yawmi_flows set doc_date = p_doc, due = p_due where id = i; end if;
  return i;
end; $$;

revoke all on function public.yawmi_flows_stamp(text) from public;
revoke all on function public.yawmi_flow_new(text, text, text, jsonb, int, date, date) from public;
grant execute on function public.yawmi_flows_stamp(text) to anon, authenticated;
grant execute on function public.yawmi_flow_new(text, text, text, jsonb, int, date, date) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v25.sql ════════════════

-- يومي: التحديث الخامس والعشرون — لوحة المشرف تعرض نوع كل حساب وصاحبه وأجهزته
-- شغّل هذا الملف مرة واحدة بعد supabase_v24.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- قائمة «الأشخاص» كانت تخلط الأشخاص بحساباتهم الشخصية الأخرى (مثل «العمل»). الآن لكل حساب:
-- kind: person (شخص) أو own (حساب آخر لشخص، مع اسمه واسم صاحبه)، وعدد أجهزة الشخص (my_devices).
-- والشخص بلا اسم ولا أجهزة: حساب أُنشئ ولم يُستعمل (مثل جهاز رُبط بعدها بحساب آخر)، ويحذفه التنظيف بعد ٣٠ يومًا.

create or replace function public.yawmi_admin_accounts(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.updated_at desc), '[]'::json) from (
    select public.yawmi_short(a.code) as id, a.uname as name, a.label, a.created_at, a.updated_at,
           pg_column_size(a.*) as bytes,
           case when a.owner is not null then 'own' else 'person' end as kind,
           a.pname, (select o.uname from public.yawmi_accounts o where o.code = a.owner) as owner_name,
           case when a.owner is not null then public.yawmi_short(a.owner) end as owner_id,
           (select count(*) from public.yawmi_my_devices m where m.person = a.code and not m.revoked) as my_devices,
           (select count(*) from public.yawmi_devices d where d.code = a.code) as devices,
           (select max(d.last_seen) from public.yawmi_devices d where d.code = a.code) as devices_seen,
           (select count(*) from public.yawmi_push p where p.code = a.code) as push,
           (select t.updated_at from public.yawmi_accounts t where t.team_leader = a.code) as team_seen,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(m.member), 'name', ma.uname, 'num', d.num, 'label', d.label, 'seen', d.last_seen, 'taken', m.taken) order by d.num), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts t on t.code = m.team and t.team_leader = a.code
            join public.yawmi_accounts ma on ma.code = m.member
            join public.yawmi_devices d on d.token = m.token) as members,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(t.team_leader), 'name', la.uname)), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts t on t.code = m.team
            join public.yawmi_accounts la on la.code = t.team_leader
            where m.member = a.code) as leaders
    from public.yawmi_accounts a where a.team_leader is null) x);
end; $$;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v26.sql ════════════════

-- يومي: التحديث السادس والعشرون — «معلومة اليوم» في أيام معيّنة
-- شغّل هذا الملف مرة واحدة بعد supabase_v25.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- لكل معلومة جدول اختياري: أيام من الأسبوع (wdays: ٠ الأحد … ٦ السبت)، أو أيام من الشهر الهجري (hdays)
-- مع شهر هجري اختياري (hmonth: ١ محرم … ١٢ ذو الحجة). في تلك الأيام تتقدّم المعلومة المجدولة على المعتادة،
-- وفي غيرها لا تظهر. والمعلومات بلا جدول تدور كما كانت.
-- مثال: تذكير صيام الاثنين والخميس ← الأحد والأربعاء. أيام البيض ← ١٢ و١٣ و١٤. يوم عرفة ← ٨ و٩ من ذي الحجة.

alter table public.yawmi_tips add column if not exists wdays int[];
alter table public.yawmi_tips add column if not exists hdays int[];
alter table public.yawmi_tips add column if not exists hmonth int;

-- المعلومة ليوم: p_hm/p_hd الشهر واليوم الهجريان كما يحسبهما الجهاز (أم القرى)
create or replace function public.yawmi_tip_for(p_day date, p_hm int, p_hd int)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json; dow int := extract(dow from p_day)::int; i int := p_day - date '2026-01-01';
begin
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

-- المعتادة (v6): تدور على المعلومات بلا جدول فقط
create or replace function public.yawmi_tip_for(p_day date)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json;
begin
  select count(*) into c from public.yawmi_tips where active and wdays is null and hdays is null;
  if c = 0 then return null; end if;
  select json_build_object('id', t.id, 'body', t.body, 'source', t.source) into r
  from public.yawmi_tips t where t.active and t.wdays is null and t.hdays is null
  order by t.id
  offset (((p_day - date '2026-01-01') % c) + c) % c
  limit 1;
  return r;
end; $$;

-- المشرف: إضافة معلومة مجدولة أو تعديل جدولها (مصفوفة فارغة = بلا جدول)
create or replace function public.yawmi_tip_plan(p_admin text, p_id int, p_body text, p_source text, p_wdays int[], p_hdays int[], p_hmonth int)
returns json language plpgsql security definer set search_path = public as $$
declare r public.yawmi_tips; w int[] := nullif(p_wdays, '{}'); h int[] := nullif(p_hdays, '{}');
begin
  if not public.yawmi_admin_check(p_admin) or coalesce(trim(p_body), '') = '' then return null; end if;
  if p_id is null then
    insert into public.yawmi_tips (body, source, wdays, hdays, hmonth)
    values (left(trim(p_body), 600), left(nullif(trim(p_source), ''), 120), w, h, case when h is not null and p_hmonth between 1 and 12 then p_hmonth end) returning * into r;
  else
    update public.yawmi_tips set body = left(trim(p_body), 600), source = left(nullif(trim(p_source), ''), 120),
      wdays = w, hdays = h, hmonth = case when h is not null and p_hmonth between 1 and 12 then p_hmonth end, active = true, updated_at = now()
    where id = p_id returning * into r;
  end if;
  return json_build_object('id', r.id, 'body', r.body, 'source', r.source);
end; $$;

-- المشرف: المعلومات المجدولة المفعّلة
create or replace function public.yawmi_admin_tips(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(json_build_object('id', t.id, 'body', t.body, 'source', t.source, 'wdays', t.wdays, 'hdays', t.hdays, 'hmonth', t.hmonth) order by t.id), '[]'::json)
    from public.yawmi_tips t where t.active and (t.wdays is not null or t.hdays is not null));
end; $$;

revoke all on function public.yawmi_tip_for(date, int, int) from public;
revoke all on function public.yawmi_tip_plan(text, int, text, text, int[], int[], int) from public;
revoke all on function public.yawmi_admin_tips(text) from public;
grant execute on function public.yawmi_tip_for(date, int, int) to anon, authenticated;
grant execute on function public.yawmi_tip_plan(text, int, text, text, int[], int[], int) to anon, authenticated;
grant execute on function public.yawmi_admin_tips(text) to anon, authenticated;

-- أمثلة جاهزة (تُضاف مرة واحدة)
insert into public.yawmi_tips (body, source, wdays)
select 'غدًا يوم تُعرض فيه الأعمال، فانوِ صيامه إن استطعت: «تُعرض الأعمال يوم الاثنين والخميس، فأحب أن يُعرض عملي وأنا صائم».', 'رواه الترمذي', '{0,3}'
where not exists (select 1 from public.yawmi_tips where wdays = '{0,3}');
insert into public.yawmi_tips (body, source, hdays)
select 'أيام البيض: ١٣ و١٤ و١٥ من الشهر الهجري، يُستحب صيامها. قال ﷺ: «صوم ثلاثة أيام من كل شهر صوم الدهر كله».', 'رواه البخاري ومسلم', '{12,13,14}'
where not exists (select 1 from public.yawmi_tips where hdays = '{12,13,14}' and hmonth is null);

notify pgrst, 'reload schema';


-- ════════════════ supabase_v27.sql ════════════════

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


-- ════════════════ supabase_v28.sql ════════════════

-- يومي: التحديث الثامن والعشرون — إشعار لمن سجّل المعاملة حين تنتهي أو تُرفض
-- شغّل هذا الملف مرة واحدة بعد supabase_v27.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- قبل هذا التحديث كان الإشعار يصل فقط لصاحب الخطوة التالية، فإن أُنجزت المعاملة أو رُفضت لم يصل شيء.
-- الآن يصل لمن سجّلها (أول سطر في سجلها): «✅ انتهت المعاملة» أو «❌ رُفضت المعاملة»، ومعه اسم من أنهاها أو رفضها.

create or replace function public.yawmi_flow_ping(p_id bigint, p_from text)
returns void language plpgsql security definer set search_path = public as $$
declare f public.yawmi_flows; r text; starter int;
begin
  select * into f from public.yawmi_flows where id = p_id;
  if f.id is null then return; end if;
  if f.status = 'open' then
    r := f.steps->>f.pos;
    insert into public.yawmi_flow_pings (endpoint, sub, title, body, tag)
    select p.endpoint, p.sub, '📨 معاملة وصلتك: ' || left(f.title, 60), 'رقم ' || f.no || ' · من ' || coalesce(p_from, ''), 'flow:' || f.id || ':' || f.pos
    from public.yawmi_push p, public.yawmi_accounts a
    where p.code = f.team and a.code = f.team and p.seen > now() - interval '3 days'
      and p.num is not null and nullif(trim(a.settings->'roles'->>(p.num::text)), '') = r;
    return;
  end if;
  -- finished or rejected: tell the one who registered it
  starter := nullif(f.log->0->>'n', '')::int;
  if starter is null then return; end if;
  insert into public.yawmi_flow_pings (endpoint, sub, title, body, tag)
  select p.endpoint, p.sub,
         case when f.status = 'done' then '✅ انتهت المعاملة: ' else '❌ رُفضت المعاملة: ' end || left(f.title, 60),
         'رقم ' || f.no || ' · ' || case when f.status = 'done' then 'أنهاها ' else 'رفضها ' end || coalesce(p_from, ''),
         'flow:' || f.id || ':end'
  from public.yawmi_push p
  where p.code = f.team and p.num = starter and p.seen > now() - interval '3 days';
end; $$;
revoke all on function public.yawmi_flow_ping(bigint, text) from public, anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ supabase_v29.sql ════════════════

-- يومي: التحديث التاسع والعشرون — تغيير اسم الفريق أو الحساب المشترك
-- شغّل هذا الملف مرة واحدة بعد supabase_v28.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- كان الاسم يتغير على جهاز المسؤول فقط، ويبقى القديم في السحابة، فيظهر في «جدولي» والدعوة ولدى الأعضاء.
-- مسؤول الفريق وحده (رقم ١) يغيّره. لا جداول جديدة.

create or replace function public.yawmi_team_rename(p_key text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; nm text := left(trim(coalesce(p_name, '')), 40);
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or n <> 1 or nm = '' then return false; end if;
  update public.yawmi_accounts set team_name = nm where code = c and team_leader is not null;
  return found;
end; $$;
revoke all on function public.yawmi_team_rename(text, text) from public;
grant execute on function public.yawmi_team_rename(text, text) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════ النهاية ════════════════
-- مفتاح المشرف: انسخه واحفظه (تدخل به لوحة الإدارة)
select key as "مفتاح المشرف — احفظه" from public.yawmi_admin;
