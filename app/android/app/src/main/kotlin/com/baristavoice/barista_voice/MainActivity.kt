package com.baristavoice.barista_voice

import io.flutter.embedding.android.FlutterFragmentActivity

// RevenueCat's PaywallView renders a native Fragment, which requires the
// host Activity to be a FlutterFragmentActivity (not plain FlutterActivity)
// — see https://rev.cat/flutter-paywall-installation. This also requires
// the app theme to descend from Theme.AppCompat (see styles.xml) and the
// androidx.appcompat dependency (see app/build.gradle.kts).
class MainActivity : FlutterFragmentActivity()
