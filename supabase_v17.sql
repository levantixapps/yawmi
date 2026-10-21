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
