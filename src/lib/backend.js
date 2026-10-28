// Supabase connection. Agar .env mein keys nahi hain toh app purane
// demo mode mein chalti hai (sab kuch browser memory mein).
import { createClient } from "@supabase/supabase-js";

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_KEY;

export const supabase = url && key ? createClient(url, key) : null;
export const isLive = Boolean(supabase);

const ERRORS = {
  not_logged_in: "Pehle login karo",
  recharge_required: "Session start karne ke liye recharge karo",
  tutor_offline: "Tutor abhi offline hai",
  tutor_not_found: "Tutor nahi mila",
  insufficient_balance: "Wallet balance kam hai — recharge karo ya COD choose karo",
  address_required: "Delivery address poora bharo",
  invalid_items: "Cart mein kuch galat hai, dobara try karo",
  test_recharge_disabled: "Recharge abhi band hai",
  invalid_pack: "Ye recharge pack valid nahi hai",
  "Invalid login credentials": "Email ya password galat hai",
  "User already registered": "Is email se account pehle se bana hai — login karo",
  "Email not confirmed": "Pehle apni email mein aaya confirmation link kholo",
};

export function friendlyError(err) {
  const msg = err?.message || String(err);
  for (const k of Object.keys(ERRORS)) if (msg.includes(k)) return ERRORS[k];
  if (/password/i.test(msg) && /6/.test(msg)) return "Password kam se kam 6 characters ka hona chahiye";
  if (/fetch|network/i.test(msg)) return "Internet connection check karo";
  return "Kuch gadbad hui — dobara try karo";
}

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

const fmtTime = (d) =>
  new Date(d).toLocaleString("en-IN", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
const fmtDate = (d) => new Date(d).toLocaleDateString("en-IN", { day: "numeric", month: "short" });

// Login ke baad user ka saara data ek saath
export async function loadAccount(userId) {
  const [p, w, t, o] = await Promise.all([
    supabase.from("profiles").select("name, first_session_used").eq("id", userId).single(),
    supabase.from("wallets").select("balance").eq("user_id", userId).single(),
    supabase.from("wallet_transactions").select("amount, note, created_at").order("created_at", { ascending: false }).limit(50),
    supabase.from("orders").select("*").order("created_at", { ascending: false }).limit(30),
  ]);
  for (const r of [p, w, t, o]) if (r.error) throw r.error;
  return {
    name: p.data.name,
    firstFree: !p.data.first_session_used,
    balance: Number(w.data.balance),
    txns: t.data.map((x) => ({
      type: Number(x.amount) >= 0 ? "credit" : "debit",
      amount: Math.abs(Number(x.amount)),
      note: x.note,
      time: fmtTime(x.created_at),
    })),
    orders: o.data.map(toOrder),
  };
}

export function toOrder(o) {
  const created = o.created_at ? new Date(o.created_at) : new Date();
  return {
    id: o.code,
    items: o.items.map((i) => ({ ...i, price: Number(i.price) })),
    total: Number(o.total),
    pay: o.pay_mode,
    status: o.status || "Confirmed",
    date: fmtDate(created),
    eta: fmtDate(created.getTime() + 4 * 86400000),
  };
}

export const api = {
  signUp: async (name, email, password) => {
    const { data, error } = await supabase.auth.signUp({ email, password, options: { data: { name } } });
    if (error) throw error;
    return data;
  },
  signIn: async (email, password) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) throw error;
  },
  signOut: () => supabase.auth.signOut(),
  recharge: (amount) => rpc("test_recharge", { p_amount: amount }),
  startSession: (tutorId, mode) => rpc("start_session", { p_tutor_ref: String(tutorId), p_mode: mode }),
  tick: (sessionId) => rpc("session_tick", { p_session: sessionId }),
  endSession: (sessionId) => rpc("end_session", { p_session: sessionId }),
  placeOrder: (cart, payMode, address) =>
    rpc("place_order", {
      p_items: cart.map((i) => ({ id: i.id, qty: i.qty })),
      p_pay_mode: payMode,
      p_address: address,
    }),
};
