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
