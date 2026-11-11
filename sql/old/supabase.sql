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
