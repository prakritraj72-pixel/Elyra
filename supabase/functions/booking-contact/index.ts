import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_KEY") ?? "";
const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  try {
    if (!url || !serviceKey) return json({ ok: false, error: "Server configuration is incomplete." }, 500);

    const authHeader = req.headers.get("authorization") || "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) return json({ ok: false, error: "Authentication required." }, 401);

    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData.user) return json({ ok: false, error: "Invalid session." }, 401);

    const body = await req.json().catch(() => ({}));
    const bookingId = String(body.booking_id || "");
    if (!bookingId) return json({ ok: false, error: "booking_id is required." }, 400);

    const { data: booking, error: bookingError } = await admin
      .from("bookings")
      .select("id,customer_id,creator_id,status,customer_name,customer_phone")
      .eq("id", bookingId)
      .maybeSingle();

    if (bookingError) return json({ ok: false, error: bookingError.message }, 500);
    if (!booking) return json({ ok: false, error: "Booking not found." }, 404);
    if (String(booking.status).toLowerCase() !== "accepted") return json({ ok: false, error: "Contact details are available only after the booking is accepted." }, 403);

    const uid = authData.user.id;
    const isCustomer = uid === booking.customer_id;
    const isCreator = uid === booking.creator_id;
    if (!isCustomer && !isCreator) return json({ ok: false, error: "You are not a participant in this booking." }, 403);

    if (isCreator) {
      const { data: customer, error: customerError } = await admin.auth.admin.getUserById(String(booking.customer_id));
      if (customerError) return json({ ok: false, error: customerError.message }, 500);
      return json({
        ok: true,
        role: "creator",
        contact: {
          name: booking.customer_name || customer.user?.user_metadata?.full_name || customer.user?.email?.split("@")[0] || "Customer",
          phone: String(booking.customer_phone || customer.user?.phone || customer.user?.user_metadata?.phone || ""),
          email: String(customer.user?.email || ""),
        },
      });
    }

    const { data: creator, error: creatorError } = await admin.auth.admin.getUserById(String(booking.creator_id));
    if (creatorError) return json({ ok: false, error: creatorError.message }, 500);
    const { data: profile } = await admin
      .from("creator_profiles")
      .select("display_name")
      .eq("user_id", booking.creator_id)
      .maybeSingle();

    return json({
      ok: true,
      role: "customer",
      contact: {
        name: profile?.display_name || creator.user?.user_metadata?.full_name || creator.user?.email?.split("@")[0] || "Creator",
        phone: String(creator.user?.phone || creator.user?.user_metadata?.phone || ""),
        email: String(creator.user?.email || ""),
      },
    });
  } catch (error) {
    console.error(error);
    return json({ ok: false, error: error instanceof Error ? error.message : "Unknown error" }, 500);
  }
});
