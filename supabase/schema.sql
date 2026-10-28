-- =====================================================================
-- EduTalk — Supabase database (Step 1: login, wallet, billing, orders)
--
-- Kaise chalana hai: Supabase dashboard → SQL Editor → New query →
-- is poori file ko paste karo → Run. Ek hi baar chalana hai.
--
-- Security model: app (browser) kisi bhi table mein seedha likh NAHI
-- sakti. Har paisa wala kaam neeche ke functions se hota hai, jo
-- server par price, balance aur time khud check karte hain. Isliye
-- koi user browser mein code badal ke free mein balance nahi bana sakta.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Settings (sirf ek row)
-- allow_test_recharge = true  → wallet recharge bina payment ke ho jata
--   hai (testing ke liye). Razorpay lagne ke baad isse FALSE karna hai.
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  id int primary key default 1 check (id = 1),
  allow_test_recharge boolean not null default true,
  free_session_minutes int not null default 5
);
insert into public.app_settings (id) values (1) on conflict do nothing;

-- ---------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text,
  role text not null default 'student' check (role in ('student','tutor','admin')),
  first_session_used boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance numeric(10,2) not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

-- Append-only ledger: balance hamesha isse dobara calculate ho sakta hai
create table if not exists public.wallet_transactions (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  amount numeric(10,2) not null,            -- + credit / - debit
  type text not null,                       -- recharge | session_debit | store_purchase | refund
  note text,
  ref_id uuid,
  balance_after numeric(10,2) not null,
  created_at timestamptz not null default now()
);
create index if not exists wallet_tx_user_idx on public.wallet_transactions (user_id, created_at desc);

-- Naya user signup kare → profile + khali wallet apne aap ban jaye
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)));
  insert into public.wallets (user_id) values (new.id);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Tutors & products (price yahin se aata hai, browser se nahi)
-- ---------------------------------------------------------------------
create table if not exists public.tutors (
  ref text primary key,                     -- app ke tutor id se match karta hai
  name text not null,
  is_ai boolean not null default false,
  price_per_min numeric(6,2) not null check (price_per_min > 0),
  status text not null default 'online' check (status in ('online','busy','offline'))
);

insert into public.tutors (ref, name, is_ai, price_per_min, status) values
  ('1',   'Ananya Rao',     false,  6, 'online'),
  ('2',   'Vikram Khanna',  false,  9, 'online'),
  ('3',   'Sarah Mathew',   false,  5, 'busy'),
  ('4',   'Rohit Deshmukh', false,  7, 'online'),
  ('5',   'Priya Nair',     false,  4, 'offline'),
  ('6',   'Arjun Mehta',    false, 12, 'online'),
  ('101', 'Aria AI',        true,   1, 'online'),
  ('102', 'Neo AI',         true,   1, 'online'),
  ('103', 'Lexa AI',        true,   1, 'online')
on conflict (ref) do nothing;

create table if not exists public.products (
  id int primary key,
  title text not null,
  price numeric(8,2) not null check (price > 0),
  physical boolean not null default true,
  active boolean not null default true
);

insert into public.products (id, title, price, physical) values
  (1,  'Apsara pencils (pack of 10)',   40,  true),
  (2,  'Geometry box (full set)',       149, true),
  (3,  'A4 notebooks (pack of 5)',      199, true),
  (4,  'School backpack (30L)',         699, true),
  (5,  'Scientific calculator FX-991',  899, true),
  (6,  'Study lamp (eye-care LED)',     549, true),
  (7,  'Focus headphones (wired)',      1499, true),
  (8,  'Pomodoro timer watch',          399, true),
  (9,  'Writing tablet (8.5 inch)',     449, true),
  (10, 'JEE Maths test series',         299, false),
  (11, 'Physics handwritten notes',     149, false),
  (12, 'NEET crash course',             999, false)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- Sessions & orders
