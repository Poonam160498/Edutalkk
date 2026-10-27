# EduTalk — Backend Design
### Astrotalk-model marketplace, adapted to education (pay-per-minute tutoring)

The backend has one job above all others: **meter live sessions per minute and move money safely** between student wallets and tutor payouts. Everything else (listings, live streams, store) hangs off that core.

---

## 1. High-level architecture

```
 [Student app]        [Tutor app]         [Admin panel]
 (Flutter/RN)         (Flutter/RN)          (React web)
      │                    │                    │
      └──────────┬─────────┴──────────┬─────────┘
                 │  HTTPS (REST)      │  WSS (Socket.IO)
                 ▼                    ▼
          ┌──────────────────────────────────┐
          │        API Gateway (Nginx)        │
          └──────────────────────────────────┘
                 │
   ┌─────────┬───┴──────┬───────────┬────────────┬──────────┐
   ▼         ▼          ▼           ▼            ▼          ▼
 Auth     Tutor &    Session &   Wallet &     Store     Live class
 service  Search     Matching    Billing      service   service
   │       service    service     service        │          │
   │         │          │           │            │          │
   └────┬────┴────┬─────┴─────┬─────┴──────┬─────┴────┬─────┘
        ▼         ▼           ▼            ▼          ▼
   PostgreSQL   Redis      Socket.IO    Razorpay    Agora.io
   (primary DB) (presence, (chat +      (payments,  (voice/video
                queues,    billing      payouts)    + live streams)
                locks)     ticks)
                     │
              S3 / CloudFront          Firebase FCM
              (doubt photos, notes,    (push notifications)
               recordings)
```

Start as a **modular monolith** (one Node.js codebase, folders per service). Split into microservices only after real traffic demands it — Astrotalk itself ran for years on a simple stack.

**Tech stack:** Node.js (NestJS) · PostgreSQL 15 · Redis 7 · Socket.IO · Agora.io (calls, live) · Razorpay (payments + RazorpayX payouts) · Firebase (FCM push, phone-OTP auth) · S3 (media) · Docker on AWS/GCP.

---

## 2. Database schema (PostgreSQL)

