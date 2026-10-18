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
