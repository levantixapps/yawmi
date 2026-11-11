-- يومي: التحديث الثامن عشر — الجهاز الأساسي، ورابط ربط الجهاز
-- شغّل هذا الملف مرة واحدة بعد supabase_v17.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) لكل شخص جهاز أساسي ⭐ (أول جهاز سُجّل له): وحده يضيف الأجهزة ويزيلها، ولا يُزال هو.
--    ويستطيع أن يجعل جهازًا آخر هو الأساسي.
-- ٢) رابط ربط: الجهاز الأساسي يرسل رابطًا (مرة واحدة، ١٠ دقائق)، فمن فتحه على جهازه الجديد رُبط مباشرة.

alter table public.yawmi_my_devices add column if not exists is_main boolean not null default false;

-- لكل شخص ليس له جهاز أساسي: أقدم أجهزته الفعّالة
create or replace function public.yawmi_main_fix(p_person text)
returns void language sql security definer set search_path = public as $$
  update public.yawmi_my_devices d set is_main = true
  where d.person = p_person and not d.revoked
    and not exists (select 1 from public.yawmi_my_devices m where m.person = p_person and m.is_main and not m.revoked)
    and d.dev = (select x.dev from public.yawmi_my_devices x where x.person = p_person and not x.revoked order by x.created_at limit 1);
$$;
revoke all on function public.yawmi_main_fix(text) from public, anon, authenticated;
select public.yawmi_main_fix(p) from (select distinct person as p from public.yawmi_my_devices) s;

-- هل هذا الجهاز هو الأساسي؟
create or replace function public.yawmi_is_main(p_person text, p_dev text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.yawmi_my_devices where person = p_person and dev = p_dev and is_main and not revoked);
$$;
revoke all on function public.yawmi_is_main(text, text) from public, anon, authenticated;

-- عند كل فتح (v16) + هل هو الأساسي
create or replace function public.yawmi_me(p_key text, p_dev text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); rv boolean;
begin
  if c is null or coalesce(p_dev, '') = '' then return null; end if;
  select revoked into rv from public.yawmi_my_devices where person = c and dev = left(p_dev, 40);
  if rv then return json_build_object('revoked', true); end if;
  insert into public.yawmi_my_devices (person, dev, label) values (c, left(p_dev, 40), left(nullif(trim(p_label), ''), 40))
  on conflict (person, dev) do update set last_seen = now(), label = coalesce(excluded.label, public.yawmi_my_devices.label);
  perform public.yawmi_main_fix(c);
  return json_build_object('accounts', public.yawmi_my_accounts(c), 'uname', (select uname from public.yawmi_accounts where code = c),
    'main', public.yawmi_is_main(c, left(p_dev, 40)));
end; $$;

create or replace function public.yawmi_my_devices_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  return (select coalesce(json_agg(json_build_object('dev', d.dev, 'label', d.label, 'main', d.is_main, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.is_main desc, d.created_at), '[]'::json)
    from public.yawmi_my_devices d where d.person = c and not d.revoked);
end; $$;

-- الإزالة من الجهاز الأساسي فقط، ولا يُزال الأساسي
drop function if exists public.yawmi_my_device_remove(text, text);
create or replace function public.yawmi_my_device_remove(p_key text, p_dev text, p_me text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or not public.yawmi_is_main(c, p_me) or p_dev = p_me then return false; end if;
  update public.yawmi_my_devices set revoked = true, is_main = false where person = c and dev = p_dev;
  return found;
end; $$;

-- الأساسي يجعل جهازًا آخر هو الأساسي
create or replace function public.yawmi_my_device_main(p_key text, p_dev text, p_me text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null or not public.yawmi_is_main(c, p_me) then return false; end if;
  if not exists (select 1 from public.yawmi_my_devices where person = c and dev = p_dev and not revoked) then return false; end if;
  update public.yawmi_my_devices set is_main = (dev = p_dev) where person = c;
  return true;
end; $$;

-- الموافقة على رمز الجهاز الجديد: من الأساسي فقط (notmain)
drop function if exists public.yawmi_mine_approve(text, text);
create or replace function public.yawmi_mine_approve(p_token text, p_key text, p_me text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key);
begin
  if c is null then return null; end if;
  if not public.yawmi_is_main(c, p_me) then return 'notmain'; end if;
  if public.yawmi_my_count(c) >= (select max_devices from public.yawmi_accounts where code = c) then return 'limit'; end if;
  update public.yawmi_link_requests set code = c
  where token = p_token and kind = 'mine' and code is null and created_at > now() - interval '10 minutes';
  return case when found then 'ok' end;
end; $$;

-- رابط ربط من الأساسي: رمز موافَق عليه مسبقًا، يأخذه الجهاز الجديد بـ yawmi_mine_take
create or replace function public.yawmi_mine_link(p_key text, p_me text)
returns text language plpgsql security definer set search_path = public as $$
declare c text := public.yawmi_person(p_key); t text;
begin
  if c is null then return null; end if;
  if not public.yawmi_is_main(c, p_me) then return 'notmain'; end if;
  if public.yawmi_my_count(c) >= (select max_devices from public.yawmi_accounts where code = c) then return 'limit'; end if;
  delete from public.yawmi_link_requests where created_at < now() - interval '10 minutes';
  loop
    t := public.yawmi_rand(12);
    exit when not exists (select 1 from public.yawmi_link_requests where token = t);
  end loop;
  insert into public.yawmi_link_requests (token, code, kind) values (t, c, 'mine');
  return t;
end; $$;

-- الأخذ (v16) مع صلاحية ١٠ دقائق
create or replace function public.yawmi_mine_take(p_token text, p_dev text, p_label text)
returns json language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if coalesce(p_dev, '') = '' then return null; end if;
  delete from public.yawmi_link_requests where token = p_token and kind = 'mine' and code is not null and created_at > now() - interval '10 minutes'
  returning code into c;
  if c is null then return null; end if;
  insert into public.yawmi_my_devices (person, dev, label) values (c, left(p_dev, 40), left(nullif(trim(p_label), ''), 40))
  on conflict (person, dev) do update set revoked = false, last_seen = now(), label = coalesce(excluded.label, public.yawmi_my_devices.label);
  perform public.yawmi_main_fix(c);
  return json_build_object('key', c, 'uname', (select uname from public.yawmi_accounts where code = c));
end; $$;

revoke all on function public.yawmi_my_device_remove(text, text, text) from public;
revoke all on function public.yawmi_my_device_main(text, text, text) from public;
revoke all on function public.yawmi_mine_approve(text, text, text) from public;
revoke all on function public.yawmi_mine_link(text, text) from public;
grant execute on function public.yawmi_my_device_remove(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_my_device_main(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_mine_approve(text, text, text) to anon, authenticated;
grant execute on function public.yawmi_mine_link(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

select left(md5(person), 6) as "الشخص", label as "الجهاز", is_main as "أساسي", revoked as "أُزيل", last_seen as "آخر ظهور"
from public.yawmi_my_devices order by person, created_at;
