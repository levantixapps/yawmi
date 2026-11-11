-- يومي: التحديث الرابع عشر — زر «تصفير المنصة» في لوحة المشرف
-- شغّل هذا الملف مرة واحدة بعد supabase_v13.sql من: Supabase ← SQL Editor ← New query ← Run.
--
-- التصفير يحذف كل الحسابات (الشخصية والفرق)، ومعها بالتسلسل: الأجهزة، واشتراكات الإشعارات، والتابعون، والطلبات، ورموز الربط.
-- يبقى: معلومات اليوم (yawmi_tips) ومفتاح المشرف (yawmi_admin).
-- لا رجعة فيه. يحتاج مفتاح المشرف، وكلمة «صفر» تأكيدًا.

create or replace function public.yawmi_admin_reset(p_admin text, p_word text)
returns json language plpgsql security definer set search_path = public as $$
declare a int;
begin
  if not public.yawmi_admin_check(p_admin) or replace(trim(coalesce(p_word, '')), 'ّ', '') <> 'صفر' then return null; end if;
  delete from public.yawmi_accounts where true; -- Supabase يرفض الحذف بلا شرط
  get diagnostics a = row_count;
  delete from public.yawmi_link_requests where true;
  return json_build_object('accounts', a);
end; $$;
revoke all on function public.yawmi_admin_reset(text, text) from public;
grant execute on function public.yawmi_admin_reset(text, text) to anon, authenticated;

notify pgrst, 'reload schema';
