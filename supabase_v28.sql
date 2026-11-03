-- يومي: التحديث الثامن والعشرون — إشعار لمن سجّل المعاملة حين تنتهي أو تُرفض
-- شغّل هذا الملف مرة واحدة بعد supabase_v27.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- قبل هذا التحديث كان الإشعار يصل فقط لصاحب الخطوة التالية، فإن أُنجزت المعاملة أو رُفضت لم يصل شيء.
-- الآن يصل لمن سجّلها (أول سطر في سجلها): «✅ انتهت المعاملة» أو «❌ رُفضت المعاملة»، ومعه اسم من أنهاها أو رفضها.

create or replace function public.yawmi_flow_ping(p_id bigint, p_from text)
returns void language plpgsql security definer set search_path = public as $$
declare f public.yawmi_flows; r text; starter int;
begin
  select * into f from public.yawmi_flows where id = p_id;
  if f.id is null then return; end if;
  if f.status = 'open' then
    r := f.steps->>f.pos;
    insert into public.yawmi_flow_pings (endpoint, sub, title, body, tag)
    select p.endpoint, p.sub, '📨 معاملة وصلتك: ' || left(f.title, 60), 'رقم ' || f.no || ' · من ' || coalesce(p_from, ''), 'flow:' || f.id || ':' || f.pos
    from public.yawmi_push p, public.yawmi_accounts a
    where p.code = f.team and a.code = f.team and p.seen > now() - interval '3 days'
      and p.num is not null and nullif(trim(a.settings->'roles'->>(p.num::text)), '') = r;
    return;
  end if;
  -- finished or rejected: tell the one who registered it
  starter := nullif(f.log->0->>'n', '')::int;
  if starter is null then return; end if;
  insert into public.yawmi_flow_pings (endpoint, sub, title, body, tag)
  select p.endpoint, p.sub,
         case when f.status = 'done' then '✅ انتهت المعاملة: ' else '❌ رُفضت المعاملة: ' end || left(f.title, 60),
         'رقم ' || f.no || ' · ' || case when f.status = 'done' then 'أنهاها ' else 'رفضها ' end || coalesce(p_from, ''),
         'flow:' || f.id || ':end'
  from public.yawmi_push p
  where p.code = f.team and p.num = starter and p.seen > now() - interval '3 days';
end; $$;
revoke all on function public.yawmi_flow_ping(bigint, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
