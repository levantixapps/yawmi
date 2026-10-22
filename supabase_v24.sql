-- يومي: التحديث الرابع والعشرون — تاريخ المعاملة وموعدها النهائي، وتنزيل المعاملات عند تغيّرها فقط
-- شغّل هذا الملف مرة واحدة بعد supabase_v23.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- ١) لكل معاملة تاريخ اختياري (مثل تاريخ الكتاب الوارد) وموعد نهائي اختياري للمعاملة كلها.
-- ٢) «ختم» المعاملات: يسأل التطبيق أولًا هل تغيّر شيء (بضعة بايتات)، ولا ينزّل القائمة إلا إن تغيّرت.

alter table public.yawmi_flows add column if not exists doc_date date;
alter table public.yawmi_flows add column if not exists due date;

-- الختم: آخر تعديل وعدد المعاملات الظاهرة، أو null إن لم يكن فريقًا
create or replace function public.yawmi_flows_stamp(p_key text)
returns text language plpgsql security definer set search_path = public as $$
declare w record; r text;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null then return null; end if;
  select coalesce(max(f.updated_at)::text, '-') || '#' || count(*) into r
  from public.yawmi_flows f where f.team = w.r_team and (f.status = 'open' or f.updated_at > now() - interval '30 days');
  return r;
end; $$;

create or replace function public.yawmi_flows_list(p_key text)
returns json language plpgsql security definer set search_path = public as $$
declare w record;
begin
  select * into w from public.yawmi_flow_who(p_key);
  if w.r_team is null then return null; end if;
  return (select coalesce(json_agg(json_build_object('id', f.id, 'no', f.no, 'title', f.title, 'ref', f.ref, 'steps', f.steps, 'pos', f.pos,
      'status', f.status, 'days', f.days, 'doc_date', f.doc_date, 'due', f.due, 'step_at', f.step_at, 'created_at', f.created_at, 'updated_at', f.updated_at, 'log', f.log)
      order by (f.status = 'open') desc, f.updated_at desc), '[]'::json)
    from public.yawmi_flows f where f.team = w.r_team and (f.status = 'open' or f.updated_at > now() - interval '30 days'));
end; $$;

-- التسجيل (v20) مع التاريخين
create or replace function public.yawmi_flow_new(p_key text, p_title text, p_ref text, p_steps jsonb, p_days int, p_doc date, p_due date)
returns bigint language plpgsql security definer set search_path = public as $$
declare i bigint;
begin
  i := public.yawmi_flow_new(p_key, p_title, p_ref, p_steps, p_days);
  if i is not null then update public.yawmi_flows set doc_date = p_doc, due = p_due where id = i; end if;
  return i;
end; $$;

revoke all on function public.yawmi_flows_stamp(text) from public;
revoke all on function public.yawmi_flow_new(text, text, text, jsonb, int, date, date) from public;
grant execute on function public.yawmi_flows_stamp(text) to anon, authenticated;
grant execute on function public.yawmi_flow_new(text, text, text, jsonb, int, date, date) to anon, authenticated;

notify pgrst, 'reload schema';
