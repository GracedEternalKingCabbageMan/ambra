import '../rust/api.dart' as core;
import 'config.dart';
import 'wallet_repository.dart';

/// Authorize (fail-closed biometric) → build the PSET → sign → broadcast.
/// Returns the txid, or throws on auth failure / build / broadcast error.
Future<String> authorizeBuildBroadcast(Future<String> Function(String mnemonic) buildPset) async {
  final ok = await WalletRepository.instance.requirePaymentAuth();
  if (!ok) throw Exception('Authentication failed or cancelled.');
  final m = await WalletRepository.instance.readMnemonic();
  if (m == null) throw Exception('wallet unavailable');
  final pset = await buildPset(m);
  final signed = await core.signPset(mnemonic: m, pset: pset);
  return core.finalizeAndBroadcast(mnemonic: m, esploraUrl: Backend.esplora, pset: signed);
}
