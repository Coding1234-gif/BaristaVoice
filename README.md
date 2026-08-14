# BaristaVoice

A conversational AI self-service ordering kiosk for independent coffee shops. Customers speak
naturally to place, question, and modify an order; the screen updates live; staff see confirmed
orders on a simple dashboard.

## Structure

- [`app/`](app/) — Flutter app (customer kiosk, staff dashboard, owner menu admin — one codebase,
  role-based screens).
- [`supabase/`](supabase/) — Postgres schema and the `order-agent` Edge Function, which holds the
  LLM API key server-side and turns a transcript + current order + menu into an updated,
  menu-grounded order state. The LLM provider (Gemini or Groq) is a manual switch via the
  `LLM_PROVIDER`/`LLM_API_KEY` secrets, not automatic failover — flip it in the Supabase dashboard
  if one provider's free tier runs dry, no redeploy needed.
- [`BaristaVoice/`](BaristaVoice/) — original static HTML/JS prototype, kept for reference.

## Getting started

1. `cd app && flutter pub get`
2. Create a Supabase project, run `supabase/schema.sql` against it, then deploy the Edge Function:
   `supabase functions deploy order-agent` and set secrets `LLM_PROVIDER` (`gemini` or `groq`) and
   `LLM_API_KEY` (that provider's key).
3. Copy `app/.env.example` to `app/.env` and fill in `SUPABASE_URL` / `SUPABASE_ANON_KEY`.
4. `flutter run`

Built with **Flutter**, **Supabase** (Postgres, Realtime, Storage, Edge Functions), **Gemini or
Groq** (switchable) for the conversational order engine, and **RevenueCat** for café subscription
billing.
