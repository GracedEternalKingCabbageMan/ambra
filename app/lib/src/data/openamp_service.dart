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

  /// Register the wallet's x-only key (idempotent) and cache the AID, ASSERTING
  /// the server AID equals the locally computed one (spec 1.3). A network/offline
  /// failure stays soft (the layer simply stays dormant), but an AID mismatch is
  /// an integrity failure and is surfaced: it means the server registered a
  /// different or additional key, and the wallet must not proceed under it.
  Future<void> ensureRegistered(String mnemonic) async {
    if (_aid != null) return;
    final String xonly;
    final String localAid;
    final String aid;
    try {
      xonly = core.openampXonlyPubkey(mnemonic: mnemonic);
      localAid = core.openampComputeAid(pubkeys: [xonly]);
      aid = await ApiClient.openampRegister([xonly]);
    } catch (_) {
      // OpenAMP not deployed / offline: stays inactive.
      return;
    }
    if (aid.isEmpty) return;
    if (aid.toLowerCase() != localAid.toLowerCase()) {
      throw Exception(
          'OpenAMP registration integrity failure: server AID $aid does not match '
          'the locally computed AID $localAid; refusing to register.');
    }
    _xonly = xonly;
    _aid = aid;
    notifyListeners();
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

  /// Draft a transfer and VERIFY it on-device before any signing (spec 0.4(3),
  /// SWK-6): recompute every enclave sighash locally, refuse on any mismatch with
  /// the server's `to_sign`, and decode the real effects for the review sheet.
  /// No key material or payment auth is needed here; [completePrepared] signs.
  ///
  /// The wallet NEVER blind-signs the server digest: for each input it rebuilds
  /// the Elements taproot sighash from the returned tx, the resolved prevouts,
  /// and its own enclave leaf + control block, and only the locally recomputed
  /// digest is ever signed.
  Future<OpenampPrepared> prepareTransfer({
    required String mnemonic,
    required String assetId,
    required String recipientAid,
    required BigInt atoms,
  }) async {
    await ensureRegistered(mnemonic);
    final sender = _aid;
    if (sender == null) throw Exception('OpenAMP account not registered');

    final draft = await ApiClient.openampCreateTransfer(
      asset: assetId,
      senderAid: sender,
      recipientAid: recipientAid,
      atoms: atoms,
    );
    if (draft.tx.isEmpty) {
      throw Exception('transfer draft is missing the unsigned transaction');
    }

    // Enumerate the draft's inputs (outpoints) by decoding with no prevouts yet.
    final probe = core.decodeEnclaveSpend(txHex: draft.tx, prevouts: const [], myScripts: const []);

    // My per-asset enclave leaf + control block + scriptPubKey (shared by all my
    // enclave inputs of this asset).
    final addr = await ApiClient.openampAddressInfo(sender, assetId);
    if (addr.transferLeaf.isEmpty || addr.transferControl.isEmpty) {
      throw Exception('enclave address is missing the transfer leaf/control');
    }

    // Resolve EVERY input's prevout, aligned by input index (taproot
    // SIGHASH_DEFAULT commits to all prevout amounts + scripts).
    final slots = List<core.EnclavePrevout?>.filled(probe.inputs.length, null);
    await Future.wait(probe.inputs.map((inp) async {
      slots[inp.index] = await ApiClient.prevoutAt(inp.txid, inp.vout);
    }));
    final prevouts = <core.EnclavePrevout>[];
    for (var i = 0; i < slots.length; i++) {
      final p = slots[i];
      if (p == null) throw Exception('could not resolve the prevout for input $i');
      prevouts.add(p);
    }

    // MANDATORY safety mechanism: recompute each sighash and refuse on mismatch.
    final genesis = core.sequentiaGenesisHash();
    final localDigests = <String, String>{};
    for (final ts in draft.toSign) {
      final idx = int.tryParse(ts.input);
      if (idx == null) throw Exception('malformed to_sign input index "${ts.input}"');
      final local = core.enclaveSighash(
        txHex: draft.tx,
        inputIndex: idx,
        prevouts: prevouts,
        leafScriptHex: addr.transferLeaf,
        controlBlockHex: addr.transferControl,
        genesisHex: genesis,
      );
      if (local.toLowerCase() != ts.sighash.toLowerCase()) {
        final srv = ts.sighash.length >= 16 ? ts.sighash.substring(0, 16) : ts.sighash;
        throw Exception('sighash mismatch at input ${ts.input} '
            '(local ${local.substring(0, 16)}… vs server $srv…); refusing to sign.');
      }
      localDigests[ts.input] = local;
    }

    // Decode the real effects with the resolved prevouts + my script for review.
    final effects = core.decodeEnclaveSpend(
      txHex: draft.tx,
      prevouts: prevouts,
      myScripts: [addr.scriptPubkey],
    );

    return OpenampPrepared(
      draftId: draft.id,
      assetId: assetId,
      localDigests: localDigests,
      effects: effects,
      convertAtoms: draft.convertAtoms,
      feeSats: draft.feeSats,
    );
  }

  /// Sign the LOCALLY RECOMPUTED digests (never the server's `to_sign`) and
  /// complete the transfer. Returns the broadcast txid. Call only after the user
  /// confirms the effects from [prepareTransfer] and payment auth has passed.
  Future<String> completePrepared(OpenampPrepared prepared, String mnemonic) async {
    final sigs = <String, String>{};
    prepared.localDigests.forEach((input, digest) {
      sigs[input] = core.openampSignSighash(mnemonic: mnemonic, sighashHex: digest);
    });
    return ApiClient.openampCompleteTransfer(prepared.draftId, sigs);
  }
}

/// A verified, ready-to-sign OpenAMP transfer: the draft id, the per-input local
/// digests the wallet recomputed and will sign, and the decoded effects to show
/// the user before they confirm.
class OpenampPrepared {
  OpenampPrepared({
    required this.draftId,
    required this.assetId,
    required this.localDigests,
    required this.effects,
    this.convertAtoms,
    this.feeSats,
  });

  /// The volatile draft id to complete against.
  final String draftId;

  /// The transacted asset id.
  final String assetId;

  /// Input key (decimal index, as returned in `to_sign`) -> the LOCALLY
  /// recomputed 32-byte sighash hex to sign. Never the server's digest.
  final Map<String, String> localDigests;

  /// The decoded, locally verified effects to render before signing.
  final core.EnclaveSpendEffects effects;

  /// Fee taken by conversion in the transacted asset (fee_mode: "convert").
  final BigInt? convertAtoms;

  /// The equivalent network fee in sats.
  final BigInt? feeSats;
}
