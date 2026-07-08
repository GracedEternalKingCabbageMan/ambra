import 'package:flutter/foundation.dart';

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';

/// Bridges the wallet to the OpenAMP restricted-asset enclave.
///
/// The wallet holds the enclave's signing key on-device: a dedicated x-only key
/// derived at m/5/0 (`core.openampXonlyPubkey`). On unlock the wallet registers
/// that key and gets an account id (AID); restricted balances are then fetched
/// and surfaced as ordinary asset rows (one among equals — no privileged label).
/// Sends draft a transfer, Schnorr-sign each enclave sighash on-device, and
/// complete. When the enclave is absent or offline the whole layer stays dormant
/// (every call fails soft), so an on-chain-only build behaves unchanged.
class OpenAmpService extends ChangeNotifier {
  OpenAmpService._();
  static final OpenAmpService instance = OpenAmpService._();

  String? _aid;
  String? _xonly;
  List<OpenAmpAsset> _assets = const [];
  List<core.AssetBalance> _balances = const [];

  /// The enclave account id, once registered. Shown on Receive.
  String? get aid => _aid;

  /// The device x-only key (m/5/0) this account is registered under.
  String? get xonly => _xonly;

  /// The restricted assets the enclave offers.
  List<OpenAmpAsset> get assets => _assets;

  /// Last-known restricted balances (atoms > 0), as ordinary [core.AssetBalance]
  /// rows so the existing balance UI renders them with no special-casing.
  List<core.AssetBalance> get balances => _balances;

  bool isRestricted(String assetId) => _assets.any((a) => a.id == assetId);

  OpenAmpAsset? assetFor(String assetId) {
    for (final a in _assets) {
      if (a.id == assetId) return a;
    }
    return null;
  }

  /// Register the wallet's x-only key (idempotent) and cache the AID. Fails soft
  /// if the enclave is unreachable — the layer simply stays dormant.
  Future<void> ensureRegistered(String mnemonic) async {
    if (_aid != null) return;
    try {
      final xonly = core.openampXonlyPubkey(mnemonic: mnemonic);
      final aid = await ApiClient.openampRegister([xonly]);
      if (aid.isEmpty) return;
      _xonly = xonly;
      _aid = aid;
      notifyListeners();
    } catch (_) {/* OpenAMP not deployed / offline: stays inactive */}
  }

  /// Refresh the restricted-asset catalogue + balances. Returns the held rows
  /// (atoms > 0). Fails soft to the last-known list if the enclave is offline.
  Future<List<core.AssetBalance>> refresh(String mnemonic) async {
    await ensureRegistered(mnemonic);
    final aid = _aid;
    if (aid == null) return _balances;
    try {
      final assets = await ApiClient.openampAssets();
      if (assets.isNotEmpty) {
        _assets = assets;
        SeqAssets.mergeOpenamp({
          for (final a in assets) a.id: AssetLabel(a.ticker, a.precision, subtitle: a.name),
        });
      }
    } catch (_) {/* keep the last-known catalogue */}

    final held = <core.AssetBalance>[];
    for (final a in _assets) {
      try {
        final atoms = await ApiClient.openampBalance(aid, a.id);
        if (atoms > BigInt.zero) {
          held.add(core.AssetBalance(assetId: a.id, atoms: atoms.toString()));
        }
      } catch (_) {/* skip this asset; others still show */}
    }
    _balances = held;
    notifyListeners();
    return held;
  }

  /// The enclave deposit address for a restricted [assetId] (for Receive).
  Future<String?> depositAddress(String assetId) async {
    final aid = _aid;
    if (aid == null) return null;
    try {
      return await ApiClient.openampAddress(aid, assetId);
    } catch (_) {
      return null;
    }
  }

  /// Draft -> sign each enclave sighash on-device -> complete. Returns the txid.
  Future<String> sendTransfer({
    required String mnemonic,
    required String assetId,
    required String recipientAid,
    required BigInt atoms,
  }) async {
    final sender = _aid;
    if (sender == null) throw Exception('OpenAMP account not registered');
    final draft = await ApiClient.openampCreateTransfer(
      asset: assetId,
      senderAid: sender,
      recipientAid: recipientAid,
      atoms: atoms,
    );
    final sigs = <String, String>{};
    for (final ts in draft.toSign) {
      sigs[ts.input] = core.openampSignSighash(mnemonic: mnemonic, sighashHex: ts.sighash);
    }
    return ApiClient.openampCompleteTransfer(draft.id, sigs);
  }
}
