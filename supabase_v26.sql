-- يومي: التحديث السادس والعشرون — «معلومة اليوم» في أيام معيّنة
-- شغّل هذا الملف مرة واحدة بعد supabase_v25.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- لكل معلومة جدول اختياري: أيام من الأسبوع (wdays: ٠ الأحد … ٦ السبت)، أو أيام من الشهر الهجري (hdays)
-- مع شهر هجري اختياري (hmonth: ١ محرم … ١٢ ذو الحجة). في تلك الأيام تتقدّم المعلومة المجدولة على المعتادة،
-- وفي غيرها لا تظهر. والمعلومات بلا جدول تدور كما كانت.
-- مثال: تذكير صيام الاثنين والخميس ← الأحد والأربعاء. أيام البيض ← ١٢ و١٣ و١٤. يوم عرفة ← ٨ و٩ من ذي الحجة.

alter table public.yawmi_tips add column if not exists wdays int[];
alter table public.yawmi_tips add column if not exists hdays int[];
alter table public.yawmi_tips add column if not exists hmonth int;

-- المعلومة ليوم: p_hm/p_hd الشهر واليوم الهجريان كما يحسبهما الجهاز (أم القرى)
create or replace function public.yawmi_tip_for(p_day date, p_hm int, p_hd int)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json; dow int := extract(dow from p_day)::int; i int := p_day - date '2026-01-01';
begin
  select count(*) into c from public.yawmi_tips t where t.active
    and ((t.wdays is not null and dow = any(t.wdays)) or (t.hdays is not null and p_hd = any(t.hdays) and (t.hmonth is null or t.hmonth = p_hm)));
  if c > 0 then
    select json_build_object('id', t.id, 'body', t.body, 'source', t.source, 'special', true) into r
    from public.yawmi_tips t where t.active
      and ((t.wdays is not null and dow = any(t.wdays)) or (t.hdays is not null and p_hd = any(t.hdays) and (t.hmonth is null or t.hmonth = p_hm)))
    order by t.id offset ((i % c) + c) % c limit 1;
    return r;
  end if;
  return public.yawmi_tip_for(p_day);
end; $$;

-- المعتادة (v6): تدور على المعلومات بلا جدول فقط
create or replace function public.yawmi_tip_for(p_day date)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json;
begin
  select count(*) into c from public.yawmi_tips where active and wdays is null and hdays is null;
  if c = 0 then return null; end if;
  select json_build_object('id', t.id, 'body', t.body, 'source', t.source) into r
  from public.yawmi_tips t where t.active and t.wdays is null and t.hdays is null
  order by t.id
  offset (((p_day - date '2026-01-01') % c) + c) % c
  limit 1;
  return r;
end; $$;

-- المشرف: إضافة معلومة مجدولة أو تعديل جدولها (مصفوفة فارغة = بلا جدول)
create or replace function public.yawmi_tip_plan(p_admin text, p_id int, p_body text, p_source text, p_wdays int[], p_hdays int[], p_hmonth int)
returns json language plpgsql security definer set search_path = public as $$
declare r public.yawmi_tips; w int[] := nullif(p_wdays, '{}'); h int[] := nullif(p_hdays, '{}');
begin
  if not public.yawmi_admin_check(p_admin) or coalesce(trim(p_body), '') = '' then return null; end if;
  if p_id is null then
    insert into public.yawmi_tips (body, source, wdays, hdays, hmonth)
    values (left(trim(p_body), 600), left(nullif(trim(p_source), ''), 120), w, h, case when h is not null and p_hmonth between 1 and 12 then p_hmonth end) returning * into r;
  else
    update public.yawmi_tips set body = left(trim(p_body), 600), source = left(nullif(trim(p_source), ''), 120),
      wdays = w, hdays = h, hmonth = case when h is not null and p_hmonth between 1 and 12 then p_hmonth end, active = true, updated_at = now()
    where id = p_id returning * into r;
  end if;
  return json_build_object('id', r.id, 'body', r.body, 'source', r.source);
end; $$;

-- المشرف: المعلومات المجدولة المفعّلة
create or replace function public.yawmi_admin_tips(p_admin text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return null; end if;
  return (select coalesce(json_agg(json_build_object('id', t.id, 'body', t.body, 'source', t.source, 'wdays', t.wdays, 'hdays', t.hdays, 'hmonth', t.hmonth) order by t.id), '[]'::json)
    from public.yawmi_tips t where t.active and (t.wdays is not null or t.hdays is not null));
end; $$;

revoke all on function public.yawmi_tip_for(date, int, int) from public;
revoke all on function public.yawmi_tip_plan(text, int, text, text, int[], int[], int) from public;
revoke all on function public.yawmi_admin_tips(text) from public;
grant execute on function public.yawmi_tip_for(date, int, int) to anon, authenticated;
grant execute on function public.yawmi_tip_plan(text, int, text, text, int[], int[], int) to anon, authenticated;
grant execute on function public.yawmi_admin_tips(text) to anon, authenticated;

-- أمثلة جاهزة (تُضاف مرة واحدة)
insert into public.yawmi_tips (body, source, wdays)
select 'غدًا يوم تُعرض فيه الأعمال، فانوِ صيامه إن استطعت: «تُعرض الأعمال يوم الاثنين والخميس، فأحب أن يُعرض عملي وأنا صائم».', 'رواه الترمذي', '{0,3}'
where not exists (select 1 from public.yawmi_tips where wdays = '{0,3}');
insert into public.yawmi_tips (body, source, hdays)
select 'أيام البيض: ١٣ و١٤ و١٥ من الشهر الهجري، يُستحب صيامها. قال ﷺ: «صوم ثلاثة أيام من كل شهر صوم الدهر كله».', 'رواه البخاري ومسلم', '{12,13,14}'
where not exists (select 1 from public.yawmi_tips where hdays = '{12,13,14}' and hmonth is null);

notify pgrst, 'reload schema';
