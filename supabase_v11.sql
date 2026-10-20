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
