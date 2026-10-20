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
create unique index if not exists yawmi_accounts_team_leader on public.yawmi_accounts (team_leader) where team_leader is not null;

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
