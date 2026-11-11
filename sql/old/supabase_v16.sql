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
