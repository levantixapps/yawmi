-- يومي: التحديث السادس — إشعارات حتى والتطبيق مغلق + معلومة اليوم
-- شغّل هذا الملف مرة واحدة بعد supabase_v5.sql من: Supabase ← SQL Editor ← New query ← Run.
-- في آخر التشغيل يظهر «مفتاح المشرف»: احفظه، فبه تعدّل معلومة اليوم من داخل التطبيق.

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- =====================================================================
-- 1) الإشعارات (Web Push)
-- =====================================================================
-- اشتراك كل جهاز في الإشعارات، مربوط بحسابه
create table if not exists public.yawmi_push (
  endpoint   text primary key,
  code       text not null references public.yawmi_accounts(code) on delete cascade,
  sub        jsonb not null,
  tz         int  not null default 180,  -- فرق التوقيت عن UTC بالدقائق
  lead_min   int  not null default 0,    -- التنبيه قبل الموعد بكم دقيقة
  created_at timestamptz not null default now()
);
-- ما أُرسل، حتى لا يتكرر الإشعار (يُحذف بعد يومين)
create table if not exists public.yawmi_push_sent (
  endpoint text not null,
  tag      text not null,
  at       timestamptz not null default now(),
  primary key (endpoint, tag)
);
alter table public.yawmi_push      enable row level security;
alter table public.yawmi_push_sent enable row level security;
revoke all on public.yawmi_push, public.yawmi_push_sent from anon, authenticated;

-- الجهاز يسجّل اشتراكه (بمفتاحه: الكود الرئيسي أو رقمه الثانوي)
create or replace function public.yawmi_push_save(p_key text, p_sub jsonb, p_tz int, p_lead int)
returns boolean language plpgsql security definer set search_path = public as $$
declare c text; n int;
begin
  select r_code, r_num into c, n from public.yawmi_resolve(p_key);
  if c is null or coalesce(p_sub->>'endpoint', '') !~ '^https://' then return false; end if;
  insert into public.yawmi_push (endpoint, code, sub, tz, lead_min)
  values (p_sub->>'endpoint', c, p_sub, greatest(-720, least(840, coalesce(p_tz, 180))), greatest(0, least(60, coalesce(p_lead, 0))))
  on conflict (endpoint) do update
    set code = excluded.code, sub = excluded.sub, tz = excluded.tz, lead_min = excluded.lead_min;
  return true;
end; $$;

