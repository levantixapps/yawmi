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
