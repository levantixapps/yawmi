-- يومي: التحديث الثلاثون — مسابقة الألغاز بين فريقين 🏆
-- شغّل هذا الملف مرة واحدة بعد supabase_v29.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- لكل مسابقة صف واحد: الرمز (٦ أرقام)، ومفتاحا الجهازين (رئيس الفريق الأول، ورئيس الثاني)، ورقم النسخة،
-- والحالة `st` (رقم يولّد منه كل جهاز الأسئلة نفسها، ورقم السؤال، والنقاط، ووقت بدء السؤال). الأسئلة لا تُحفظ هنا.
-- يكتب الجهاز فقط إن كان رقم النسخة عنده هو الأحدث، فلا يكتب أحد فوق الآخر.
-- المسابقات التي مضى عليها يوم تُحذف عند إنشاء مسابقة جديدة. لا تحتاج حسابًا.

create table if not exists public.yawmi_matches (
  code text primary key,
  host text not null,
  guest text,
  ver int not null default 1,
  st jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.yawmi_matches enable row level security; -- لا يُقرأ إلا من الدوال

create or replace function public.yawmi_match_now() returns bigint language sql stable as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint $$;

create or replace function public.yawmi_match_new(p_key text, p_st jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare c text; i int := 0;
begin
  if length(coalesce(p_key, '')) < 16 or length(p_key) > 64 or p_st is null or length(p_st::text) > 2000 then return null; end if;
  delete from public.yawmi_matches where updated_at < now() - interval '1 day';
  loop
    c := lpad((floor(random() * 1000000))::int::text, 6, '0');
    begin
      insert into public.yawmi_matches (code, host, st) values (c, p_key, p_st);
      return c;
    exception when unique_violation then
      i := i + 1; if i > 20 then return null; end if;
    end;
  end loop;
end; $$;

-- رئيس الفريق الثاني يدخل بالرمز (أو أيٌّ من الجهازين يعود إليها)
create or replace function public.yawmi_match_join(p_code text, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.yawmi_matches;
begin
  if length(coalesce(p_key, '')) < 16 or length(p_key) > 64 then return null; end if;
  select * into m from public.yawmi_matches where code = p_code;
  if not found then return jsonb_build_object('err', 'none'); end if;
  if m.host <> p_key and m.guest is not null and m.guest <> p_key then return jsonb_build_object('err', 'full'); end if;
  if m.host <> p_key and m.guest is null then
    update public.yawmi_matches set guest = p_key, ver = ver + 1, updated_at = now() where code = p_code returning * into m;
  end if;
  return jsonb_build_object('ver', m.ver, 'st', m.st, 'now', public.yawmi_match_now(), 'host', m.host = p_key, 'guest', m.guest is not null);
end; $$;

-- القراءة: إن لم يتغيّر رقم النسخة يعود الرقم والوقت فقط
create or replace function public.yawmi_match_get(p_code text, p_ver int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.yawmi_matches;
begin
  select * into m from public.yawmi_matches where code = p_code;
  if not found then return jsonb_build_object('err', 'none'); end if;
  if m.ver = p_ver then return jsonb_build_object('ver', m.ver, 'now', public.yawmi_match_now()); end if;
  return jsonb_build_object('ver', m.ver, 'st', m.st, 'now', public.yawmi_match_now(), 'guest', m.guest is not null);
end; $$;

-- الكتابة: من أحد الجهازين فقط، وإن كانت نسخته هي الأحدث
create or replace function public.yawmi_match_put(p_code text, p_key text, p_ver int, p_st jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v int;
begin
  if p_st is null or length(p_st::text) > 2000 then return null; end if;
  update public.yawmi_matches set st = p_st, ver = ver + 1, updated_at = now()
    where code = p_code and ver = p_ver and (host = p_key or guest = p_key) returning ver into v;
  if v is null then return null; end if;
  return jsonb_build_object('ver', v, 'now', public.yawmi_match_now());
end; $$;

revoke all on function public.yawmi_match_new(text, jsonb) from public;
revoke all on function public.yawmi_match_join(text, text) from public;
revoke all on function public.yawmi_match_get(text, int) from public;
revoke all on function public.yawmi_match_put(text, text, int, jsonb) from public;
grant execute on function public.yawmi_match_new(text, jsonb) to anon, authenticated;
grant execute on function public.yawmi_match_join(text, text) to anon, authenticated;
grant execute on function public.yawmi_match_get(text, int) to anon, authenticated;
grant execute on function public.yawmi_match_put(text, text, int, jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
