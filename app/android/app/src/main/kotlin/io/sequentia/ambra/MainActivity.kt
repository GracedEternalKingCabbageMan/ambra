package io.sequentia.ambra

import android.os.Bundle
import android.view.WindowManager

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth: its
// BiometricPrompt can only be hosted by a FragmentActivity. With a plain
// FlutterActivity, authenticate() throws `no_fragment_activity`, which made the
// app-lock and payment-auth prompts unable to appear.
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    // FLAG_SECURE, app-wide. The wallet renders the recovery phrase (onboarding
    // create/verify + the "Reveal recovery phrase" sheet), balances, and receive
    // addresses. Marking the window secure keeps EVERY screen out of screenshots
    // and the OS "recents" thumbnail, so a seed screen that was on top when the
    // app was backgrounded cannot leak into the task switcher. App-wide (rather
    // than per-route) is deliberate: it has no route-tracking gap a sensitive
    // sheet could slip through.
    override fun onCreate(savedInstanceState: Bundle?) {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onCreate(savedInstanceState)
    }
}
