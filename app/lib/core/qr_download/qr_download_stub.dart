/// Non-web platforms don't get a browser "save file" dialog — the button
/// that calls this is only shown when running on web anyway (see
/// admin_settings_screen.dart), so this only exists to keep the app
/// compiling for mobile/desktop targets.
void downloadPngBytes(List<int> bytes, String filename) {
  throw UnsupportedError('QR download is only available on the web admin dashboard.');
}
