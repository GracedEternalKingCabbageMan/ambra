// ---------------------------------------------------------------------------
// store_log.dart — the LOUD diagnostic channel for the trade-record storage layer.
//
// Deliberately print-based (not debugPrint/dev.log) so the lines reach `adb logcat` in RELEASE builds:
// the storage layer guards preimages (the only handle to in-flight funds), and a silent failure there
// is exactly the incident class this exists to make visible (an Android keystore invalidation makes
// every secure-storage read return null — indistinguishable from "key absent" — so a trade record can
// vanish without any error ever surfacing).
//
// NEVER log record CONTENTS through this: records hold preimages/secrets. Ids, states, keys, counts
// and error strings only.
// ---------------------------------------------------------------------------

/// Log one storage-layer event, prefixed '[ambra-store]' for logcat grep.
void storeLog(String message) {
  // ignore: avoid_print
  print('[ambra-store] $message');
}
