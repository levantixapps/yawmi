-- يومي: التحديث الثاني والعشرون — «👑 اجعله المسؤول»: نقل مسؤولية الفريق أو الحساب المشترك إلى عضو
-- شغّل هذا الملف مرة واحدة بعد supabase_v21.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- العضو (ممن انضم برابط الدعوة) يصبح المسؤول، والمسؤول السابق يصبح عضوًا. وتنتقل الأدوار في المعاملات مع أصحابها:
-- المسؤول دائمًا رقم ١، فيأخذ الجديد دور رقم ١، ويأخذ السابق رقمه الجديد بدوره القديم.
-- كل جهاز يبدّل الحساب عند تحققه التالي (yawmi_me).

create or replace function public.yawmi_team_handover(p_key text, p_num int)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int; l text; m text; tk text; nt text; nn int; ro jsonb; r jsonb;
begin
  select x.r_code, x.r_num into c, n from public.yawmi_resolve(p_key) x;
  if c is null or n <> 1 then return false; end if;
  select team_leader, settings->'roles' into l, ro from public.yawmi_accounts where code = c;
  if l is null then return false; end if;
  select tm.member, tm.token into m, tk
  from public.yawmi_team_members tm join public.yawmi_devices d on d.token = tm.token
  where tm.team = c and d.num = p_num;
  if m is null or m = l then return false; end if; -- عضو بالطريقة القديمة (بلا شخص) لا يُنقل إليه
  delete from public.yawmi_devices where token = tk; -- يحذف عضويته معه
  update public.yawmi_accounts set team_leader = m, team_taken = true, uname = (select uname from public.yawmi_accounts where code = m) where code = c;
  nt := public.yawmi_team_add_member(c, l);
  update public.yawmi_team_members set taken = true where team = c and member = l;
  select num into nn from public.yawmi_devices where token = nt;
  if ro is not null and jsonb_typeof(ro) = 'object' then
    r := ro - '1' - (p_num::text);
    if ro ? (p_num::text) then r := r || jsonb_build_object('1', ro->(p_num::text)); end if;
    if ro ? '1' then r := r || jsonb_build_object(nn::text, ro->'1'); end if;
    update public.yawmi_accounts set settings = jsonb_set(jsonb_set(settings, '{roles}', r), '{updatedAt}', to_jsonb((extract(epoch from now()) * 1000)::bigint)),
      updated_at = now() where code = c;
  end if;
  return true;
end; $$;
revoke all on function public.yawmi_team_handover(text, int) from public;
grant execute on function public.yawmi_team_handover(text, int) to anon, authenticated;

notify pgrst, 'reload schema';
