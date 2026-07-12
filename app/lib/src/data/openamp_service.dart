import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'wallet_cache.dart';

/// The OpenAMP tagged hash (spec 0.4(2)):
/// `tagged_hash(tag, m) = sha256(sha256(tag) || sha256(tag) || m)`, returned as
/// 64-char hex. Domain-separated from an enclave-spend sighash, so a signature
/// produced over a tagged hash can never authorize a transfer. Matches SWK
/// `lwk_wollet/src/openamp.rs::tagged_hash` byte-for-byte.
String openampTaggedHash(String tag, List<int> message) {
  final tagHash = sha256.convert(utf8.encode(tag)).bytes;
  final pre = <int>[...tagHash, ...tagHash, ...message];
  final digest = sha256.convert(pre).bytes;
  return _hex(digest);
}

/// The two OpenAMP tagged-sign tags (spec 0.4(2)). There is deliberately no
/// third, raw-digest tag: every sign path here is tagged, so the sign surface
/// structurally cannot become an enclave-spend authorization.
const String kOpenampTagChallenge = 'openamp-challenge-v1';
const String kOpenampTagDocument = 'openamp-document-v1';

/// Sign a TAGGED, non-spending OpenAMP request with the on-device m/5/0 key. The
/// tag is applied here (never by the caller), and the tagged hash — not any
/// externally supplied 32-byte value — is what reaches the Schnorr signer.
String openampSignTagged({
  required String mnemonic,
  required String tag,
  required List<int> message,
}) {
  final taggedHex = openampTaggedHash(tag, message);
  return core.openampSignSighash(mnemonic: mnemonic, sighashHex: taggedHex);
}

/// Sign a wallet-link / login challenge (tag `openamp-challenge-v1`) over the
/// UTF-8 bytes of [challenge].
String openampSignChallenge({required String mnemonic, required String challenge}) =>
    openampSignTagged(mnemonic: mnemonic, tag: kOpenampTagChallenge, message: utf8.encode(challenge));

/// Sign a document e-signature (tag `openamp-document-v1`) over the raw 32 bytes
/// of a 64-hex [docHash]. Throws if [docHash] is not exactly 32 bytes of hex, so
/// no over/under-sized value is ever tagged-signed.
String openampSignDocument({required String mnemonic, required String docHash}) {
  final bytes = _hexBytes(docHash.trim().toLowerCase());
  if (bytes.length != 32) {
    throw Exception('document hash must be 64 hex characters (32 bytes)');
  }
  return openampSignTagged(mnemonic: mnemonic, tag: kOpenampTagDocument, message: bytes);
}

String _hex(List<int> b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _hexBytes(String s) {
  if (s.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(s)) {
    throw Exception('invalid hex');
  }
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

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
  OpenAmpUser? _user;

  /// The enclave account id, once registered. Shown on Receive.
  String? get aid => _aid;

  /// The device x-only key (m/5/0) this account is registered under.
  String? get xonly => _xonly;

  /// The last-known account record (categories + frozen), for the disclosure
  /// view's frozen banner. Null until [refreshUser] runs.
  OpenAmpUser? get user => _user;

  /// True when this account is frozen by the issuer (transfers will be refused).
  bool get isFrozen => _user?.frozen == true;

  /// Whether the legacy m/3/0 identity's stranded balances can be enumerated.
  /// The wallet registers OpenAMP under m/5/0; earlier builds (and the web
  /// wallet's WW-1 path) used the m/3/0 SeqDEX-HTLC key. Ambra's core exposes no
  /// keyless m/3/0 x-only FFI, so the legacy AID cannot be reproduced byte-exact
  /// here — the disclosure view surfaces the concept read-only rather than
  /// fabricate a wrong AID/balance. Flips true once such an FFI is added.
  bool get legacyBalancesAvailable => false;

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

    await refreshUser();

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

  /// Refresh the account record (categories + frozen) for the disclosure view.
  /// Fails soft: a transient error keeps the previous record rather than
  /// blanking it (never treat a hiccup as "unfrozen -> frozen" flapping).
  Future<void> refreshUser() async {
    final aid = _aid;
    if (aid == null) return;
    try {
      _user = await ApiClient.openampUser(aid);
      notifyListeners();
    } catch (_) {/* keep the last-known record */}
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
      recipientAid: recipientAid,
      atoms: atoms,
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
    final txid = await ApiClient.openampCompleteTransfer(prepared.draftId, sigs);
    // Track the sent transfer locally (openampd has no per-holder history): the
    // History tab re-derives confirmation + Bitcoin anchor depth from this.
    if (txid.isNotEmpty) {
      final label = SeqAssets.labelFor(prepared.assetId);
      try {
        await WalletCache.addOampTransfer(OampTransfer(
          asset: prepared.assetId,
          ticker: label.ticker,
          precision: label.precision,
          recipientAid: prepared.recipientAid,
          atoms: prepared.atoms.toString(),
          txid: txid,
          time: DateTime.now().millisecondsSinceEpoch,
        ));
      } catch (_) {/* tracking is best-effort; never block the completed send */}
    }
    return txid;
  }
}

/// A verified, ready-to-sign OpenAMP transfer: the draft id, the per-input local
/// digests the wallet recomputed and will sign, and the decoded effects to show
/// the user before they confirm.
class OpenampPrepared {
  OpenampPrepared({
    required this.draftId,
    required this.assetId,
    required this.recipientAid,
    required this.atoms,
    required this.localDigests,
    required this.effects,
    this.convertAtoms,
    this.feeSats,
  });

  /// The volatile draft id to complete against.
  final String draftId;

  /// The transacted asset id.
  final String assetId;

  /// The recipient account id (for local transfer tracking).
  final String recipientAid;

  /// The transferred amount in atoms (for local transfer tracking).
  final BigInt atoms;

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