create or replace function public.yawmi_push_delete(p_endpoint text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from public.yawmi_push where endpoint = p_endpoint;
  return found;
end; $$;

-- المهام التي حان موعدها الآن لكل مشترك (تستدعيها دالة الإرسال فقط)
create or replace function public.yawmi_push_due()
returns table (endpoint text, sub jsonb, title text, body text, tag text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
begin
  delete from public.yawmi_push_sent s0 where s0.at < now() - interval '2 days';
  return query
  with s as (
    select p.endpoint, p.sub, p.lead_min,
           (now() at time zone 'UTC') + make_interval(mins => p.tz) as lt,
           array[a.day_m3, a.day_m2, a.day_m1, a.day_0, a.day_p1, a.day_p2, a.day_p3] as days
    from public.yawmi_push p
    join public.yawmi_accounts a on a.code = p.code
  ), d as (
    select s.endpoint, s.sub, s.lead_min, s.lt, dd as day
    from s, unnest(s.days) dd
    where dd is not null and dd->>'date' = to_char(s.lt, 'YYYY-MM-DD')
  ), it as (
    select d.endpoint, d.sub, d.lead_min, d.lt, d.day->>'date' as dday, i
    from d, jsonb_array_elements(coalesce(d.day->'items', '[]'::jsonb)) i
    where coalesce(i->>'time', '') ~ '^\d{2}:\d{2}$'
      and coalesce(i->>'done', 'false') <> 'true'
      and coalesce(i->>'moved', 'false') <> 'true'
      and not (coalesce(i->>'important', '') = 'false' and coalesce(i->>'urgent', '') = 'false')
  ), due as (
    select it.*,
           split_part(it.i->>'time', ':', 1)::int * 60 + split_part(it.i->>'time', ':', 2)::int - it.lead_min as at_min,
           extract(hour from it.lt)::int * 60 + extract(minute from it.lt)::int as now_min
    from it
  ), pick as (
    select due.endpoint, due.sub,
           (case when due.lead_min > 0 then 'بعد ' || due.lead_min || ' دقائق: ' else '⏰ حان الوقت: ' end || coalesce(due.i->>'title', '')) as title,
           ('الساعة ' || (due.i->>'time')) as body,
           (due.dday || ':' || coalesce(due.i->>'id', '') || ':' || (due.i->>'time') || ':' || due.lead_min) as tag
    from due
    where due.now_min between due.at_min and due.at_min + 2
  ), ins as (
    insert into public.yawmi_push_sent (endpoint, tag)
    select pick.endpoint, pick.tag from pick
    on conflict do nothing
    returning yawmi_push_sent.endpoint, yawmi_push_sent.tag
  )
  select pick.endpoint, pick.sub, pick.title, pick.body, pick.tag
  from pick join ins on ins.endpoint = pick.endpoint and ins.tag = pick.tag;
end; $$;

revoke all on function public.yawmi_push_save(text, jsonb, int, int) from public;
revoke all on function public.yawmi_push_delete(text) from public;
revoke all on function public.yawmi_push_due() from public, anon, authenticated;
grant execute on function public.yawmi_push_save(text, jsonb, int, int) to anon, authenticated;
grant execute on function public.yawmi_push_delete(text) to anon, authenticated;
grant execute on function public.yawmi_push_due() to service_role;

-- فحص كل دقيقة: يستدعي دالة الإرسال yawmi-push
do $$
begin
  if exists (select 1 from cron.job where jobname = 'yawmi-push') then
    perform cron.unschedule('yawmi-push');
  end if;
end $$;
select cron.schedule('yawmi-push', '* * * * *', $cron$
  select net.http_post(
    url := 'https://nkcngzsjevgzurwxkjqn.supabase.co/functions/v1/yawmi-push',
    headers := '{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5rY25nenNqZXZnenVyd3hranFuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU3NTQyMTEsImV4cCI6MjEwMTMzMDIxMX0.2UlqfEPT-TCBGnIfHqn1sArX1AOkhRr6zvnQt4evD0U"}'::jsonb,
    body := '{}'::jsonb
  );
$cron$);

-- =====================================================================
-- 2) معلومة اليوم (يراها كل مستخدمي التطبيق، ويعدّلها المشرف)
-- =====================================================================
create table if not exists public.yawmi_tips (
  id         serial primary key,
  body       text not null,
  source     text,
  active     boolean not null default true,
  updated_at timestamptz not null default now()
);
create table if not exists public.yawmi_admin (key text primary key);
alter table public.yawmi_tips  enable row level security;
alter table public.yawmi_admin enable row level security;
revoke all on public.yawmi_tips, public.yawmi_admin from anon, authenticated;

insert into public.yawmi_admin (key)
select public.yawmi_rand(16) where not exists (select 1 from public.yawmi_admin);

-- معلومة يوم معيّن: تدور على المعلومات المفعّلة بالترتيب، يومًا بعد يوم
create or replace function public.yawmi_tip_for(p_day date)
returns json language plpgsql security definer set search_path = public as $$
declare c int; r json;
begin
  select count(*) into c from public.yawmi_tips where active;
  if c = 0 then return null; end if;
  select json_build_object('id', t.id, 'body', t.body, 'source', t.source) into r
  from public.yawmi_tips t where t.active
  order by t.id
  offset (((p_day - date '2026-01-01') % c) + c) % c
  limit 1;
  return r;
end; $$;

create or replace function public.yawmi_admin_check(p_admin text)
returns boolean language sql security definer set search_path = public as $$
  select exists (select 1 from public.yawmi_admin where key = p_admin);
$$;

-- المشرف: إضافة معلومة (p_id فارغ) أو تعديلها
create or replace function public.yawmi_tip_save(p_admin text, p_id int, p_body text, p_source text)
returns json language plpgsql security definer set search_path = public as $$
declare r public.yawmi_tips;
begin
  if not public.yawmi_admin_check(p_admin) or coalesce(trim(p_body), '') = '' then return null; end if;
  if p_id is null then
    insert into public.yawmi_tips (body, source) values (left(trim(p_body), 600), left(nullif(trim(p_source), ''), 120)) returning * into r;
  else
    update public.yawmi_tips set body = left(trim(p_body), 600), source = left(nullif(trim(p_source), ''), 120), updated_at = now()
    where id = p_id returning * into r;
  end if;
  return json_build_object('id', r.id, 'body', r.body, 'source', r.source);
end; $$;

-- المشرف: إيقاف معلومة (لا تُحذف، فلا يختل ترتيب الأيام إلا بقدرها)
create or replace function public.yawmi_tip_hide(p_admin text, p_id int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.yawmi_admin_check(p_admin) then return false; end if;
  update public.yawmi_tips set active = false, updated_at = now() where id = p_id;
  return found;
end; $$;

revoke all on function public.yawmi_tip_for(date) from public;
revoke all on function public.yawmi_admin_check(text) from public;
revoke all on function public.yawmi_tip_save(text, int, text, text) from public;
revoke all on function public.yawmi_tip_hide(text, int) from public;
grant execute on function public.yawmi_tip_for(date) to anon, authenticated;
grant execute on function public.yawmi_admin_check(text) to anon, authenticated;
grant execute on function public.yawmi_tip_save(text, int, text, text) to anon, authenticated;
grant execute on function public.yawmi_tip_hide(text, int) to anon, authenticated;

-- معلومات أولية (تُضاف مرة واحدة فقط إن كان الجدول فارغًا)
insert into public.yawmi_tips (body, source)
select v.body, v.source from (values
  ('«نعمتان مغبون فيهما كثير من الناس: الصحة والفراغ».', 'صحيح البخاري'),
  ('«اللهم بارك لأمتي في بكورها». أفضل ساعات العمل والحفظ هي ساعات الصباح الأولى.', 'سنن أبي داود والترمذي'),
  ('«أحب الأعمال إلى الله أدومها وإن قل». صفحة يوميًا خير من عشر صفحات مرة في الأسبوع.', 'صحيح البخاري ومسلم'),
  ('﴿وَالْعَصْرِ ۝ إِنَّ الْإِنسَانَ لَفِي خُسْرٍ﴾. أقسم الله بالوقت لعظيم قيمته.', 'سورة العصر'),
  ('﴿فَإِذَا فَرَغْتَ فَانصَبْ﴾: إذا انتهيت من عمل فابدأ بالذي بعده.', 'سورة الشرح، الآية ٧'),
  ('«احرص على ما ينفعك، واستعن بالله، ولا تعجز».', 'صحيح مسلم'),
  ('«إن الله يحب إذا عمل أحدكم عملًا أن يتقنه».', 'رواه الطبراني والبيهقي، وحسّنه الألباني'),
  ('ابدأ يومك بأصعب مهمة وأهمها، قبل أن تستهلك الرسائل والاجتماعات طاقتك.', 'نصيحة في إدارة الوقت'),
  ('قاعدة الدقيقتين: إن كانت المهمة تأخذ أقل من دقيقتين، فافعلها الآن ولا تؤجلها.', 'نصيحة في إدارة الوقت'),
  ('العمل ٢٥ دقيقة بتركيز كامل ثم راحة ٥ دقائق يحافظ على نشاط ذهنك طوال اليوم.', 'طريقة بومودورو'),
  ('المهام المهمة غير العاجلة هي التي تبني مستقبلك، فخصّص لها وقتًا ثابتًا كل يوم.', 'مصفوفة أيزنهاور'),
  ('العمل يتمدد ليملأ الوقت المتاح له. ضع لكل مهمة وقتًا محددًا تنتهي فيه.', 'قانون باركنسون'),
  ('التنقل بين المهام يهدر جزءًا كبيرًا من تركيزك. أنجز مهمة واحدة ثم انتقل للتالية.', 'نصيحة في التركيز'),
  ('ضع الجوال بعيدًا عنك وقت الدراسة؛ مجرد وجوده أمامك يشتت الانتباه.', 'نصيحة في التركيز'),
  ('يحتاج البالغ عادة من ٧ إلى ٩ ساعات نوم. قلة النوم تضعف الحفظ والتركيز.', 'معلومة صحية'),
  ('النوم المبكر بعد العشاء يعطيك صباحًا مباركًا دون أن تنقص من حاجة جسمك للنوم.', 'نصيحة في النوم'),
  ('القيلولة القصيرة (١٠ إلى ٣٠ دقيقة) بعد الظهر تجدد النشاط وتحسن التركيز.', 'معلومة صحية'),
  ('اشرب الماء بانتظام؛ نقص الماء ولو قليلًا يسبب التعب وضعف التركيز.', 'معلومة صحية'),
  ('المشي ٢٠ دقيقة يوميًا يحسّن المزاج والذاكرة ويقوي القلب.', 'معلومة صحية'),
  ('راجع ما حفظته في اليوم التالي، ثم بعد أسبوع، ثم بعد شهر؛ فالمراجعة المتباعدة تثبّت الحفظ.', 'التكرار المتباعد'),
  ('اشرح ما درسته لغيرك أو لنفسك بصوت مسموع؛ الشرح من أقوى طرق الفهم.', 'نصيحة في الدراسة'),
  ('اختبر نفسك بأسئلة بدل إعادة القراءة فقط؛ الاسترجاع يثبّت المعلومة أكثر.', 'نصيحة في الدراسة'),
  ('اكتب أهم ٣ مهام لليوم قبل أن تنام، فتستيقظ وأنت تعرف من أين تبدأ.', 'نصيحة في التخطيط'),
  ('قسّم المهمة الكبيرة إلى خطوات صغيرة، وابدأ بأول خطوة الآن.', 'نصيحة في الإنجاز'),
  ('اترك ١٠ دقائق راحة بين المهام؛ الجدول المضغوط بلا فراغات ينهار عند أول تأخير.', 'نصيحة في التخطيط'),
  ('راجع يومك مساءً: ما الذي نجح؟ وما الذي ستحسّنه غدًا؟ دقيقتان تصنعان فرقًا كبيرًا.', 'نصيحة في المراجعة'),
  ('الإنجاز الصغير المتكرر يبني العادة؛ ابدأ بخمس دقائق يوميًا ثم زِد.', 'نصيحة في بناء العادات'),
  ('اربط العادة الجديدة بعادة ثابتة، مثل قراءة صفحة من القرآن بعد صلاة الفجر مباشرة.', 'نصيحة في بناء العادات'),
  ('قول «لا» لما لا يهم هو ما يعطيك الوقت لقول «نعم» لما يهم.', 'نصيحة في إدارة الوقت'),
  ('حدد وقتين في اليوم لقراءة الرسائل بدل فتحها كل بضع دقائق.', 'نصيحة في التركيز'),
  ('رتّب مكان عملك قبل أن تبدأ؛ المكان المرتب يساعد على التركيز.', 'نصيحة في الإنجاز'),
  ('أوقات الصلاة محطات طبيعية لتقسيم يومك: خطط لما بين كل صلاتين.', 'نصيحة في التخطيط'),
  ('كافئ نفسك بعد إنجاز المهمة الصعبة؛ المكافأة الصغيرة تشجعك على الاستمرار.', 'نصيحة في التحفيز'),
  ('لا تنتظر الحماس لتبدأ؛ ابدأ، فيأتي الحماس بعد البداية.', 'نصيحة في التحفيز'),
  ('اكتب ما يشغل بالك على ورقة أو في «أفرغ ذهنك»؛ تفريغ الذهن يخفف التوتر.', 'نصيحة في التخطيط'),
  ('«بادروا بالأعمال».', 'صحيح مسلم'),
  ('الوقت أنفس ما عُني بحفظه، وأراه أسهل ما عليك يضيع.', 'من الحكمة العربية'),
  ('الإفراط في التخطيط دون تنفيذ نوع من التسويف؛ خطّط بقدر، ثم ابدأ.', 'نصيحة في الإنجاز'),
  ('الصباح الهادئ يبدأ من ليلة منظمة: جهّز ملابسك وأدواتك قبل النوم.', 'نصيحة في التخطيط'),
  ('قِس تقدمك أسبوعيًا لا يوميًا؛ الأيام تتفاوت، والاتجاه العام هو المهم.', 'نصيحة في المتابعة')
) as v(body, source)
where not exists (select 1 from public.yawmi_tips);

notify pgrst, 'reload schema';

-- مفتاح المشرف: انسخه واحفظه (به تعدّل معلومة اليوم من داخل التطبيق ← ⚙ ← وضع المشرف)
select key as "مفتاح المشرف — احفظه" from public.yawmi_admin;
