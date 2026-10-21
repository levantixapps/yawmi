-- يومي: التحديث التاسع عشر — «ابدأ من جديد»: تصفير الحساب على كل أجهزته
-- شغّل هذا الملف مرة واحدة بعد supabase_v18.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- يحذف أيام الحساب ومهامه وتقاريره (واختياريًا إعداداته) من السحابة، ويضع «وقت التصفير» reset_at،
-- فكل جهاز يرى وقتًا أحدث مما يعرفه يمسح نسخته هو أيضًا (حتى لا يعيد رفع القديم).
-- من يستطيع: الحساب الشخصي وحسابات الشخص الأخرى من جهازه الأساسي ⭐، والفريق والحساب المشترك من مسؤوله.

alter table public.yawmi_accounts add column if not exists reset_at timestamptz;
alter table public.yawmi_accounts add column if not exists reset_set boolean not null default false;

-- الجلب (v15) + وقت التصفير
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
    'num', n, 'stamp', a.updated_at, 'reset_at', a.reset_at, 'reset_set', a.reset_set
  ) into r from public.yawmi_accounts a where a.code = c;
  return r;
end; $$;

-- التصفير: يعيد وقته، أو null إن لم يكن مسموحًا
create or replace function public.yawmi_reset(p_key text, p_dev text, p_settings boolean)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare c text; n int; l text; o text; ok boolean; t timestamptz := now();
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or n <> 1 then return null; end if;
  select team_leader, owner into l, o from public.yawmi_accounts where code = c;
  if l is not null then ok := true; -- فريق أو حساب مشترك: مسؤوله يحمل كوده
  elsif o is not null then ok := public.yawmi_is_main(o, p_dev);
  else ok := public.yawmi_is_main(c, p_dev) or not exists (select 1 from public.yawmi_my_devices where person = c and not revoked);
  end if;
  if not ok then return null; end if;
  update public.yawmi_accounts set
    day_m3 = null, day_m2 = null, day_m1 = null, day_0 = null, day_p1 = null, day_p2 = null, day_p3 = null,
    settings = case when p_settings then null else settings end,
    reset_at = t, reset_set = coalesce(p_settings, false), updated_at = t
  where code = c;
  update public.yawmi_devices set changes = null where code = c;
  return t;
end; $$;
revoke all on function public.yawmi_reset(text, text, boolean) from public;
grant execute on function public.yawmi_reset(text, text, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
