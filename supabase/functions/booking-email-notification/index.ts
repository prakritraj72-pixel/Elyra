import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-elyra-webhook-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_KEY") ?? "";
const emailKey = Deno.env.get("EMAIL_PROVIDER_KEY") ?? "";
const fromEmail = Deno.env.get("EMAIL_FROM") ?? "";
const webhookSecret = Deno.env.get("ELYRA_WEBHOOK_SECRET") ?? "";
const siteUrl = (Deno.env.get("ELYRA_SITE_URL") ?? "https://prakritraj72-pixel.github.io/Elyra").replace(/\/$/, "");

const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });

function esc(value: unknown) {
  return String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
}
function money(value: unknown) {
  const n = Number(value ?? 0);
  return `₹${Number.isFinite(n) ? n.toLocaleString("en-IN") : "0"}`;
}
function dateText(value: unknown) {
  if (!value) return "—";
  const d = new Date(`${String(value).slice(0, 10)}T00:00:00`);
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" });
}
function timeText(value: unknown) { return value ? String(value).slice(0, 5) : "—"; }
function recordFrom(payload: Record<string, unknown>) {
  if (payload.record && typeof payload.record === "object") return payload.record as Record<string, unknown>;
  if (payload.new_record && typeof payload.new_record === "object") return payload.new_record as Record<string, unknown>;
  if (payload.id && payload.creator_id) return payload;
  return null;
}

function creatorRequestHtml(booking: Record<string, unknown>, creatorName: string) {
  const link = `${siteUrl}/creator-bookings.html`;
  return `<!doctype html><html><body style="margin:0;background:#070707;color:#fff;font-family:Arial,sans-serif"><div style="max-width:620px;margin:auto;padding:24px 14px"><div style="background:#111;border:1px solid rgba(255,63,143,.28);border-radius:18px;overflow:hidden"><div style="padding:24px;background:linear-gradient(135deg,rgba(255,63,143,.16),rgba(255,63,143,.03))"><div style="font-size:24px;font-weight:900;letter-spacing:3px">ELY<span style="color:#ff3f8f">RA</span></div><h2 style="margin:18px 0 7px">New booking request</h2><div style="color:#aaa">Hi ${esc(creatorName)}, a customer has requested a booking with you.</div></div><div style="padding:24px"><table style="width:100%;font-size:14px"><tr><td style="padding:8px;color:#888">Customer</td><td style="padding:8px;text-align:right">${esc(booking.customer_name || "Customer")}</td></tr><tr><td style="padding:8px;color:#888">Date</td><td style="padding:8px;text-align:right">${esc(dateText(booking.booking_date))}</td></tr><tr><td style="padding:8px;color:#888">Time</td><td style="padding:8px;text-align:right">${esc(timeText(booking.start_time))} – ${esc(timeText(booking.end_time))}</td></tr><tr><td style="padding:8px;color:#888">Duration</td><td style="padding:8px;text-align:right">${esc(booking.duration_hours ?? booking.hours ?? 1)} hour(s)</td></tr><tr><td style="padding:8px;color:#888">Amount</td><td style="padding:8px;text-align:right;color:#ff3f8f;font-weight:800">${esc(money(booking.amount ?? booking.total_amount))}</td></tr></table><div style="margin-top:14px;padding:14px;background:#090909;border-radius:12px"><div style="color:#777;font-size:11px">MEETING LOCATION</div><div style="margin-top:5px">${esc(booking.meeting_address || "Not provided")}</div></div><div style="margin-top:12px;padding:14px;background:#090909;border-radius:12px"><div style="color:#777;font-size:11px">CUSTOMER NOTE</div><div style="margin-top:5px;line-height:1.5">${esc(booking.notes || "No notes provided.")}</div></div><a href="${esc(link)}" style="display:block;margin-top:20px;padding:14px;border-radius:11px;background:#ff3f8f;color:#050505;text-align:center;text-decoration:none;font-weight:900">Open Booking Requests</a></div></div><div style="padding:16px;color:#666;font-size:11px;text-align:center">ELYRA · 18+ · Lawful social companionship only</div></div></body></html>`;
}

