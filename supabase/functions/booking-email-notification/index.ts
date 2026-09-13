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

const admin = createClient(url, serviceKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function esc(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
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

function timeText(value: unknown) {
  return value ? String(value).slice(0, 5) : "—";
}

function recordFrom(payload: Record<string, unknown>) {
  if (payload.record && typeof payload.record === "object") return payload.record as Record<string, unknown>;
  if (payload.new_record && typeof payload.new_record === "object") return payload.new_record as Record<string, unknown>;
  if (payload.id && payload.creator_id) return payload;
  return null;
}

function emailHtml(booking: Record<string, unknown>, creatorName: string) {
  const customer = esc(booking.customer_name || "Customer");
  const date = esc(dateText(booking.booking_date));
  const start = esc(timeText(booking.start_time));
  const end = esc(timeText(booking.end_time));
  const hours = esc(booking.duration_hours ?? booking.hours ?? 1);
  const amount = esc(money(booking.amount ?? booking.total_amount));
  const address = esc(booking.meeting_address || "Not provided");
  const notes = esc(booking.notes || "No notes provided.");
  const link = `${siteUrl}/creator-bookings.html`;

  return `<!doctype html><html><body style="margin:0;background:#070707;color:#fff;font-family:Arial,sans-serif"><div style="max-width:620px;margin:auto;padding:24px 14px"><div style="background:#111;border:1px solid rgba(255,63,143,.28);border-radius:18px;overflow:hidden"><div style="padding:24px;background:linear-gradient(135deg,rgba(255,63,143,.16),rgba(255,63,143,.03))"><div style="font-size:24px;font-weight:900;letter-spacing:3px">ELY<span style="color:#ff3f8f">RA</span></div><h2 style="margin:18px 0 7px">New booking request</h2><div style="color:#aaa">Hi ${esc(creatorName)}, a customer has requested a booking with you.</div></div><div style="padding:24px"><table style="width:100%;font-size:14px"><tr><td style="padding:8px;color:#888">Customer</td><td style="padding:8px;text-align:right">${customer}</td></tr><tr><td style="padding:8px;color:#888">Date</td><td style="padding:8px;text-align:right">${date}</td></tr><tr><td style="padding:8px;color:#888">Time</td><td style="padding:8px;text-align:right">${start} – ${end}</td></tr><tr><td style="padding:8px;color:#888">Duration</td><td style="padding:8px;text-align:right">${hours} hour(s)</td></tr><tr><td style="padding:8px;color:#888">Amount</td><td style="padding:8px;text-align:right;color:#ff3f8f;font-weight:800">${amount}</td></tr></table><div style="margin-top:14px;padding:14px;background:#090909;border-radius:12px"><div style="color:#777;font-size:11px">MEETING LOCATION</div><div style="margin-top:5px">${address}</div></div><div style="margin-top:12px;padding:14px;background:#090909;border-radius:12px"><div style="color:#777;font-size:11px">CUSTOMER NOTE</div><div style="margin-top:5px;line-height:1.5">${notes}</div></div><a href="${esc(link)}" style="display:block;margin-top:20px;padding:14px;border-radius:11px;background:#ff3f8f;color:#050505;text-align:center;text-decoration:none;font-weight:900">Open Booking Requests</a></div></div><div style="padding:16px;color:#666;font-size:11px;text-align:center">ELYRA · 18+ · Lawful social companionship only</div></div></body></html>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });

  try {
    if (!url || !serviceKey || !emailKey || !fromEmail) throw new Error("Server email configuration is incomplete.");

    if (webhookSecret && req.headers.get("x-elyra-webhook-secret") !== webhookSecret) {
      return new Response(JSON.stringify({ ok: false, error: "Unauthorized" }), { status: 401, headers: { ...headers, "Content-Type": "application/json" } });
    }

    const payload = await req.json();
    const booking = recordFrom(payload);
    if (!booking) throw new Error("No booking record supplied.");

    if (booking.status && booking.status !== "pending") {
      return new Response(JSON.stringify({ ok: true, skipped: true }), { headers: { ...headers, "Content-Type": "application/json" } });
    }

    const creatorId = String(booking.creator_id || "");
    if (!creatorId) throw new Error("Booking creator_id is missing.");

    const { data: profile, error: profileError } = await admin
      .from("creator_profiles")
      .select("user_id,display_name")
      .eq("user_id", creatorId)
      .maybeSingle();

    if (profileError) throw new Error(profileError.message);
    if (!profile?.user_id) throw new Error("Creator profile not found.");

    const { data: authUser, error: authError } = await admin.auth.admin.getUserById(profile.user_id);
    if (authError) throw new Error(authError.message);

    const to = authUser.user?.email;
    if (!to) throw new Error("Creator email is not available.");

    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${emailKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: fromEmail,
        to: [to],
        subject: `ELYRA — New booking request from ${String(booking.customer_name || "a customer")}`,
        html: emailHtml(booking, profile.display_name || "Creator"),
      }),
    });

    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`Email provider error (${response.status}).`);

    return new Response(JSON.stringify({ ok: true, email_id: result?.id ?? null }), { headers: { ...headers, "Content-Type": "application/json" } });
  } catch (error) {
    console.error(error);
    return new Response(JSON.stringify({ ok: false, error: error instanceof Error ? error.message : "Unknown error" }), { status: 500, headers: { ...headers, "Content-Type": "application/json" } });
  }
});
