import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'config.dart';
import 'tx_flow.dart';
import 'wallet_repository.dart';
import 'xchain_client.dart';

/// 1e8 = exchange-rate scale (native atoms per reference unit), matching the swap
/// screen + the price server. Used to convert the native policy fee into the
/// traded asset for the asset-leg refund fee (memory principle 4).
final BigInt _kScale = BigInt.from(100000000);

/// A conservative vByte estimate for the single-input SEQ HTLC refund tx (matches
/// the core's `claim_tx_vsize`), and a default native feerate (atoms/vB) well
/// above the relay floor, so the rate-derived refund fee always clears relay.
const int _kRefundVbytes = 400;
const double _kRefundFeerateNative = 1;

/// Local, taker-centric state of an in-flight REVERSE cross-chain swap (Sequentia
/// asset -> BTC). The wallet is the source of truth (the maker/daemon state is
/// in-memory and dies on restart), so this is persisted after every transition.
///
/// The taker NEVER holds or reveals a preimage in this direction (the maker does),
/// so the "never reveal before the paying leg is anchor-safe" axiom is upheld BY
/// CONSTRUCTION. The taker's discipline is: verify the maker's BTC leg before
/// funding, wait for it to confirm (so the asset leg anchors at/above it), enforce
/// T_btc > T_seq, and refund the asset via CLTV if the maker stalls.
enum RStep {
  rQuoted, // quote fetched; nothing opened
  btcLocked, // maker locked + we verified the BTC leg
  btcConfirmed, // maker's BTC leg confirmed on OUR node
  seqFunding, // our asset HTLC broadcast (awaiting confirmation)
  seqSubmitted, // asset leg confirmed + submitted to the maker
  seqClaimed, // maker revealed the secret (preimage read from chain)
  btcClaimed, // we claimed the BTC; swap complete
  refunded, // we refunded our asset leg (aborted)
  failed,
}

class RSwapRecord {
  RSwapRecord({
    required this.step,
    required this.seqAsset,
    required this.seqAmount,
    required this.btcAmount,
    required this.feeBtc,
    required this.quoteId,
    required this.takerBtcClaimPub,
    required this.takerSeqRefundPub,
    this.swapId = '',
    this.hashHex = '',
    this.makerSeqClaimPub = '',
    this.makerBtcRefundPub = '',
    this.btcLocktime = 0,
    this.seqLocktime = 0,
    this.btcLeg,
    this.btcLegHeight = -1,
    this.seqRedeemScript = '',
    this.seqP2shAddress = '',
    this.seqP2shSpkHex = '',
    this.seqFundTxid = '',
    this.seqVout = -1,
    this.seqBlockHash = '',
    this.seqHeight = -1,
    this.preimageHex = '',
    this.btcClaimTxid = '',
    this.seqRefundTxid = '',
    this.detail = '',
  });

  RStep step;
  final String seqAsset;
  final BigInt seqAmount;
  final BigInt btcAmount;
  final BigInt feeBtc;
  final String quoteId;
  final String takerBtcClaimPub;
  final String takerSeqRefundPub;
  String swapId;
  String hashHex;
  String makerSeqClaimPub;
  String makerBtcRefundPub;
  int btcLocktime;
  int seqLocktime;
  XBtcLeg? btcLeg;
  int btcLegHeight;
  String seqRedeemScript;
  String seqP2shAddress;
  String seqP2shSpkHex;
  String seqFundTxid;
  int seqVout;
  String seqBlockHash;
  int seqHeight;
  String preimageHex;
  String btcClaimTxid;
  String seqRefundTxid;
  String detail;

  Map<String, dynamic> toJson() => {
        'step': step.name,
        'seqAsset': seqAsset,
        'seqAmount': seqAmount.toString(),
        'btcAmount': btcAmount.toString(),
        'feeBtc': feeBtc.toString(),
        'quoteId': quoteId,
        'takerBtcClaimPub': takerBtcClaimPub,
        'takerSeqRefundPub': takerSeqRefundPub,
        'swapId': swapId,
        'hashHex': hashHex,
        'makerSeqClaimPub': makerSeqClaimPub,
        'makerBtcRefundPub': makerBtcRefundPub,
        'btcLocktime': btcLocktime,
        'seqLocktime': seqLocktime,
        'btcLeg': btcLeg?.toJson(),
        'btcLegHeight': btcLegHeight,
        'seqRedeemScript': seqRedeemScript,
        'seqP2shAddress': seqP2shAddress,
        'seqP2shSpkHex': seqP2shSpkHex,
        'seqFundTxid': seqFundTxid,
        'seqVout': seqVout,
        'seqBlockHash': seqBlockHash,
        'seqHeight': seqHeight,
        'preimageHex': preimageHex,
        'btcClaimTxid': btcClaimTxid,
        'seqRefundTxid': seqRefundTxid,
        'detail': detail,
      };

