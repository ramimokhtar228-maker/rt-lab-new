-- RT LAB Supabase Setup (clean)
-- Paste entire file in SQL Editor and Run once


-- ========== BLOCK 1 ==========
-- ============================================================
-- SQL: مواعيد التحاليل (محدّث) + Storage للروشتات
-- ============================================================

-- إنشاء الجدول من الصفر (لو مش موجود)
create table if not exists public.rt_lab_bookings (
  id                 bigserial primary key,
  full_name          text not null,
  phone              text not null,
  whatsapp           text,
  preferred_date     date,
  preferred_time     text,
  tests_text         text,
  prescription_path  text,
  prescription_url   text,
  notes              text,
  status             text not null default 'PENDING',
  quoted_price       numeric,
  price_before       numeric,
  visit_fee          numeric default 0,
  visit_type         text default 'branch',
  address_details    text,
  confirmed_date     date,
  confirmed_time     text,
  complaint          text,
  medications        text,
  result_url         text,
  daily_discount     numeric default 0,
  points_used        numeric default 0,
  discount_type      text default 'none',
  admin_notes        text,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

-- لو الجدول موجود مسبقاً، أضف الأعمدة الجديدة فقط:
alter table public.rt_lab_bookings add column if not exists price_before numeric;
alter table public.rt_lab_bookings add column if not exists visit_fee numeric default 0;
alter table public.rt_lab_bookings add column if not exists visit_type text default 'branch';
alter table public.rt_lab_bookings add column if not exists address_details text;
alter table public.rt_lab_bookings add column if not exists confirmed_date date;
alter table public.rt_lab_bookings add column if not exists confirmed_time text;
alter table public.rt_lab_bookings add column if not exists complaint text;
alter table public.rt_lab_bookings add column if not exists medications text;
alter table public.rt_lab_bookings add column if not exists result_url text;
alter table public.rt_lab_bookings add column if not exists daily_discount numeric default 0;
alter table public.rt_lab_bookings add column if not exists points_used numeric default 0;
alter table public.rt_lab_bookings add column if not exists discount_type text default 'none';
alter table public.rt_lab_bookings add column if not exists age numeric;

-- نقاط الولاء على جدول المرضى

create table if not exists public."Patients" (
  id bigserial primary key,
  phone text,
  name text,
  loyalty_points numeric default 0,
  age numeric
);

alter table public."Patients" add column if not exists loyalty_points numeric default 0;
alter table public."Patients" add column if not exists age numeric;

create index if not exists idx_lab_bookings_status on public.rt_lab_bookings(status);

alter table public.rt_lab_bookings enable row level security;

drop policy if exists "Allow all lab bookings" on public.rt_lab_bookings;
create policy "Allow all lab bookings"
  on public.rt_lab_bookings for all to anon, authenticated
  using (true) with check (true);

-- Storage: من لوحة Supabase → Storage → New bucket
-- الاسم: prescriptions
-- Public bucket: نعم
-- ثم Policies للـ bucket: INSERT/SELECT للـ anon

-- ============================================================
-- تحديث فئات العضوية: من BASIC/PLUS/VIP المدفوعة
-- إلى RT SILVER/GOLD/PLATINUM/DIAMOND/BLACK المجانية التلقائية
-- ============================================================
-- شغّل الأوامر دي مرة واحدة في Supabase SQL Editor بعد رفع التعديل

-- لو جدول rt_membership_tiers مش موجود أصلاً، أنشئه:
create table if not exists public.rt_membership_tiers (
  id               bigserial primary key,
  name             text not null unique,
  discount_percent numeric not null default 0,
  annual_fee       numeric not null default 0,
  min_spend        numeric not null default 0
);
alter table public.rt_membership_tiers add column if not exists min_spend numeric default 0;

-- أدخل/حدّث الفئات الست (SILVER → BLACK + PREMIUM)
-- min_spend = الحد الأدنى بالنقاط (نقطة ≈ 10 ج)
insert into public.rt_membership_tiers (name, discount_percent, annual_fee, min_spend) values
  ('SILVER',   20, 0, 0),
  ('GOLD',     25, 0, 30),
  ('PLATINUM', 30, 0, 50),
  ('DIAMOND',  40, 0, 75),
  ('PREMIUM',  50, 0, 100),
  ('BLACK',    60, 0, 150)
on conflict (name) do update set
  discount_percent = excluded.discount_percent,
  annual_fee = excluded.annual_fee,
  min_spend = excluded.min_spend;

-- (اختياري) لو عايز تشيل فئات BASIC/PLUS/VIP القديمة نهائياً بعد ما تتأكد
-- إنه مفيش كروت نشطة عليها، شغّل السطرين دول يدوياً بعد المراجعة:
-- delete from public.rt_membership_tiers where name in ('BASIC','PLUS','VIP')
--   and id not in (select tier_id from public.rt_memberships);

-- انتهى

-- ========== BLOCK 2 ==========
-- ============================================================
-- SQL إضافي: تحديثات دفعة التطوير الجديدة
-- (كارت كامل + تذكيرات + تقارير + بوابة عميل + صلاحية نقاط)
-- نفّذ الكود ده كامل مرة واحدة من SQL Editor في Supabase
-- ============================================================

-- 1) أعمدة جديدة في إعدادات المعمل (بيانات الكارت + صلاحية النقاط)

