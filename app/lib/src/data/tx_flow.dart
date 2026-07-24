import '../rust/api.dart' as core;
import 'config.dart';
import 'wallet_repository.dart';

/// Authorize (fail-closed biometric) → build the PSET → sign → broadcast.
/// Returns the txid, or throws on auth failure / build / broadcast error.
///
/// [onAboutToBroadcast] (optional) runs AFTER the biometric auth + buildPset + signPset ALL succeed and
/// IMMEDIATELY BEFORE the single irreversible [core.finalizeAndBroadcast] — the Dart twin of the web wallet's
/// `onAboutToFund` intent, fired at the SAME moment the web sets it (right before the actual on-chain
/// broadcast). A caller persists a "a broadcast may have gone out" marker here so a throw/crash on the
/// EARLIER auth/build/sign leaves NOTHING marked (the swap is droppable as pre-commitment), while a
/// throw/crash on-or-after this point keeps the swap RESUMABLE. Existing callers pass nothing and are
/// unaffected. If the hook itself throws the broadcast is NOT attempted (fail closed — same as a build/sign
/// error), which for the SELL caller correctly leaves the record droppable.
Future<String> authorizeBuildBroadcast(
  Future<String> Function(String mnemonic) buildPset, {
  Future<void> Function()? onAboutToBroadcast,
}) async {
  final ok = await WalletRepository.instance.requirePaymentAuth();
  if (!ok) throw Exception('Authentication failed or cancelled.');
  final m = await WalletRepository.instance.readMnemonic();
  if (m == null) throw Exception('wallet unavailable');
  final pset = await buildPset(m);
  final signed = await core.signPset(mnemonic: m, pset: pset);
  if (onAboutToBroadcast != null) await onAboutToBroadcast();
  return core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);
}