  static RSwapRecord fromJson(Map<String, dynamic> j) => RSwapRecord(
        step: RStep.values.firstWhere((s) => s.name == j['step'], orElse: () => RStep.failed),
        seqAsset: '${j['seqAsset']}',
        seqAmount: BigInt.parse('${j['seqAmount']}'),
        btcAmount: BigInt.parse('${j['btcAmount']}'),
        feeBtc: BigInt.parse('${j['feeBtc']}'),
        quoteId: '${j['quoteId']}',
        takerBtcClaimPub: '${j['takerBtcClaimPub']}',
        takerSeqRefundPub: '${j['takerSeqRefundPub']}',
        swapId: '${j['swapId'] ?? ''}',
        hashHex: '${j['hashHex'] ?? ''}',
        makerSeqClaimPub: '${j['makerSeqClaimPub'] ?? ''}',
        makerBtcRefundPub: '${j['makerBtcRefundPub'] ?? ''}',
        btcLocktime: (j['btcLocktime'] as int?) ?? 0,
        seqLocktime: (j['seqLocktime'] as int?) ?? 0,
        btcLeg: j['btcLeg'] == null ? null : XBtcLeg.fromJson(j['btcLeg'] as Map),
        btcLegHeight: (j['btcLegHeight'] as int?) ?? -1,
        seqRedeemScript: '${j['seqRedeemScript'] ?? ''}',
        seqP2shAddress: '${j['seqP2shAddress'] ?? ''}',
        seqP2shSpkHex: '${j['seqP2shSpkHex'] ?? ''}',
        seqFundTxid: '${j['seqFundTxid'] ?? ''}',
        seqVout: (j['seqVout'] as int?) ?? -1,
        seqBlockHash: '${j['seqBlockHash'] ?? ''}',
        seqHeight: (j['seqHeight'] as int?) ?? -1,
        preimageHex: '${j['preimageHex'] ?? ''}',
        btcClaimTxid: '${j['btcClaimTxid'] ?? ''}',
        seqRefundTxid: '${j['seqRefundTxid'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
      );

  /// True while our asset leg is funded and the maker has NOT yet taken it — the
  /// only window where the asset-leg CLTV refund is the recovery path. Once the
  /// maker reveals (seqClaimed), the outpoint is spent and we claim the BTC instead.
  bool get refundable => seqFundTxid.isNotEmpty && step == RStep.seqSubmitted;
}

/// Persists the single active reverse cross-chain swap. Distinct key from the
/// forward BUY store so the two wizards never clobber each other.
class RSwapStore {
  RSwapStore._();
  static const _key = 'ambra.xchain.reverse.active';
  static const _storage = FlutterSecureStorage();