-- ---------------------------------------------------------------------
create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  tutor_ref text not null references public.tutors(ref),
  mode text not null check (mode in ('chat','call')),
  price_per_min numeric(6,2) not null,      -- start par lock ho jata hai
  is_free_first boolean not null default false,
  status text not null default 'active' check (status in ('active','completed')),
  started_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at timestamptz,
  billed_minutes int not null default 0,
  total_charge numeric(10,2) not null default 0,
  end_reason text                            -- user_ended | low_balance | free_limit | disconnect
);
create index if not exists sessions_student_idx on public.sessions (student_id, started_at desc);
create unique index if not exists one_active_session_per_student
  on public.sessions (student_id) where status = 'active';

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  items jsonb not null,                      -- [{id, title, price, qty, physical}]
  subtotal numeric(10,2) not null,
  delivery numeric(10,2) not null,
  total numeric(10,2) not null,
  pay_mode text not null check (pay_mode in ('wallet','cod')),
  address jsonb,
  status text not null default 'Confirmed',
  created_at timestamptz not null default now()
);
create index if not exists orders_user_idx on public.orders (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- Row Level Security: har user sirf apna data PADH sakta hai.
-- Likhne ki koi policy nahi hai → seedha insert/update blocked.
-- ---------------------------------------------------------------------
alter table public.app_settings        enable row level security;
alter table public.profiles            enable row level security;
alter table public.wallets             enable row level security;
alter table public.wallet_transactions enable row level security;
alter table public.tutors              enable row level security;
alter table public.products            enable row level security;
alter table public.sessions            enable row level security;
alter table public.orders              enable row level security;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select using (auth.uid() = id);
drop policy if exists "own wallet" on public.wallets;
create policy "own wallet" on public.wallets for select using (auth.uid() = user_id);
drop policy if exists "own transactions" on public.wallet_transactions;
create policy "own transactions" on public.wallet_transactions for select using (auth.uid() = user_id);
drop policy if exists "own sessions" on public.sessions;
create policy "own sessions" on public.sessions for select using (auth.uid() = student_id);
drop policy if exists "own orders" on public.orders;
create policy "own orders" on public.orders for select using (auth.uid() = user_id);
drop policy if exists "tutors are public" on public.tutors;
create policy "tutors are public" on public.tutors for select using (true);
drop policy if exists "products are public" on public.products;
create policy "products are public" on public.products for select using (true);
drop policy if exists "settings are public" on public.app_settings;
create policy "settings are public" on public.app_settings for select using (true);

-- =====================================================================
-- Money functions
-- =====================================================================

-- Internal: session ka hisaab kitab. Jitne poore minute beete hain unka
-- charge kaatta hai (ek-ek minute, balance ke hisaab se). Agar app ne
-- 90 second se ping nahi kiya (app band / net gaya) toh student se sirf
-- last ping tak ka hi paisa katta hai.
create or replace function public._settle_session(p_id uuid, p_finish boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s        public.sessions%rowtype;
  w_bal    numeric;
  free_cap int;
  eff_now  timestamptz;
  due      int;
  reason   text := p_reason;
  finish   boolean := p_finish;
begin
  select * into s from public.sessions where id = p_id for update;
  if s.status <> 'active' then
    return jsonb_build_object('ended', true, 'billed_minutes', s.billed_minutes,
      'spent', s.total_charge, 'seconds', extract(epoch from s.ended_at - s.started_at)::int);
  end if;

  select free_session_minutes into free_cap from public.app_settings where id = 1;

  eff_now := now();
  if eff_now > s.last_seen_at + interval '90 seconds' then
    eff_now := s.last_seen_at + interval '60 seconds';
    finish := true;
    reason := coalesce(reason, 'disconnect');
  end if;

  -- 5 second ki chhoot: browser ka timer thoda jaldi bhi ping kar sakta hai
  due := floor((extract(epoch from eff_now - s.started_at) + 5) / 60)::int;

  if s.is_free_first then
    if due >= free_cap then
      due := free_cap;
      finish := true;
      reason := 'free_limit';
    end if;
    s.billed_minutes := greatest(s.billed_minutes, due);
  else
    select balance into w_bal from public.wallets where user_id = s.student_id for update;
    while s.billed_minutes < due loop
      if w_bal < s.price_per_min then
        finish := true;
        reason := 'low_balance';
        exit;
      end if;
      w_bal := w_bal - s.price_per_min;
      s.billed_minutes := s.billed_minutes + 1;
      s.total_charge := s.total_charge + s.price_per_min;
    end loop;
    if s.total_charge > (select total_charge from public.sessions where id = s.id) then
      update public.wallets set balance = w_bal, updated_at = now() where user_id = s.student_id;
      insert into public.wallet_transactions (user_id, amount, type, note, ref_id, balance_after)
      values (s.student_id,
              -(s.total_charge - (select total_charge from public.sessions where id = s.id)),
              'session_debit',
              (select case when t.is_ai then 'AI chat' when s.mode = 'call' then 'Call' else 'Chat' end
                      || ' — ' || t.name from public.tutors t where t.ref = s.tutor_ref),
              s.id, w_bal);
    end if;
    -- agla minute afford nahi hoga → abhi hi band
    if not finish and w_bal < s.price_per_min then
      finish := true;
      reason := 'low_balance';
    end if;
  end if;

  update public.sessions set
    billed_minutes = s.billed_minutes,
    total_charge   = s.total_charge,
    last_seen_at   = case when eff_now = now() then now() else last_seen_at end,
    status         = case when finish then 'completed' else 'active' end,
    ended_at       = case when finish then eff_now else null end,
    end_reason     = case when finish then coalesce(reason, 'user_ended') else null end
  where id = s.id;

  return jsonb_build_object(
    'ended', finish,
    'reason', case when finish then coalesce(reason, 'user_ended') end,
    'billed_minutes', s.billed_minutes,
    'spent', s.total_charge,
    'seconds', greatest(0, extract(epoch from eff_now - s.started_at)::int),
    'balance', (select balance from public.wallets where user_id = s.student_id));
end $$;

-- Session shuru karo. Price tutors table se lock hota hai.
create or replace function public.start_session(p_tutor_ref text, p_mode text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid   uuid := auth.uid();
  t     public.tutors%rowtype;
  price numeric;
  bal   numeric;
  used  boolean;
  old   uuid;
  sid   uuid;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_mode not in ('chat','call') then raise exception 'bad_mode'; end if;

  -- pichla koi session khula reh gaya ho toh pehle usse band karo
  for old in select id from public.sessions where student_id = uid and status = 'active' loop
    perform public._settle_session(old, true, 'replaced');
  end loop;

  select * into t from public.tutors where ref = p_tutor_ref;
  if not found then raise exception 'tutor_not_found'; end if;
  if t.status = 'offline' then raise exception 'tutor_offline'; end if;
  -- call human tutor ke saath ₹2/min zyada (app jaisa hi)
  price := t.price_per_min + case when p_mode = 'call' and not t.is_ai then 2 else 0 end;

  select balance into bal from public.wallets where user_id = uid for update;
  select first_session_used into used from public.profiles where id = uid for update;

  if used and bal < price then raise exception 'recharge_required'; end if;

  insert into public.sessions (student_id, tutor_ref, mode, price_per_min, is_free_first)
  values (uid, t.ref, p_mode, price, not used)
  returning id into sid;

  if not used then
    update public.profiles set first_session_used = true where id = uid;
  end if;

  return jsonb_build_object('session_id', sid, 'price', price, 'free', not used,
    'free_minutes', (select free_session_minutes from public.app_settings where id = 1));
end $$;

-- Har minute app isse call karti hai (heartbeat + billing)
create or replace function public.session_tick(p_session uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.sessions where id = p_session and student_id = auth.uid()) then
    raise exception 'session_not_found';
  end if;
  return public._settle_session(p_session, false, null);
end $$;

create or replace function public.end_session(p_session uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.sessions where id = p_session and student_id = auth.uid()) then
    raise exception 'session_not_found';
  end if;
  return public._settle_session(p_session, true, 'user_ended');
end $$;

-- TESTING ONLY: bina payment ke recharge. Razorpay ke baad band karna hai.
create or replace function public.test_recharge(p_amount int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid   uuid := auth.uid();
  bonus int;
  total numeric;
  bal   numeric;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if not (select allow_test_recharge from public.app_settings where id = 1) then
    raise exception 'test_recharge_disabled';
  end if;
  bonus := case p_amount when 50 then 0 when 100 then 20 when 200 then 50 when 500 then 100 else null end;
  if bonus is null then raise exception 'invalid_pack'; end if;
  total := p_amount + bonus;

  update public.wallets set balance = balance + total, updated_at = now()
  where user_id = uid returning balance into bal;

  insert into public.wallet_transactions (user_id, amount, type, note, balance_after)
  values (uid, total, 'recharge',
          'Recharge ₹' || p_amount || case when bonus > 0 then ' + ₹' || bonus || ' bonus' else '' end,
          bal);
  return jsonb_build_object('balance', bal, 'added', total);
end $$;

-- EduMall order. Price aur delivery charge server par calculate hote hain.
-- p_items = [{"id": 3, "qty": 2}, ...]
create or replace function public.place_order(p_items jsonb, p_pay_mode text, p_address jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid      uuid := auth.uid();
  items    jsonb;
  subtotal numeric;
  has_phys boolean;
  delivery numeric;
  total    numeric;
  bal      numeric;
  ocode    text := 'ED' || (1000 + floor(random() * 9000))::int;
  oid      uuid;
  cnt      int;
begin
  if uid is null then raise exception 'not_logged_in'; end if;
  if p_pay_mode not in ('wallet','cod') then raise exception 'bad_pay_mode'; end if;

  select jsonb_agg(jsonb_build_object('id', p.id, 'title', p.title, 'price', p.price,
                                      'qty', (i->>'qty')::int, 'physical', p.physical)),
         sum(p.price * (i->>'qty')::int),
         bool_or(p.physical),
         sum((i->>'qty')::int)
    into items, subtotal, has_phys, cnt
  from jsonb_array_elements(p_items) i
  join public.products p on p.id = (i->>'id')::int and p.active
  where (i->>'qty')::int between 1 and 20;

  if items is null or jsonb_array_length(items) <> jsonb_array_length(p_items) then
    raise exception 'invalid_items';
  end if;

  if has_phys and (coalesce(p_address->>'name','') = '' or coalesce(p_address->>'phone','') = ''
                   or coalesce(p_address->>'address','') = '' or coalesce(p_address->>'pin','') = '') then
    raise exception 'address_required';
  end if;

  delivery := case when has_phys and subtotal < 499 then 40 else 0 end;
  total := subtotal + delivery;

  insert into public.orders (code, user_id, items, subtotal, delivery, total, pay_mode, address)
  values (ocode, uid, items, subtotal, delivery, total, p_pay_mode,
          case when has_phys then p_address end)
  returning id into oid;

  if p_pay_mode = 'wallet' then
    select balance into bal from public.wallets where user_id = uid for update;
    if bal < total then raise exception 'insufficient_balance'; end if;
    bal := bal - total;
    update public.wallets set balance = bal, updated_at = now() where user_id = uid;
    insert into public.wallet_transactions (user_id, amount, type, note, ref_id, balance_after)
    values (uid, -total, 'store_purchase', 'EduMall order (' || cnt || ' items)', oid, bal);
  end if;

  return jsonb_build_object('id', oid, 'code', ocode, 'total', total, 'items', items);
end $$;

-- Internal function ko koi browser se call na kar sake; public functions
-- sirf logged-in users ke liye
revoke all on function public._settle_session(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.start_session(text, text)        from public, anon;
revoke all on function public.session_tick(uuid)               from public, anon;
revoke all on function public.end_session(uuid)                from public, anon;
revoke all on function public.test_recharge(int)               from public, anon;
revoke all on function public.place_order(jsonb, text, jsonb)  from public, anon;
grant execute on function public.start_session(text, text)       to authenticated;
grant execute on function public.session_tick(uuid)              to authenticated;
grant execute on function public.end_session(uuid)               to authenticated;
grant execute on function public.test_recharge(int)              to authenticated;
grant execute on function public.place_order(jsonb, text, jsonb) to authenticated;
