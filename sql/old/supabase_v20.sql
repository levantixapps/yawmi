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
