-- يومي: التحديث الحادي والعشرون — إصلاح تسجيل المعاملات («column reference "r_num" is ambiguous»)
-- شغّل هذا الملف مرة واحدة بعد supabase_v20.sql من: Supabase ← SQL Editor ← New query ← Run.

create or replace function public.yawmi_flow_who(p_key text, out r_team text, out r_num int)
language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or not exists (select 1 from public.yawmi_accounts where code = c and team_leader is not null and team_kind = 'team') then return; end if;
  r_team := c; r_num := n;
end; $$;
revoke all on function public.yawmi_flow_who(text) from public, anon, authenticated;

notify pgrst, 'reload schema';