  static Future<RSwapRecord?> load() async {
    final s = await _storage.read(key: _key);
    if (s == null || s.isEmpty) return null;
    try {
      return RSwapRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(RSwapRecord r) => _storage.write(key: _key, value: jsonEncode(r.toJson()));
  static Future<void> clear() => _storage.delete(key: _key);
}

/// Drives the REVERSE swap state machine from LOCAL state, calling the core FFI +
/// the daemon. Each method advances one step and persists. The reveal discipline
/// is upheld by construction (the taker never holds a preimage); the safety gates
/// are [verifyMakerBtcLeg] (before funding) + [pollBtcConf] (fund only after the
/// maker's BTC leg confirms) + the T_btc > T_seq quote check + the CLTV refund.
class XchainReverseSwapService {
  XchainReverseSwapService._();

  static Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  /// Quote selling `seqAmount` of `seqAsset` for BTC + derive the taker's leg
  /// pubkeys, and persist — all before any open. Enforces T_btc > T_seq.
  static Future<RSwapRecord> begin(String seqAsset, BigInt seqAmount) async {
    final m = await _mnemonic();
    final q = await XchainClient.reverseQuote(seqAsset, seqAmount);
    if (!(q.btcLocktime > q.seqLocktime)) {
      throw Exception('quote rejected: the Bitcoin timeout must exceed the Sequentia timeout');
    }
    final btcClaimPub = await core.xchainBtcClaimPubkey(mnemonic: m);
    final seqRefundPub = await core.xchainSeqClaimPubkey(mnemonic: m); // canonical HTLC key, here the SEQ REFUND key
    final rec = RSwapRecord(
      step: RStep.rQuoted,
      seqAsset: seqAsset,
      seqAmount: q.seqAmount,
      btcAmount: q.btcAmount,
      feeBtc: q.feeBtc,
      quoteId: q.quoteId,
      takerBtcClaimPub: btcClaimPub,
      takerSeqRefundPub: seqRefundPub,
      btcLocktime: q.btcLocktime,
      seqLocktime: q.seqLocktime,
    );
    await RSwapStore.save(rec);
    return rec;
  }

  /// Open the swap: the maker locks BTC first. VERIFY its BTC leg (rebuild the
  /// redeemScript from H + our claim key + the maker's refund key + T_btc, and
  /// byte-compare) BEFORE trusting it — never fund the asset into a mismatched leg.
  static Future<RSwapRecord> open(RSwapRecord r) async {
    final o = await XchainClient.openReverse(
      quoteId: r.quoteId,
      takerBtcClaimPub: r.takerBtcClaimPub,
      takerSeqRefundPub: r.takerSeqRefundPub,
    );
    // Recompute the maker's BTC-leg redeemScript: claim = OUR key (we spend it with
    // the preimage), refund = the maker's key, locktime = T_btc.
    final rebuilt = await core.xchainBtcHtlc(
      hashHex: o.hashHex,
      claimPubHex: r.takerBtcClaimPub,
      refundPubHex: o.makerBtcRefundPub,
      locktime: o.btcLocktime,
    );
    if (rebuilt.redeemScriptHex.toLowerCase() != o.btcLeg.redeemScript.toLowerCase()) {
      throw Exception('maker BTC leg script does not match the agreed terms; refusing to fund the asset');
    }
    if (o.btcLeg.amount < r.btcAmount) {
      throw Exception('maker locked less BTC than agreed; refusing to fund the asset');
    }
    if (!(o.btcLocktime > o.seqLocktime)) {
      throw Exception('bad timeout ordering (T_btc must exceed T_seq); refusing to fund the asset');
    }
    r
      ..swapId = o.swapId
      ..hashHex = o.hashHex
      ..makerSeqClaimPub = o.makerSeqClaimPub
      ..makerBtcRefundPub = o.makerBtcRefundPub
      ..btcLocktime = o.btcLocktime
      ..seqLocktime = o.seqLocktime
      ..btcLeg = o.btcLeg
      ..step = RStep.btcLocked;
    await RSwapStore.save(r);
    return r;
  }

  /// Poll until the maker's BTC leg confirms on OUR node; record its vout + height.
  /// We fund the asset only after this, so the Sequentia leg anchors at/above it.
  static Future<bool> pollBtcConf(RSwapRecord r) async {
    final leg = r.btcLeg;
    if (leg == null) return false;
    final spk = await core.xchainBtcHtlc(
      hashHex: r.hashHex,
      claimPubHex: r.takerBtcClaimPub,
      refundPubHex: r.makerBtcRefundPub,
      locktime: r.btcLocktime,
    );
    final f = await core.xchainFindBtcFunding(t4Api: Backend.testnet4, txid: leg.txid, p2ShSpkHex: spk.p2ShSpkHex);
    if (f.confirmations < 1 || f.height < 0) return false;
    if (f.valueSats.isNotEmpty && BigInt.parse(f.valueSats) < r.btcAmount) {
      throw Exception('maker BTC output value is below the agreed amount; refusing to fund the asset');
    }
    leg.vout = f.vout;
    r
      ..btcLegHeight = f.height
      ..step = RStep.btcConfirmed;
    await RSwapStore.save(r);
    return true;
  }

  /// Fund the asset leg: build the SEQ HTLC (claim = maker, refund = us, T_seq),
  /// then send the asset to its P2SH as an EXPLICIT output. Real money moves — the
  /// caller gates this on payment auth (fail-closed, via [authorizeBuildBroadcast]).
  static Future<RSwapRecord> fundSeq(RSwapRecord r) async {
    if (r.btcLegHeight < 0) throw Exception('the maker BTC leg has not confirmed yet');
    // Idempotent recovery: never re-broadcast the asset HTLC. If already funded,
    // resume at confirmation-wait.
    if (r.seqFundTxid.isNotEmpty) return r;
    final m = await _mnemonic();
    final htlc = await core.xchainSeqHtlcReverse(
      mnemonic: m,
      hashHex: r.hashHex,
      makerSeqClaimPubHex: r.makerSeqClaimPub,
      seqLocktime: r.seqLocktime,
    );
    r
      ..seqRedeemScript = htlc.redeemScriptHex
      ..seqP2shAddress = htlc.p2ShAddress
      ..seqP2shSpkHex = htlc.p2ShSpkHex;
    await RSwapStore.save(r);
    final txid = await authorizeBuildBroadcast((mnemonic) => core.buildSendTx(
          mnemonic: mnemonic,
          esploraUrl: Backend.esplora,
          recipients: [core.Recipient(address: htlc.p2ShAddress, assetId: r.seqAsset, satoshi: r.seqAmount)],
          feeRateSatKvb: null,
          feeAsset: null,
        ));
    r
      ..seqFundTxid = txid
      ..step = RStep.seqFunding;
    await RSwapStore.save(r);
    return r;
  }

  /// Poll the Sequentia esplora until the asset-leg funding confirms; capture the
  /// HTLC vout (+ block hash/height), then submit the leg to the maker. Returns
  /// true once submitted.
  static Future<bool> pollSeqFundAndSubmit(RSwapRecord r) async {
    if (r.seqFundTxid.isEmpty) return false;
    final tx = await _seqTx(r.seqFundTxid);
    if (tx == null) return false;
    final vout = _findVout(tx, r.seqP2shSpkHex);
    final status = tx['status'] as Map?;
    final confirmed = status != null && (status['confirmed'] == true);
    if (vout >= 0) r.seqVout = vout;
    if (!confirmed) {
      await RSwapStore.save(r);
      return false;
    }
    r
      ..seqBlockHash = '${status['block_hash'] ?? ''}'
      ..seqHeight = (status['block_height'] as int?) ?? -1;
    if (r.seqVout < 0) r.seqVout = 0;
    await RSwapStore.save(r);
    // Submit the funded leg. An in-band rejection (leg not yet anchored) is a
    // retry, not a failure — stay on this step and re-submit next poll.
    await XchainClient.submitSeq(
      swapId: r.swapId,
      seqTxid: r.seqFundTxid,
      seqVout: r.seqVout,
      seqRedeemScript: r.seqRedeemScript,
      seqAmount: r.seqAmount,
      seqAssetId: r.seqAsset,
    );
    r.step = RStep.seqSubmitted;
    await RSwapStore.save(r);
    return true;
  }

  /// THE REVEAL WATCH. Read the maker's revealed preimage OFF THE CHAIN (the maker
  /// spent our asset leg to take it), validated in trusted core (sha256==H). Never
  /// trusts a counterparty message for the secret. Returns true once known.
  static Future<bool> pollReveal(RSwapRecord r) async {
    if (r.seqFundTxid.isEmpty || r.seqVout < 0) return false;
    final pre = await core.xchainReadSeqPreimage(
      seqEsplora: Backend.esplora,
      seqLegTxid: r.seqFundTxid,
      seqVout: r.seqVout,
      hashHex: r.hashHex,
    );
    if (pre == null || pre.isEmpty) return false;
    r
      ..preimageHex = pre
      ..step = RStep.seqClaimed;
    await RSwapStore.save(r);
    return true;
  }

  /// Claim the maker's BTC leg with the revealed preimage (the parent chain is
  /// anchor-supreme; this needs no Sequentia gate). Completes the swap.
  static Future<RSwapRecord> claimBtc(RSwapRecord r, {double feeRate = 2}) async {
    if (r.preimageHex.isEmpty) throw Exception('the maker has not revealed the secret yet');
    final leg = r.btcLeg!;
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m); // our own tb1
    final feeSats = BigInt.from((220 * feeRate).ceil()); // legacy P2SH HTLC spend ~ 200 vB
    final hex = await core.xchainBtcClaim(
      mnemonic: m,
      btcTxid: leg.txid,
      btcVout: leg.vout,
      btcAmountSats: leg.amount,
      destAddress: dest,
      feeSats: feeSats,
      redeemScriptHex: leg.redeemScript,
      preimageHex: r.preimageHex,
    );
    final txid = await core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
    r
      ..btcClaimTxid = txid
      ..step = RStep.btcClaimed;
    await RSwapStore.save(r);
    return r;
  }

  /// Whether the asset-leg refund is spendable yet (SEQ chain tip >= T_seq).
  static Future<bool> refundReady(RSwapRecord r) async {
    if (!r.refundable) return false;
    final tip = await _seqTipHeight();
    return tip >= 0 && tip >= r.seqLocktime;
  }

  /// Refund the asset leg via the CLTV/ELSE branch (only while refundable + the
  /// SEQ tip has reached T_seq). The fee is paid IN THE ASSET, derived from the
  /// asset's published rate and capped at half the output (never the flat forward
  /// claim fee — a valuable asset would be rejected as "Fee exceeds maximum").
  static Future<RSwapRecord> refundSeq(RSwapRecord r, Map<String, BigInt> feeRates) async {
    if (!r.refundable) throw Exception('this swap is not refundable (the asset leg is not in the refund window)');
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m); // our own SEQ address (a tb1 is a valid SEQ addr)
    final fee = _assetRefundFee(r.seqAsset, r.seqAmount, feeRates);
    final hex = await core.xchainSeqRefund(
      mnemonic: m,
      seqTxid: r.seqFundTxid,
      seqVout: r.seqVout,
      seqAmount: r.seqAmount,
      seqAssetId: r.seqAsset,
      destAddress: dest,
      feeAtoms: fee,
      redeemScriptHex: r.seqRedeemScript,
      seqLocktime: r.seqLocktime,
    );
    final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
    r
      ..seqRefundTxid = txid
      ..step = RStep.refunded;
    await RSwapStore.save(r);
    return r;
  }

