package io.sequentia.ambra

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth: its
// BiometricPrompt can only be hosted by a FragmentActivity. With a plain
// FlutterActivity, authenticate() throws `no_fragment_activity`, which made the
// app-lock and payment-auth prompts unable to appear.
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
