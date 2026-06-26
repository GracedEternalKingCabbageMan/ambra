import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'config.dart';
import 'wallet_repository.dart';
import 'xchain_client.dart';

/// Bitcoin confirmation depth required on the SEQ leg's anchor before revealing
/// the preimage (D). 1 = the same security as accepting that much BTC at 1 conf;
/// anchoring adds no cross-chain buffer on top. See ambra-btc-wallet-build notes.
const int kAnchorDepthD = 1;

/// A modest flat fee (atoms of the claimed asset) for the SEQ claim's explicit
/// Elements fee output. Tunable; must be < the SEQ leg amount.
final BigInt kSeqClaimFee = BigInt.from(100000);

/// Local, Alice-centric state of an in-flight cross-chain swap. The wallet is the
/// source of truth (the daemon's state is in-memory and dies on restart), so this
/// is persisted to secure storage after every transition — it holds the secret +
/// outpoints that, if lost while BTC is locked, would strand the refund.
enum XStep {
  secretReady, // secret + keys + BTC HTLC built; nothing broadcast yet
  btcFunding, // BTC funding tx broadcast
  btcLocked, // BTC funding confirmed (Hp known)
  seqLocked, // daemon accepted + locked the SEQ leg
  seqVerified, // SEQ leg value-bound + anchor-safe (gate ok)
  seqClaimed, // preimage revealed (point of no return)
  btcClaimed, // maker swept the BTC; swap complete
  refunded, // BTC refunded via CLTV (aborted)
  failed,
}

class XchainSwapRecord {
  XchainSwapRecord({
    required this.step,
    required this.seqAsset,
    required this.seqAmount,
    required this.btcAmount,
    required this.feeBtc,
    required this.secretHex,
    required this.hashHex,
    required this.seqClaimPub,
    required this.btcRefundPub,
    required this.makerBtcClaimPub,
    required this.makerSeqRefundPub,
    required this.btcLocktime,
    required this.seqLocktime,
    required this.quoteId,
    required this.btcRedeemScript,
    required this.btcP2shAddress,
    required this.btcP2shSpkHex,
    this.btcFundingTxid = '',
    this.btcVout = -1,
    this.btcHp = -1,
    this.swapId = '',
    this.seqLeg,
    this.seqClaimTxid = '',
    this.btcRefundTxid = '',
  });

  XStep step;
  final String seqAsset;
  final BigInt seqAmount;
  final BigInt btcAmount;
  final BigInt feeBtc;
  final String secretHex; // NOT HD-derivable — the recovery-critical secret
  final String hashHex;
  final String seqClaimPub;
  final String btcRefundPub;
  final String makerBtcClaimPub;
  final String makerSeqRefundPub;
  final int btcLocktime;
  final int seqLocktime;
  final String quoteId;
  final String btcRedeemScript;
  final String btcP2shAddress;
  final String btcP2shSpkHex;
  String btcFundingTxid;
  int btcVout;
  int btcHp;
  String swapId;
  XSeqLeg? seqLeg;
  String seqClaimTxid;
  String btcRefundTxid;

  Map<String, dynamic> toJson() => {
        'step': step.name,
        'seqAsset': seqAsset,
        'seqAmount': seqAmount.toString(),
        'btcAmount': btcAmount.toString(),
        'feeBtc': feeBtc.toString(),
        'secretHex': secretHex,
        'hashHex': hashHex,
        'seqClaimPub': seqClaimPub,
        'btcRefundPub': btcRefundPub,
        'makerBtcClaimPub': makerBtcClaimPub,
        'makerSeqRefundPub': makerSeqRefundPub,
        'btcLocktime': btcLocktime,
        'seqLocktime': seqLocktime,
        'quoteId': quoteId,
        'btcRedeemScript': btcRedeemScript,
        'btcP2shAddress': btcP2shAddress,
        'btcP2shSpkHex': btcP2shSpkHex,
        'btcFundingTxid': btcFundingTxid,
        'btcVout': btcVout,
        'btcHp': btcHp,
        'swapId': swapId,
        'seqLeg': seqLeg?.toJson(),
        'seqClaimTxid': seqClaimTxid,
        'btcRefundTxid': btcRefundTxid,
      };