  // -- per-asset fee derivation (mirrors the swap screen + web wallet) --------

  /// The asset-leg refund fee, in atoms of the traded asset: convert the native
  /// policy fee (feerate * vbytes) at the asset's published rate, min 1 atom, and
  /// cap at half the output. `rate` = atoms of the asset per 1e8 native.
  static BigInt _assetRefundFee(String assetHex, BigInt amount, Map<String, BigInt> feeRates) {
    final rate = _rateFor(assetHex, feeRates);
    final native = BigInt.from((_kRefundFeerateNative * _kRefundVbytes).ceil());
    // ceil(native * scale / rate)
    var fee = (native * _kScale + rate - BigInt.one) ~/ rate;
    if (fee < BigInt.one) fee = BigInt.one;
    final half = amount ~/ BigInt.two;
    if (fee > half) fee = half < BigInt.one ? BigInt.one : half;
    return fee;
  }

  static BigInt _rateFor(String assetHex, Map<String, BigInt> feeRates) {
    // tSEQ is priced from the /feerates feed like any asset — no SEQ=1 privilege (principle 3). Fall back
    // to the reference scale only when the feed omits tSEQ (tSEQ is then the reference itself).
    final ticker = SeqAssets.labelFor(assetHex).ticker;
    return feeRates[ticker] ?? feeRates[assetHex] ?? _kScale;
  }

  // -- Sequentia esplora helpers ---------------------------------------------

  static Future<Map<String, dynamic>?> _seqTx(String txid) async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      return jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static int _findVout(Map<String, dynamic> tx, String spkHex) {
    final outs = (tx['vout'] as List?) ?? const [];
    final want = spkHex.toLowerCase();
    for (var i = 0; i < outs.length; i++) {
      final o = outs[i] as Map?;
      if (o != null && '${o['scriptpubkey'] ?? ''}'.toLowerCase() == want) return i;
    }
    return -1;
  }

  static Future<int> _seqTipHeight() async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/blocks/tip/height'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      return int.tryParse(resp.body.trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }
}
