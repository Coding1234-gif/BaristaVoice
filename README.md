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
Groq** (switchable) for the conversational order engine, **ElevenLabs** for text-to-speech, and
**RevenueCat** for café subscription billing.

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

No changes are needed in `app/.env` — like `LLM_API_KEY`, these are server-only secrets and are
never read by the Flutter client.

**Running it locally:** once the secrets above are set and the app is running (`flutter run`) with
`SUPABASE_URL`/`SUPABASE_ANON_KEY` configured, ask the kiosk for anything — a speaker icon appears
next to the barista's reply. Tap it to play, tap again (now a stop icon) to stop. A red-tinted
error icon appears if synthesis fails; tapping it retries.

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
