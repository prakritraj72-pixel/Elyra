# ELYRA booking email notifications

This feature sends the creator an email whenever a new booking request is inserted with `status = pending`.

## Files

- `supabase/functions/booking-email-notification/index.ts` — Supabase Edge Function that receives a booking webhook and sends the creator email through Resend.

## Server secrets

Configure these as Supabase Edge Function secrets. Never put them in GitHub Pages frontend code.

- `RESEND_API_KEY` — Resend API key.
- `RESEND_FROM_EMAIL` — verified sender, for example `ELYRA <notifications@your-domain.example>`.
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase service-role key.
- `ELYRA_BOOKING_WEBHOOK_SECRET` — random private value used by the database webhook.
- `ELYRA_SITE_URL` — `https://prakritraj72-pixel.github.io/Elyra`

`SUPABASE_URL` is normally available automatically to Supabase Edge Functions.

## Deploy

From the Supabase project, deploy the function named `booking-email-notification`.

The function should be protected by the private `ELYRA_BOOKING_WEBHOOK_SECRET` header when called by the database webhook.

## Database webhook

Create a Database Webhook for the `public.bookings` table:

- Event: `INSERT`
- Method: `POST`
- Target: the deployed `booking-email-notification` Edge Function URL
- Header: `x-elyra-webhook-secret: <same value as ELYRA_BOOKING_WEBHOOK_SECRET>`
- Content type: JSON
- Payload: record/new record payload supplied by the Supabase database webhook

The function ignores non-pending booking records.

## Email contents

The creator receives:

- customer display name
- booking date
- start/end time
- duration
- booking amount
- meeting address
- customer note
- booking ID
- link to `creator-bookings.html`

The customer's phone number is intentionally not included in this first notification email.

## Important

The existing creator booking RLS/trigger setup remains unchanged. Creators can still only change their own pending booking status from `pending` to `accepted` or `rejected`.