  static XchainSwapRecord fromJson(Map<String, dynamic> j) => XchainSwapRecord(
        step: XStep.values.firstWhere((s) => s.name == j['step'], orElse: () => XStep.failed),
        seqAsset: '${j['seqAsset']}',
        seqAmount: BigInt.parse('${j['seqAmount']}'),
        btcAmount: BigInt.parse('${j['btcAmount']}'),
        feeBtc: BigInt.parse('${j['feeBtc']}'),
        secretHex: '${j['secretHex']}',
        hashHex: '${j['hashHex']}',
        seqClaimPub: '${j['seqClaimPub']}',
        btcRefundPub: '${j['btcRefundPub']}',
        makerBtcClaimPub: '${j['makerBtcClaimPub']}',
        makerSeqRefundPub: '${j['makerSeqRefundPub']}',
        btcLocktime: j['btcLocktime'] as int,
        seqLocktime: j['seqLocktime'] as int,
        quoteId: '${j['quoteId']}',
        btcRedeemScript: '${j['btcRedeemScript']}',
        btcP2shAddress: '${j['btcP2shAddress']}',
        btcP2shSpkHex: '${j['btcP2shSpkHex']}',
        btcFundingTxid: '${j['btcFundingTxid'] ?? ''}',
        btcVout: (j['btcVout'] as int?) ?? -1,
        btcHp: (j['btcHp'] as int?) ?? -1,
        swapId: '${j['swapId'] ?? ''}',
        seqLeg: j['seqLeg'] == null ? null : XSeqLeg.fromJson(j['seqLeg'] as Map),
        seqClaimTxid: '${j['seqClaimTxid'] ?? ''}',
        btcRefundTxid: '${j['btcRefundTxid'] ?? ''}',
      );

  /// True once BTC is committed and the SEQ claim has NOT been revealed — the only
  /// window where the BTC refund is the recovery path.
  bool get refundable =>
      btcFundingTxid.isNotEmpty &&
      step != XStep.seqClaimed &&
      step != XStep.btcClaimed &&
      step != XStep.refunded;
}

/// Persists the single active cross-chain swap (it carries the secret, so secure
/// storage). One in-flight swap at a time keeps the wizard + recovery simple.
class XchainStore {
  XchainStore._();
  static const _key = 'ambra.xchain.active';
  static const _storage = FlutterSecureStorage();

  static Future<XchainSwapRecord?> load() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return null;
    try {
      return XchainSwapRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(XchainSwapRecord r) => _storage.write(key: _key, value: jsonEncode(r.toJson()));
  static Future<void> clear() => _storage.delete(key: _key);
}

/// Drives the cross-chain swap state machine from LOCAL state, calling the core
/// FFI + the daemon. Each method advances one step and persists. The UI gates the
/// reveal on [checkAnchor]'s `ok`, and only refunds when [XchainSwapRecord.refundable].
class XchainSwapService {
  XchainSwapService._();

  static Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  /// Quote, generate the secret + HTLC keys, build the BTC HTLC, and persist —
  /// all before any money moves. Returns the new record (UI then funds BTC).
  static Future<XchainSwapRecord> begin(String seqAsset, BigInt seqAmount) async {
    final m = await _mnemonic();
    final q = await XchainClient.quote(seqAsset, seqAmount);
    if (!(q.btcLocktime > q.seqLocktime)) {
      throw Exception('quote rejected: BTC timeout must exceed the SEQ timeout');
    }
    final secret = await core.xchainNewSecret();
    final seqClaimPub = await core.xchainSeqClaimPubkey(mnemonic: m);
    final btcRefundPub = await core.xchainBtcRefundPubkey(mnemonic: m);
    final htlc = await core.xchainBtcHtlc(
      hashHex: secret.hashHex,
      claimPubHex: q.makerBtcClaimPub, // BTC leg: maker claims with the secret
      refundPubHex: btcRefundPub, // Alice refunds via CLTV
      locktime: q.btcLocktime,
    );
    final rec = XchainSwapRecord(
      step: XStep.secretReady,
      seqAsset: seqAsset,
      seqAmount: q.seqAmount,
      btcAmount: q.btcAmount,
      feeBtc: q.feeBtc,
      secretHex: secret.secretHex,
      hashHex: secret.hashHex,
      seqClaimPub: seqClaimPub,
      btcRefundPub: btcRefundPub,
      makerBtcClaimPub: q.makerBtcClaimPub,
      makerSeqRefundPub: q.makerSeqRefundPub,
      btcLocktime: q.btcLocktime,
      seqLocktime: q.seqLocktime,
      quoteId: q.quoteId,
      btcRedeemScript: htlc.redeemScriptHex,
      btcP2shAddress: htlc.p2ShAddress,
      btcP2shSpkHex: htlc.p2ShSpkHex,
    );
    await XchainStore.save(rec);
    return rec;
  }