function customerAcceptedHtml(booking: Record<string, unknown>, creatorName: string, creatorEmail: string, creatorPhone: string) {
  const link = `${siteUrl}/profile.html`;
  const contactRows = `${creatorPhone ? `<tr><td style="padding:8px;color:#888">Phone</td><td style="padding:8px;text-align:right"><a href="tel:${esc(creatorPhone)}" style="color:#ff6ca7">${esc(creatorPhone)}</a></td></tr>` : ""}${creatorEmail ? `<tr><td style="padding:8px;color:#888">Email</td><td style="padding:8px;text-align:right"><a href="mailto:${esc(creatorEmail)}" style="color:#ff6ca7">${esc(creatorEmail)}</a></td></tr>` : ""}`;
  return `<!doctype html><html><body style="margin:0;background:#070707;color:#fff;font-family:Arial,sans-serif"><div style="max-width:620px;margin:auto;padding:24px 14px"><div style="background:#111;border:1px solid rgba(54,217,139,.28);border-radius:18px;overflow:hidden"><div style="padding:24px;background:linear-gradient(135deg,rgba(54,217,139,.13),rgba(255,63,143,.03))"><div style="font-size:24px;font-weight:900;letter-spacing:3px">ELY<span style="color:#ff3f8f">RA</span></div><h2 style="margin:18px 0 7px">Booking accepted ✓</h2><div style="color:#aaa">Your booking with ${esc(creatorName)} has been accepted.</div></div><div style="padding:24px"><table style="width:100%;font-size:14px"><tr><td style="padding:8px;color:#888">Creator</td><td style="padding:8px;text-align:right">${esc(creatorName)}</td></tr><tr><td style="padding:8px;color:#888">Date</td><td style="padding:8px;text-align:right">${esc(dateText(booking.booking_date))}</td></tr><tr><td style="padding:8px;color:#888">Time</td><td style="padding:8px;text-align:right">${esc(timeText(booking.start_time))} – ${esc(timeText(booking.end_time))}</td></tr></table><div style="margin-top:14px;padding:14px;background:#090909;border-radius:12px"><div style="color:#777;font-size:11px">CREATOR CONTACT</div><table style="width:100%;font-size:14px;margin-top:5px">${contactRows || "<tr><td style=\"padding:8px;color:#888\">Contact</td><td style=\"padding:8px;text-align:right\">Available in your Elyra booking</td></tr>"}</table></div><a href="${esc(link)}" style="display:block;margin-top:20px;padding:14px;border-radius:11px;background:#ff3f8f;color:#050505;text-align:center;text-decoration:none;font-weight:900">Open My Bookings</a></div></div><div style="padding:16px;color:#666;font-size:11px;text-align:center">ELYRA · Contact details are shared only after acceptance</div></div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  try {
    if (!url || !serviceKey || !emailKey || !fromEmail) throw new Error("Server email configuration is incomplete.");
    if (webhookSecret && req.headers.get("x-elyra-webhook-secret") !== webhookSecret) return new Response(JSON.stringify({ ok: false, error: "Unauthorized" }), { status: 401, headers: { ...headers, "Content-Type": "application/json" } });

    const payload = await req.json();
    const booking = recordFrom(payload);
    if (!booking) throw new Error("No booking record supplied.");

    const status = String(booking.status || "pending").toLowerCase();
    const creatorId = String(booking.creator_id || "");
    const customerId = String(booking.customer_id || "");
    if (!creatorId) throw new Error("Booking creator_id is missing.");

    const { data: profile, error: profileError } = await admin.from("creator_profiles").select("user_id,display_name").eq("user_id", creatorId).maybeSingle();
    if (profileError) throw new Error(profileError.message);
    if (!profile?.user_id) throw new Error("Creator profile not found.");

    const { data: creatorAuth, error: creatorAuthError } = await admin.auth.admin.getUserById(profile.user_id);
    if (creatorAuthError) throw new Error(creatorAuthError.message);

    let to = "";
    let subject = "";
    let html = "";

    if (status === "pending") {
      to = creatorAuth.user?.email || "";
      if (!to) throw new Error("Creator email is not available.");
      subject = `ELYRA — New booking request from ${String(booking.customer_name || "a customer")}`;
      html = creatorRequestHtml(booking, String(profile.display_name || "Creator"));
    } else if (status === "accepted") {
      if (!customerId) throw new Error("Booking customer_id is missing.");
      const { data: customerAuth, error: customerAuthError } = await admin.auth.admin.getUserById(customerId);
      if (customerAuthError) throw new Error(customerAuthError.message);
      to = customerAuth.user?.email || "";
      if (!to) throw new Error("Customer email is not available.");
      const creatorPhone = String(creatorAuth.user?.phone || creatorAuth.user?.user_metadata?.phone || "");
      const creatorEmail = String(creatorAuth.user?.email || "");
      subject = `ELYRA — Your booking with ${String(profile.display_name || "Creator")} was accepted`;
      html = customerAcceptedHtml(booking, String(profile.display_name || "Creator"), creatorEmail, creatorPhone);
    } else {
      return new Response(JSON.stringify({ ok: true, skipped: true }), { headers: { ...headers, "Content-Type": "application/json" } });
    }

    const response = await fetch("https://api.resend.com/emails", { method: "POST", headers: { Authorization: `Bearer ${emailKey}`, "Content-Type": "application/json" }, body: JSON.stringify({ from: fromEmail, to: [to], subject, html }) });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`Email provider error (${response.status}).`);
    return new Response(JSON.stringify({ ok: true, email_id: result?.id ?? null, status }), { headers: { ...headers, "Content-Type": "application/json" } });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : "Unknown error" }), { status: 500, headers: { ...headers, "Content-Type": "application/json" } });
  }
});