```sql
-- ============ USERS & TUTORS ============

CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone         VARCHAR(15) UNIQUE NOT NULL,
  name          VARCHAR(100),
  role          VARCHAR(10) NOT NULL DEFAULT 'student',  -- student | tutor | admin
  avatar_url    TEXT,
  exam_target   VARCHAR(50),          -- JEE, NEET, Boards, IELTS...
  first_session_used BOOLEAN DEFAULT FALSE,
  created_at    TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE tutor_profiles (
  user_id       UUID PRIMARY KEY REFERENCES users(id),
  bio           TEXT,
  subjects      TEXT[] NOT NULL,      -- {'Maths','JEE'}
  languages     TEXT[] NOT NULL,
  experience_yrs INT,
  price_per_min_chat NUMERIC(6,2) NOT NULL,
  price_per_min_call NUMERIC(6,2) NOT NULL,
  display_cut_price  NUMERIC(6,2),   -- strikethrough price (marketing)
  status        VARCHAR(10) DEFAULT 'offline',  -- online | busy | offline
  is_verified   BOOLEAN DEFAULT FALSE,          -- KYC + degree check passed
  rating_avg    NUMERIC(3,2) DEFAULT 0,
  rating_count  INT DEFAULT 0,
  total_sessions INT DEFAULT 0,
  commission_pct NUMERIC(4,2) DEFAULT 30.0      -- platform ka hissa
);

CREATE TABLE tutor_documents (        -- KYC: degree, ID, bank proof
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tutor_id UUID REFERENCES users(id),
  doc_type VARCHAR(30), file_url TEXT,
  review_status VARCHAR(10) DEFAULT 'pending'   -- pending | approved | rejected
);

-- ============ WALLET (the heart) ============

CREATE TABLE wallets (
  user_id   UUID PRIMARY KEY REFERENCES users(id),
  balance   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Append-only ledger. Balance is ALWAYS derivable from this table.
CREATE TABLE wallet_transactions (
  id          BIGSERIAL PRIMARY KEY,
  user_id     UUID REFERENCES users(id),
  amount      NUMERIC(10,2) NOT NULL,   -- +credit / -debit
  type        VARCHAR(20) NOT NULL,     -- recharge | recharge_bonus |
                                        -- session_debit | store_purchase |
                                        -- refund | tutor_earning | payout
  ref_id      UUID,                     -- session id / order id / payment id
  balance_after NUMERIC(10,2) NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE recharge_packs (
  id SERIAL PRIMARY KEY,
  amount NUMERIC(8,2), bonus NUMERIC(8,2) DEFAULT 0,
  is_popular BOOLEAN DEFAULT FALSE, active BOOLEAN DEFAULT TRUE
);

CREATE TABLE payments (               -- Razorpay ke saath reconcile karne ke liye
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID, razorpay_order_id TEXT, razorpay_payment_id TEXT,
  amount NUMERIC(10,2), status VARCHAR(15) DEFAULT 'created',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============ SESSIONS & BILLING ============

CREATE TABLE sessions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  student_id  UUID REFERENCES users(id),
  tutor_id    UUID REFERENCES users(id),
  mode        VARCHAR(10) NOT NULL,        -- chat | call | video
  price_per_min NUMERIC(6,2) NOT NULL,     -- price locked at start
  is_free_first BOOLEAN DEFAULT FALSE,
  status      VARCHAR(12) DEFAULT 'active',-- active | completed |
                                           -- auto_ended | refunded
  started_at  TIMESTAMPTZ DEFAULT now(),
  ended_at    TIMESTAMPTZ,
  billed_minutes INT DEFAULT 0,
  total_charge  NUMERIC(10,2) DEFAULT 0,
  tutor_earning NUMERIC(10,2) DEFAULT 0,
  end_reason  VARCHAR(30)                  -- user_ended | low_balance |
);                                         -- tutor_ended | disconnect

CREATE TABLE messages (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES sessions(id),
  sender_id  UUID,
  kind  VARCHAR(10) DEFAULT 'text',        -- text | image | whiteboard
  body  TEXT, media_url TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID UNIQUE REFERENCES sessions(id),
  student_id UUID, tutor_id UUID,
  stars INT CHECK (stars BETWEEN 1 AND 5),
  comment TEXT, created_at TIMESTAMPTZ DEFAULT now()
);

-- ============ WAITLIST / QUEUE ============

CREATE TABLE waitlist (
  id BIGSERIAL PRIMARY KEY,
  tutor_id UUID, student_id UUID,
  created_at TIMESTAMPTZ DEFAULT now(),
  notified BOOLEAN DEFAULT FALSE,
  UNIQUE (tutor_id, student_id)
);

-- ============ STORE (EduMall) & LIVE ============

CREATE TABLE products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT, type VARCHAR(20),        -- notes | test_series | course | mentorship
  price NUMERIC(8,2), cut_price NUMERIC(8,2),
  tutor_id UUID, file_url TEXT, active BOOLEAN DEFAULT TRUE
);

CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID, product_id UUID,
  amount NUMERIC(8,2), paid_via VARCHAR(10) DEFAULT 'wallet',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE live_classes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tutor_id UUID, title TEXT, subject VARCHAR(40),
  agora_channel TEXT, status VARCHAR(10) DEFAULT 'scheduled',
  scheduled_at TIMESTAMPTZ, viewer_count INT DEFAULT 0
);

CREATE TABLE payouts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tutor_id UUID, amount NUMERIC(10,2),
  period_start DATE, period_end DATE,
  status VARCHAR(12) DEFAULT 'pending',   -- pending | processing | paid
  razorpayx_ref TEXT, created_at TIMESTAMPTZ DEFAULT now()
);
```

Useful indexes: `tutor_profiles(status)`, `sessions(student_id, started_at DESC)`, `wallet_transactions(user_id, created_at DESC)`, GIN index on `tutor_profiles(subjects)` for subject filters.

---

## 3. REST API surface

```
AUTH
POST /auth/otp/send            { phone }
POST /auth/otp/verify          { phone, otp }        → JWT (access + refresh)

TUTORS
GET  /tutors?subject=&lang=&sort=rating&status=online&page=
GET  /tutors/:id                                     → profile + reviews
PATCH /tutors/me/status        { status }            (tutor app: go online/offline)
POST /tutors/:id/waitlist                            (busy tutor → notify me)

SESSIONS
POST /sessions                 { tutor_id, mode }    → session + socket token
POST /sessions/:id/end
GET  /sessions/:id             → transcript, charge, duration
GET  /sessions?me=1            → history
POST /sessions/:id/review      { stars, comment }

WALLET
GET  /wallet                   → balance + last transactions
GET  /wallet/packs
POST /wallet/recharge          { pack_id }           → razorpay_order_id
POST /webhooks/razorpay        (signature-verified; credits wallet + bonus)

STORE
GET  /products?type=
POST /orders                   { product_id }        (wallet se debit)
GET  /orders/me                → "My Library"

LIVE
GET  /live?status=live
POST /live/:id/join            → Agora viewer token
POST /live/:id/priority-ask    { question }          (coins debit → queue top)

ADMIN
GET/PATCH /admin/tutors/pending     (KYC approve/reject)
GET  /admin/metrics                 (GMV, sessions/day, ARPU)
POST /admin/payouts/run             (weekly batch)
```