-- جدول إعدادات المعمل (لو مش موجود)
create table if not exists public.rt_lab_settings (
  id bigserial primary key,
  card_branch text default 'RT LAB',
  card_phone text,
  card_policy text,
  points_expiry_months integer default 12
);

alter table public.rt_lab_settings add column if not exists card_branch text default 'RT LAB';
alter table public.rt_lab_settings add column if not exists card_phone text;
alter table public.rt_lab_settings add column if not exists card_policy text;
alter table public.rt_lab_settings add column if not exists points_expiry_months integer default 12;

-- 2) عمود تتبع إرسال تذكير الموعد
alter table public.rt_lab_bookings add column if not exists reminder_sent boolean default false;

-- 3) دفتر حركة نقاط الولاء (لدعم صلاحية النقاط)
create table if not exists public.rt_points_ledger (
  id          bigserial primary key,
  patient_id  bigint references public."Patients"(id) on delete cascade,
  phone       text,
-- points      integer not null,        -- موجب = كسب، سالب = استبدال أو انتهاء صلاحية
  type        text not null check (type in ('earn','redeem','expire')),
  expires_at  timestamptz,             -- تاريخ انتهاء صلاحية هذه الدفعة (لو type = earn)
  expired     boolean default false,   -- هل تم إسقاطها فعلاً؟
  created_at  timestamptz default now()
);
alter table public.rt_points_ledger enable row level security;
-- يُقرأ ويُكتب فقط من الأدمن (المستخدم الموثّق)، مش من الزوار
drop policy if exists "ledger_admin_all" on public.rt_points_ledger;
create policy "ledger_admin_all" on public.rt_points_ledger for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- 4) دالة إسقاط النقاط المنتهية (تُشغَّل يدوياً أو تلقائياً عبر pg_cron)
create or replace function public.expire_old_points()
returns void
language plpgsql
security definer
as $$
declare
  r record;
  total_expired integer;
begin
  for r in
    select patient_id, sum(points) as pts
    from public.rt_points_ledger
    where type = 'earn' and expired = false
      and expires_at is not null and expires_at < now()
    group by patient_id
  loop
    total_expired := r.pts;
    if total_expired > 0 then
      -- سجّل حركة الإسقاط
      insert into public.rt_points_ledger (patient_id, phone, points, type, expired)
      values (r.patient_id, (select phone from public."Patients" where id = r.patient_id), -total_expired, 'expire', true);
      -- اخصم من رصيد العميل (مايتعديش صفر)
      update public."Patients"
      set loyalty_points = greatest(0, coalesce(loyalty_points,0) - total_expired)
      where id = r.patient_id;
    end if;
    -- علّم الدفعات القديمة كمنتهية عشان متتكررش
    update public.rt_points_ledger
    set expired = true
    where patient_id = r.patient_id and type = 'earn' and expired = false
      and expires_at is not null and expires_at < now();
  end loop;
end;
$$;

-- السماح للأدمن (وللـ RPC اليدوي من الواجهة) بتشغيل الدالة
grant execute on function public.expire_old_points() to authenticated;

-- 5) جدولة تلقائية يومية (Supabase: فعّل إضافة pg_cron من Database > Extensions أولاً)
-- شغّل السطر ده مرة واحدة بعد تفعيل الإضافة:
-- select cron.schedule('rt_expire_points_daily', '0 3 * * *', $$select public.expire_old_points();$$);

-- 6) دالة بوابة العميل العامة (استعلام بدون تسجيل دخول، بيانات محدودة وآمنة فقط)
create or replace function public.public_portal_lookup(p_phone text)
returns table (
  status text,
  confirmed_date date,
  confirmed_time text,
  quoted_price numeric,
  result_url text,
  card_number text,
  tier_name text,
  discount_percent numeric,
  loyalty_points integer,
  card_expiry date
)
language plpgsql
security definer
as $$
begin
  return query
  select b.status, b.confirmed_date, b.confirmed_time, b.quoted_price, b.result_url,
         c.card_number, t.name as tier_name, t.discount_percent,
         p.loyalty_points, c.expiry_date
  from public.rt_lab_bookings b
  left join public."Patients" p on p.phone = b.phone
  left join public.rt_memberships m on m.patient_id = p.id and m.status = 'ACTIVE'
  left join public.rt_membership_tiers t on t.id = m.tier_id
  left join public.rt_cards c on c.membership_id = m.id and c.status = 'ACTIVE'
  where b.phone = p_phone
  order by b.id desc
  limit 1;
end;
$$;

-- السماح للزوار (anon) باستدعاء دالة البوابة فقط — بدون أي صلاحية قراءة مباشرة على الجداول
grant execute on function public.public_portal_lookup(text) to anon;

-- انتهى التحديثات