  /// Lock the BTC: fund the HTLC P2SH (reusing the ordinary BTC send path).
  static Future<XchainSwapRecord> fundBtc(XchainSwapRecord r, {double feeRate = 0}) async {
    final m = await _mnemonic();
    final tx = await core.btcPrepare(
      mnemonic: m,
      t4Api: Backend.testnet4,
      address: r.btcP2shAddress,
      amountSats: r.btcAmount,
      feeRate: feeRate,
    );
    final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: tx.hex);
    r
      ..btcFundingTxid = txid
      ..step = XStep.btcFunding;
    await XchainStore.save(r);
    return r;
  }

  /// Poll until the BTC HTLC funding confirms; record its vout + height (Hp).
  /// Returns true once locked.
  static Future<bool> pollBtcLock(XchainSwapRecord r) async {
    final f = await core.xchainFindBtcFunding(
      t4Api: Backend.testnet4,
      txid: r.btcFundingTxid,
      p2ShSpkHex: r.btcP2shSpkHex,
    );
    if (f.confirmations < 1 || f.height < 0) return false;
    r
      ..btcVout = f.vout
      ..btcHp = f.height
      ..step = XStep.btcLocked;
    await XchainStore.save(r);
    return true;
  }

  /// Propose the funded BTC leg; on accept, record the maker's SEQ leg.
  /// Throws [XchainFail] (in-band) — BTC_LEG_UNCONFIRMED means retry.
  static Future<XchainSwapRecord> propose(XchainSwapRecord r) async {
    final res = await XchainClient.propose(
      quoteId: r.quoteId,
      hashHex: r.hashHex,
      btcTxid: r.btcFundingTxid,
      btcVout: r.btcVout,
      btcHeight: r.btcHp,
      btcRedeemScript: r.btcRedeemScript,
      btcAmount: r.btcAmount,
      takerSeqClaimPub: r.seqClaimPub,
      takerBtcRefundPub: r.btcRefundPub,
    );
    r
      ..swapId = res.swapId
      ..seqLeg = res.seqLeg
      ..step = XStep.seqLocked;
    await XchainStore.save(r);
    return r;
  }

  /// Value-bind the SEQ leg: the daemon-reported redeemScript must equal the one
  /// Alice rebuilds, and the asset/amount must match the agreed terms. Throws on
  /// any mismatch (never reveal into a leg you can't claim / wrong asset).
  static Future<void> verifyLeg(XchainSwapRecord r) async {
    final leg = r.seqLeg;
    if (leg == null) throw Exception('no SEQ leg to verify');
    final m = await _mnemonic();
    final rebuilt = await core.xchainSeqRedeemScript(
      mnemonic: m,
      hashHex: r.hashHex,
      makerSeqRefundPubHex: r.makerSeqRefundPub,
      seqLocktime: r.seqLocktime,
    );
    if (rebuilt.toLowerCase() != leg.redeemScript.toLowerCase()) {
      throw Exception('SEQ leg redeemScript does not match — refusing to proceed');
    }
    if (leg.assetId.toLowerCase() != r.seqAsset.toLowerCase()) {
      throw Exception('SEQ leg pays the wrong asset — refusing to proceed');
    }
    if (leg.amount < r.seqAmount) {
      throw Exception('SEQ leg amount is below the agreed amount — refusing to proceed');
    }
    if (r.step.index < XStep.seqVerified.index) {
      r.step = XStep.seqVerified;
      await XchainStore.save(r);
    }
  }

