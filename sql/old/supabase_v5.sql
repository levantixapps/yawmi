-- يومي: التحديث الخامس — سجل التغييرات في خانة واحدة لكل مستخدم ثانوي
-- شغّل هذا الملف مرة واحدة بعد supabase_v4.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- • يُحذف جدول yawmi_log.
-- • لكل جهاز ثانوي خانة واحدة (yawmi_devices.changes) تُضاف إليها تغييراته سطرًا تحت سطر،
--   مثل: «19/10 08:42 — حذف «دراسة جغرافية» (ليوم 19/10)». للاطلاع فقط.
-- • تحتفظ الخانة بآخر ٣٠٠ سطر، والأقدم يُحذف تلقائيًا.

alter table public.yawmi_devices add column if not exists changes text;

drop function if exists public.yawmi_log_list(text);
drop table if exists public.yawmi_log;

-- يضيف سطور التغييرات إلى خانة الجهاز الثانوي (تغييرات المسؤول الأول لا تُسجَّل)
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
    exit when k > 100;
    if jsonb_typeof(e) = 'string' then
      lines := lines || left(replace(e #>> '{}', E'\n', ' '), 200);
    elsif jsonb_typeof(e) = 'object' then
      lines := lines || left(trim(coalesce(e->>'action', '') || ' «' || coalesce(e->>'title', '') || '»'), 200);
    end if;
  end loop;
  select coalesce(string_to_array(nullif(changes, ''), E'\n'), '{}') into cur from public.yawmi_devices where token = p_code;
  cur := cur || lines;
  if array_length(cur, 1) > 300 then
    cur := cur[array_length(cur, 1) - 299 : array_length(cur, 1)];
  end if;
  update public.yawmi_devices set changes = array_to_string(cur, E'\n') where token = p_code;
  return true;
end; $$;

-- قائمة الأجهزة مع اسم صاحب كل جهاز وخانة تغييراته
create or replace function public.yawmi_devices_list(p_code text)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('token', d.token, 'num', d.num, 'label', d.label, 'uname', d.uname, 'changes', d.changes, 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.num), '[]'::json)
  from public.yawmi_devices d
  where d.code = p_code and exists (select 1 from public.yawmi_accounts where code = p_code);
$$;

revoke all on function public.yawmi_log_add(text, jsonb) from public;
grant execute on function public.yawmi_log_add(text, jsonb) to anon, authenticated;
grant execute on function public.yawmi_devices_list(text) to anon, authenticated;

notify pgrst, 'reload schema';
