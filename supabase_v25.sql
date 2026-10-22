-- يومي: التحديث الخامس والعشرون — لوحة المشرف تعرض نوع كل حساب وصاحبه وأجهزته
-- شغّل هذا الملف مرة واحدة بعد supabase_v24.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- قائمة «الأشخاص» كانت تخلط الأشخاص بحساباتهم الشخصية الأخرى (مثل «العمل»). الآن لكل حساب:
-- kind: person (شخص) أو own (حساب آخر لشخص، مع اسمه واسم صاحبه)، وعدد أجهزة الشخص (my_devices).
-- والشخص بلا اسم ولا أجهزة: حساب أُنشئ ولم يُستعمل (مثل جهاز رُبط بعدها بحساب آخر)، ويحذفه التنظيف بعد ٣٠ يومًا.

create or replace function public.yawmi_admin_accounts(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(x order by x.updated_at desc), '[]'::json) from (
    select public.yawmi_short(a.code) as id, a.uname as name, a.label, a.created_at, a.updated_at,
           pg_column_size(a.*) as bytes,
           case when a.owner is not null then 'own' else 'person' end as kind,
           a.pname, (select o.uname from public.yawmi_accounts o where o.code = a.owner) as owner_name,
           case when a.owner is not null then public.yawmi_short(a.owner) end as owner_id,
           (select count(*) from public.yawmi_my_devices m where m.person = a.code and not m.revoked) as my_devices,
           (select count(*) from public.yawmi_devices d where d.code = a.code) as devices,
           (select max(d.last_seen) from public.yawmi_devices d where d.code = a.code) as devices_seen,
           (select count(*) from public.yawmi_push p where p.code = a.code) as push,
           (select t.updated_at from public.yawmi_accounts t where t.team_leader = a.code) as team_seen,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(m.member), 'name', ma.uname, 'num', d.num, 'label', d.label, 'seen', d.last_seen, 'taken', m.taken) order by d.num), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts t on t.code = m.team and t.team_leader = a.code
            join public.yawmi_accounts ma on ma.code = m.member
            join public.yawmi_devices d on d.token = m.token) as members,
           (select coalesce(json_agg(json_build_object('id', public.yawmi_short(t.team_leader), 'name', la.uname)), '[]'::json)
            from public.yawmi_team_members m
            join public.yawmi_accounts t on t.code = m.team
            join public.yawmi_accounts la on la.code = t.team_leader
            where m.member = a.code) as leaders
    from public.yawmi_accounts a where a.team_leader is null) x);
end; $$;

notify pgrst, 'reload schema';