  /// THE REVEAL GATE. Returns the live anchor evidence; `ok==true` means safe to
  /// claim. Computed in the core from Alice's own nodes (never the maker).
  static Future<core.AnchorEvidence> checkAnchor(XchainSwapRecord r) async {
    final leg = r.seqLeg!;
    return core.xchainVerifySeqLegSafe(
      seqEsplora: Backend.esplora,
      seqBlockHash: leg.blockHash,
      btcLegHeight: r.btcHp,
      t4Api: Backend.testnet4,
      minDepth: kAnchorDepthD,
    );
  }

  /// POINT OF NO RETURN. Verify-leg + the anchor gate MUST have passed. Builds +
  /// broadcasts the SEQ claim, revealing the preimage on-chain.
  static Future<XchainSwapRecord> claimSeq(XchainSwapRecord r) async {
    final leg = r.seqLeg!;
    await verifyLeg(r); // re-bind right before reveal
    final ev = await checkAnchor(r);
    if (!ev.ok) throw Exception('SEQ leg is not anchor-safe yet — not revealing the secret');
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m); // Alice's own tb1 (valid SEQ addr)
    final claimHex = await core.xchainSeqClaim(
      mnemonic: m,
      seqTxid: leg.txid,
      seqVout: leg.vout,
      seqAmount: leg.amount,
      seqAssetId: leg.assetId,
      destAddress: dest,
      hashHex: r.hashHex,
      makerSeqRefundPubHex: r.makerSeqRefundPub,
      seqLocktime: r.seqLocktime,
      fee: kSeqClaimFee,
      preimageHex: r.secretHex,
    );
    final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: claimHex);
    r
      ..seqClaimTxid = txid
      ..step = XStep.seqClaimed;
    await XchainStore.save(r);
    return r;
  }

  /// Observe the maker sweeping the BTC (the swap completing). Tolerates a daemon
  /// restart (404) by leaving local state as-is.
  static Future<XchainSwapRecord> pollSettle(XchainSwapRecord r) async {
    if (r.swapId.isEmpty) return r;
    try {
      final s = await XchainClient.swap(r.swapId);
      if (s.state == 'XCHAIN_SWAP_STATE_BTC_CLAIMED' && r.step != XStep.btcClaimed) {
        r.step = XStep.btcClaimed;
        await XchainStore.save(r);
      }
    } catch (_) {/* daemon may have restarted; drive from local state */}
    return r;
  }

  /// Whether the BTC refund is spendable yet (chain tip >= btcLocktime).
  static Future<bool> refundReady(XchainSwapRecord r) async {
    if (!r.refundable) return false;
    final resp =
        await http.get(Uri.parse('${Backend.testnet4}/blocks/tip/height')).timeout(const Duration(seconds: 20));
    final tip = int.tryParse(resp.body.trim()) ?? -1;
    return tip >= r.btcLocktime;
  }

  /// Refund the BTC via the CLTV/ELSE branch (only when refundable + matured).
  static Future<XchainSwapRecord> refundBtc(XchainSwapRecord r, {double feeRate = 2}) async {
    if (!r.refundable) throw Exception('this swap is not refundable (the SEQ claim was already revealed)');
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m);
    // Legacy P2SH HTLC spend ~ 200 vB; size the fee for that, not the P2WPKH estimate.
    final feeSats = BigInt.from((220 * feeRate).ceil());
    final hex = await core.xchainBtcRefund(
      mnemonic: m,
      btcTxid: r.btcFundingTxid,
      btcVout: r.btcVout,
      btcAmountSats: r.btcAmount,
      destAddress: dest,
      feeSats: feeSats,
      redeemScriptHex: r.btcRedeemScript,
      locktime: r.btcLocktime,
    );
    final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
    r
      ..btcRefundTxid = txid
      ..step = XStep.refunded;
    await XchainStore.save(r);
    return r;
  }
}
