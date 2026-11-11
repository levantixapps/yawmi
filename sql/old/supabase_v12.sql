-- يومي: التحديث الثاني عشر — كل مستخدم ينشئ فريقه ورابط دعوته بنفسه
-- شغّل هذا الملف مرة واحدة بعد supabase_v11.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) من التطبيق: ⚙ ← الحسابات ← «أنشئ فريقًا»: يصبح صاحب الحساب مسؤول الفريق، ويُضاف حساب الفريق إلى جهازه.
--    (حتى ١٠ فرق لكل شخص.)
-- ٢) مسؤول الفريق ينشئ رابط دعوة من داخل حساب الفريق (من ساعة إلى ٧ أيام) أو يوقفه.
-- ٣) المشرف يبقى يرى كل الفرق ويديرها من لوحته كما في v11.

-- فريق جديد: p_key مفتاح الحساب الشخصي (المسؤول الأول فيه)
create or replace function public.yawmi_team_create(p_key text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare c text; n int; t text;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 or coalesce(trim(p_name), '') = '' then return null; end if;
  if exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null) then return null; end if;
  if (select count(*) from public.yawmi_accounts where team_leader = c) >= 10 then return json_build_object('err', 'limit'); end if;
  t := public.yawmi_create();
  update public.yawmi_accounts set team_leader = c, team_name = left(trim(p_name), 40), team_taken = true,
    uname = (select uname from public.yawmi_accounts where code = c) where code = t;
  return json_build_object('kind', 'lead', 'key', t, 'num', 1, 'team', public.yawmi_short(t), 'name', public.yawmi_team_title(t));
end; $$;

-- معلومات الفريق لمسؤوله: p_key كود حساب الفريق (null إن لم يكن حساب فريق)
create or replace function public.yawmi_team_info(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare r json;
begin
  select json_build_object('name', public.yawmi_team_title(t.code),
    'invite', case when t.invite_until > now() then t.invite_token end,
    'invite_until', case when t.invite_until > now() then t.invite_until end) into r
  from public.yawmi_accounts t where t.code = p_key and t.team_leader is not null;
  return r;
end; $$;

-- رابط الدعوة من مسؤول الفريق: p_hours ساعة (حتى ٧ أيام)، أو 0 لإيقافه
create or replace function public.yawmi_team_link(p_key text, p_hours int)
returns text language plpgsql security definer set search_path = public as $$
declare tk text;
begin
  if not exists (select 1 from public.yawmi_accounts where code = p_key and team_leader is not null) then return null; end if;
  if coalesce(p_hours, 0) <= 0 then
    update public.yawmi_accounts set invite_token = null, invite_until = null where code = p_key;
    return '';
  end if;
  loop
    tk := public.yawmi_rand(12);
    exit when not exists (select 1 from public.yawmi_accounts where invite_token = tk);
  end loop;
  update public.yawmi_accounts set invite_token = tk, invite_until = now() + make_interval(hours => least(p_hours, 168)) where code = p_key;
  return tk;
end; $$;

revoke all on function public.yawmi_team_create(text, text) from public;
revoke all on function public.yawmi_team_info(text) from public;
revoke all on function public.yawmi_team_link(text, int) from public;
grant execute on function public.yawmi_team_create(text, text) to anon, authenticated;
grant execute on function public.yawmi_team_info(text) to anon, authenticated;
grant execute on function public.yawmi_team_link(text, int) to anon, authenticated;

notify pgrst, 'reload schema';