## 4. WebSocket events (Socket.IO)

```
client → server:  session:join, message:send, typing, session:end
server → client:  message:new, billing:tick {minute, charged, balance_left},
                  billing:low_balance,          (balance < 2 min bacha)
                  session:ended {reason, total},
                  tutor:status_changed,         (waitlist notify)
                  presence updates
```

---

## 5. Per-minute billing engine ⭐ (the core of the business)

Rules, same as Astrotalk: **price locks at session start**, billing is per started minute, session **auto-ends when balance can't cover the next minute**, and the first session is free per new user.

```
START SESSION
1. student taps Chat/Call
2. BEGIN TX:
     SELECT balance FROM wallets WHERE user_id = ? FOR UPDATE
     if first_session_used = false → mark session free
     else if balance < price_per_min → 402 "Recharge required"
     create sessions row (status = active)
     acquire Redis lock  tutor:{id}:busy   (prevents double-booking)
   COMMIT
3. set tutor status = busy, notify both sockets

EVERY 60 SECONDS (BullMQ repeatable job per active session)
   if session.is_free_first → emit tick, no debit
   else BEGIN TX:
     lock wallet row
     if balance >= price:
        UPDATE wallets SET balance = balance - price
        INSERT wallet_transactions (type='session_debit', ref=session_id)
        UPDATE sessions SET billed_minutes = billed_minutes + 1,
                            total_charge  = total_charge  + price
        emit billing:tick
        if balance_after < 2 * price → emit billing:low_balance
     else:
        end_session(reason = 'low_balance')
   COMMIT

END SESSION (user tap / low balance / 30 s heartbeat timeout)
   status = completed, ended_at = now()
   tutor_earning = total_charge * (1 - commission_pct/100)
   credit tutor ledger (type = 'tutor_earning')
   release Redis lock, tutor → online, notify waitlist,
   push review prompt to student
   if billed_minutes = 0 and duration < 60 s and not free
        → full refund (type = 'refund')     -- Astrotalk-style trust rule
```

Why this design is safe: `FOR UPDATE` row locks stop double-spending, the append-only ledger means balance can always be audited/rebuilt, price-lock stops mid-session price changes, and the Redis busy-lock stops two students landing on one tutor.

---

## 6. Matching, queue and discovery

Default listing sort = a weighted score: `0.4*rating + 0.3*conversion + 0.2*recency_online + 0.1*is_new_boost` (new tutors get a temporary boost, exactly how Astrotalk cold-starts fresh astrologers). "Instant match" mode picks the highest-scored **online** tutor for the chosen subject within 5 seconds. Busy tutors expose a waitlist; when the session ends, the queue head gets an FCM push — "Ananya is free now, 5 min hold."

## 7. Money in, money out

Recharge: app calls `/wallet/recharge` → Razorpay order → app opens Razorpay checkout → **webhook** (never the client) credits wallet + bonus in one transaction. Payouts: weekly cron sums each tutor's `tutor_earning − payout` ledger, creates a `payouts` row, fires RazorpayX bank transfer, marks paid. Unit economics per ₹9/min call: platform keeps ~₹2.7/min (30%) + wallet breakage + store margin.

## 8. Trust, safety and moderation

Tutor onboarding = phone KYC + degree upload + a recorded demo session reviewed by admin before `is_verified` flips. All chat media goes through moderation (block phone numbers/UPI IDs being exchanged to stop platform bypass — same leak Astrotalk fights). Report/block endpoints, profanity filter on messages, and since many students are minors: no personal-contact sharing, sessions logged, and a strict tutor code of conduct with strike-based bans.

## 9. Build order (MVP → v2)

**MVP (6–8 weeks):** OTP auth, tutor list + filters, wallet + Razorpay recharge, chat sessions with the billing engine above, reviews, admin KYC panel. This alone is the whole business loop.
**v1.1:** voice/video via Agora, waitlist + push, first-session-free growth loop, referral coins.
**v2:** live classes + priority-ask, EduMall store, tutor analytics dashboard, ML ranking of tutors.
