# BaristaVoice

A conversational AI self-service ordering kiosk for independent coffee shops. Customers speak
naturally to place, question, and modify an order; the screen updates live; staff see confirmed
orders on a simple dashboard.

## Structure

- [`app/`](app/) — Flutter app (customer kiosk, staff dashboard, owner menu admin — one codebase,
  role-based screens).
- [`supabase/`](supabase/) — Postgres schema and Edge Functions:
  - `order-agent` holds the LLM API key server-side and turns a transcript + current order + menu
    into an updated, menu-grounded order state. The LLM provider (Gemini or Groq) is a manual
    switch via the `LLM_PROVIDER`/`LLM_API_KEY` secrets, not automatic failover — flip it in the
    Supabase dashboard if one provider's free tier runs dry, no redeploy needed.
  - `tts-speak` holds the ElevenLabs API key server-side and turns the barista's reply text into
    spoken audio (see [Text-to-speech](#text-to-speech) below).
  - `pos-square-*` / `menu-square-sync` connect a café's own Square account for catalog sync and
    payments (see [POS payments (Square)](#pos-payments-square) below).
  - `menu-extractor` turns an uploaded menu photo/PDF into structured menu items.
- [`BaristaVoice/`](BaristaVoice/) — original static HTML/JS prototype, kept for reference.

## Getting started

### Cloning the repository

```bash
git clone https://github.com/Coding1234-gif/BaristaVoice.git
```

1. `cd app && flutter pub get`
2. Create a Supabase project, then run [`supabase/schema.sql`](supabase/schema.sql) against it —
   paste its full contents into the Supabase Dashboard's **SQL Editor** and run it. It's written to
   be safe to re-run any number of times (drops/recreates functions, triggers, and policies before
   redefining them) — see [Keeping the database in sync](#keeping-the-database-in-sync) if you want
   to verify a change actually landed.
3. Deploy the Edge Functions: in the Dashboard, open **Edge Functions → Create a new function**
   for each folder under [`supabase/functions/`](supabase/functions/) (`create-order`, `order-agent`,
   `menu-extractor`, `tts-speak`, `menu-square-sync`, `pos-square-sync`, `pos-square-order-submit`,
   `pos-square-order-pay`, `pos-square-terminal-checkout`), pasting in that folder's `index.ts`. (If
   you do use the Supabase CLI instead, `supabase functions deploy --all` does all of them in one
   command — see [`supabase/config.toml`](supabase/config.toml)'s header comment.)

   **JWT verification:** the five kiosk-facing functions (`create-order`, `order-agent`, `tts-speak`,
   `pos-square-terminal-checkout`, `pos-square-order-pay`) must have JWT verification **off** — the
   kiosk has no login, and with a new-format `sb_publishable_…` API key the Dart client sends no
   `Authorization` header for signed-out calls, so the gateway rejects them with *"Missing
   authorization header"*. The CLI reads this from `config.toml` (`[functions.<name>] verify_jwt =
   false`, already set); if you deploy from the Dashboard instead, switch **Verify JWT** off in each
   of those five functions' settings. Leave it on for the admin functions.
4. Under **Edge Functions → Secrets** (shared across all functions), set:
   - `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — Project Settings → API.
   - `LLM_PROVIDER` (`gemini` or `groq`) and `LLM_API_KEY` — that provider's key.
   - `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID` — see [Text-to-speech](#text-to-speech).
   - `SQUARE_ENVIRONMENT` (`sandbox` or `production`) — see
     [POS payments (Square)](#pos-payments-square).
5. Copy `app/.env.example` to a new file literally named `app/env` (**not** `.env` — the app loads
   `env` via `dotenv.load(fileName: 'env')` in `main.dart`; `.env` is kept in `.gitignore` too, but
   it isn't the file actually read) and fill in `SUPABASE_URL` / `SUPABASE_ANON_KEY`. This file holds
   client-side config only — none of the secrets from step 4 belong here.
6. For café subscription billing, see [RevenueCat setup](#café-subscription-billing-revenuecat)
   below — the app runs and every feature works without it (premium features are always unlocked
   until RevenueCat is configured).
7. `flutter run`

Built with **Flutter**, **Supabase** (Postgres, Realtime, Storage, Edge Functions), **Gemini or
Groq** (switchable) for the conversational order engine, **ElevenLabs** for text-to-speech,
**Square** for POS/payments, and **RevenueCat** for café subscription billing.

### Text-to-speech

The barista's reply can be played back as speech through **ElevenLabs**, via the `tts-speak` Edge
Function. The ElevenLabs API key never reaches the app — the client only ever calls `tts-speak`,
which holds the key server-side, exactly like `order-agent` holds the LLM key.

**How it flows:** `order-agent` returns the barista's reply text → the customer taps the speaker
icon next to it → the app splits long replies into sentence-sized chunks (`chunkTextForSpeech`) →
each chunk is sent to `tts-speak`, which streams it through ElevenLabs' `eleven_flash_v2_5` model →
the chunks play back-to-back through a single shared audio player, so the reply starts speaking as
soon as the first chunk is ready instead of waiting for the whole thing.

**Setup:**

1. Create an [ElevenLabs](https://elevenlabs.io) account and copy an API key from
   **Profile → API Keys**.
2. Pick a voice — either one of ElevenLabs' built-in voices or one from the Voice Library — and
   copy its Voice ID from the voice's **⋮ → Copy Voice ID** menu (or the Voices API).
3. In the Supabase Dashboard, open **Edge Functions → Create a new function**, name it
   `tts-speak`, and paste in the contents of
   [`supabase/functions/tts-speak/index.ts`](supabase/functions/tts-speak/index.ts), then deploy.
   (It's a single self-contained file, so pasting it directly into the Dashboard editor works —
   no CLI required.)
4. Under that function's **Secrets** (or the project's shared Edge Function secrets), set:
   - `ELEVENLABS_API_KEY` — the key from step 1.
   - `ELEVENLABS_VOICE_ID` — the voice ID from step 2.

No changes are needed in `app/env` — like `LLM_API_KEY`, these are server-only secrets and are
never read by the Flutter client.

**Running it locally:** once the secrets above are set and the app is running (`flutter run`) with
`SUPABASE_URL`/`SUPABASE_ANON_KEY` configured, ask the kiosk for anything — a speaker icon appears
next to the barista's reply. Tap it to play, tap again (now a stop icon) to stop. A red-tinted
error icon appears if synthesis fails; tapping it retries.

### Café subscription billing (RevenueCat)

Premium café-admin features (menu management, the QR code, analytics — anything wrapped in
`PremiumGate`, see [`premium_gate.dart`](app/lib/features/admin/billing/premium_gate.dart)) are
gated behind a subscription sold through **RevenueCat**. This is entirely optional for local
development: with no RevenueCat keys set, `SubscriptionService.isSupported` is `false` and every
premium feature stays unlocked (see
[`subscription_service.dart`](app/lib/data/billing/subscription_service.dart)) — same on web, which
RevenueCat's Flutter SDK doesn't support at all.

**Setup (only needed to actually test/ship the paywall):**

1. Create a project at [RevenueCat](https://app.revenuecat.com) and, under it, a Product attached to
   your Play Store/App Store app listing.
2. Create an **Entitlement** identified exactly `premium` and attach it to that Product.
3. Create an **Offering** identified exactly `default_offering` containing a Package for that
   Product.
4. Design a **Paywall** for that offering and — this is the step that's easy to miss — **Publish**
   it. A saved-but-unpublished paywall renders as a blank screen at runtime with no error.
5. Copy the platform API key(s) from **Project settings → API keys** into `app/env` as
   `REVENUECAT_API_KEY_ANDROID` / `REVENUECAT_API_KEY_IOS` (or `REVENUECAT_API_KEY_TEST`, RevenueCat's
   Test Store key, to exercise the purchase flow before real store products exist — it takes
   priority over the platform keys whenever it's set, and works on either platform).
6. **Android only:** RevenueCat's paywall UI (`purchases_ui_flutter`) renders a native Fragment, so
   `MainActivity` must extend `FlutterFragmentActivity` rather than `FlutterActivity`, and the app
   theme must descend from `Theme.AppCompat` — already done in this repo (see
   [`MainActivity.kt`](app/android/app/src/main/kotlin/com/baristavoice/barista_voice/MainActivity.kt)
   and [`styles.xml`](app/android/app/src/main/res/values/styles.xml)); worth knowing if the paywall
   ever throws `PaywallView requires the MainActivity to extend FlutterFragmentActivity`.

### POS payments (Square)

Each café connects its **own** Square account — payments settle directly into that café's bank
account, so this can't be a single shared key the way the LLM/TTS keys are. The Square access token
lives in Supabase Vault, referenced (never stored directly) from that café's row in
`pos_connections` (see [`schema.sql`](supabase/schema.sql)).

**Current state:** there is no self-serve "Connect Square" flow in the app yet — no OAuth screen,
no callback Edge Function. Wiring up a café's `pos_connections` row and Vault secret today is a
manual, per-café setup step. Building a self-serve OAuth connect flow is the natural next step
before onboarding any café beyond your own test account.

Set `SQUARE_ENVIRONMENT` (`sandbox` or `production`) and `SQUARE_CURRENCY` in the Edge Function
secrets. Also set `SQUARE_VERSION` explicitly (e.g. `2026-08-19`) rather than relying on its
per-function default — different Square functions in this repo currently fall back to different
default API versions if it's left unset.

### Keeping the database in sync

`supabase/schema.sql` is the source of truth (see its own header comment) — you always push by
re-running the whole file in the SQL Editor, and it's written to be idempotent (drops/recreates
functions, triggers, and policies rather than assuming a fresh database). To check that what's
*actually deployed* still matches this file, without needing the Supabase CLI:

```bash
pg_dump "<connection string from Project Settings → Database>" --schema-only --no-owner --no-privileges > /tmp/live_schema.sql
diff /tmp/live_schema.sql supabase/schema.sql
```

If you do use the Supabase CLI, [`supabase/config.toml`](supabase/config.toml) links this repo to
CLI commands (`supabase link`, `supabase db diff --linked`, `supabase functions deploy --all`) —
it's optional and does nothing if you never install the CLI.

### Running the app

You can run on a physical Android device or an Android emulator.

**Physical phone**

1. Enable Developer Options and USB debugging on the phone.
2. Connect it by USB and accept the debugging prompt. (If this fails, try wireless debugging instead.)
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

### Making changes

Hot reload is enabled while `flutter run` is active. Save a file and press
`r` in the terminal to reload, or `R` for a full restart.

## Testing

Run the full test suite with:

```bash
flutter test
```

Offline unit tests live in `test/unit/`. They cover small pieces of app logic
without requiring a device, a running backend, or a Supabase connection.
