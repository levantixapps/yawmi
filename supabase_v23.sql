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
