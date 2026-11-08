-- يومي: التحديث التاسع والعشرون — تغيير اسم الفريق أو الحساب المشترك
-- شغّل هذا الملف مرة واحدة بعد supabase_v28.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- كان الاسم يتغير على جهاز المسؤول فقط، ويبقى القديم في السحابة، فيظهر في «جدولي» والدعوة ولدى الأعضاء.
-- مسؤول الفريق وحده (رقم ١) يغيّره. لا جداول جديدة.

create or replace function public.yawmi_team_rename(p_key text, p_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; nm text := left(trim(coalesce(p_name, '')), 40);
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or n <> 1 or nm = '' then return false; end if;
  update public.yawmi_accounts set team_name = nm where code = c and team_leader is not null;
  return found;
end; $$;
revoke all on function public.yawmi_team_rename(text, text) from public;
grant execute on function public.yawmi_team_rename(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
