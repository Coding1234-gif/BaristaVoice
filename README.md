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

### Cloning the repository

```bash
git clone https://github.com/Coding1234-gif/BaristaVoice.git
```

1. `cd app && flutter pub get`
2. Create a Supabase project, run `supabase/schema.sql` against it, then deploy the Edge Function:
   `supabase functions deploy order-agent` and set secrets `LLM_PROVIDER` (`gemini` or `groq`) and
   `LLM_API_KEY` (that provider's key).
3. Copy `app/.env.example` to `app/.env` and fill in `SUPABASE_URL` / `SUPABASE_ANON_KEY`.
4. `flutter run`

Built with **Flutter**, **Supabase** (Postgres, Realtime, Storage, Edge Functions), **Gemini or
Groq** (switchable) for the conversational order engine, and **RevenueCat** for café subscription
billing.

### Running the app

You can run on a physical Android device or an Android emulator.

**Physical phone**

1. Enable Developer Options and USB debugging on the phone.
2. Connect it by USB and accept the debugging prompt.
3. Confirm Flutter detects it:

   ```bash
   flutter devices
   ```

4. Start the app:

   ```bash
   flutter run
   ```

**Android emulator**

1. Open Android Studio, then open the Virtual Device Manager.
2. Create and start an emulator.
3. Run `flutter run` from the project directory.

Flutter will detect a connected device or running emulator automatically. If
more than one is available, it will let you choose.

### 6. Making changes

Hot reload is enabled while `flutter run` is active. Save a file and press
`r` in the terminal to reload, or `R` for a full restart.

## Testing

Run the full test suite with:

```bash
flutter test
```

Offline unit tests live in `test/unit/`. They cover small pieces of app logic
without requiring a device, a running backend, or a Supabase connection.
