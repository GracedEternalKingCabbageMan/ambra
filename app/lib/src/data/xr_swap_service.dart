// ---------------------------------------------------------------------------
// xr_swap_service.dart — the REVERSE cross-chain (Sequentia asset -> on-chain BTC) taker: the mobile twin
// of the web wallet's xrswap.js driveReverse/driveSettle/resumeSeqLeg. FAITHFUL port of the verified
// driver — do NOT re-derive the checks.
//
// Roles flip from the forward lift (cross_lift_service.dart): here the taker SELLS the asset and the
// MAKER is the secret holder. Flow, over the same sealed E2E courier (cross_courier.dart):
//
//   1. terms_request {taker_seq_refund_pub, taker_btc_claim_pub, seq_amount} -> the maker locks the BTC
//      leg FIRST (testnet4 HTLC: claim = us with the secret, refund = maker after T_btc) and answers
//      btc_leg_locked with the terms riding in it. We REVERIFY the redeemScript + amounts + timelock
//      ordering before trusting anything. Nothing of ours is spent.
//   2. Wait on OUR OWN chain view for the maker's BTC lock to CONFIRM (never fund against 0-conf).
//   3. ANCHOR GATE (mandatory — the anchor-ordering value-add): wait until our Sequentia node's LIVE
//      committed Bitcoin-anchor height reaches the BTC-lock height + 1, so the block confirming our
//      asset leg anchors at/above the maker's lock and the maker's own gate passes first time. Waiting
//      is free (nothing of ours has moved); the wait ends only at the timelocks or the user, never a
//      wall clock (owner ruling 2026-07-25, ported from xrswap.js awaitAnchorReachesBtcLeg).
//   4. Re-verify the BTC leg (a reorg during the wait can vanish it), then fund the ASSET leg into a
//      Sequentia HTLC (claim = maker with the secret, refund = us after T_seq). PERSIST-BEFORE-
//      BROADCAST: the redeem script + HTLC address are persisted before the send, the broadcast intent
//      at sign time, the txid at broadcast — so no crash window can strand a funded leg unrecorded.
//   5. Announce seq_leg_funded (with the leg's REAL Bitcoin-anchor height); the maker anchor-gates then
//      claims it, revealing the secret ON SEQUENTIA. We read the preimage OFF-CHAIN from that claim
//      (a courier secret_revealed is only a verified fast-path hint), then claim the maker's BTC leg.
//   6. Refund off-ramp: after T_seq, reclaim our asset via the CLTV branch if the maker never claimed.
//
// Persistence is a MULTI-RECORD secure-storage list ('ambra.xrswaps', the TradeListStore substrate),
// with one-time never-lossy adoption of the legacy single-slot record ('ambra.xrswap.active'). Every
// save upserts by record id, so concurrent sells never clobber each other's reclaim material; the
// shared TradeSlots bound gates new dispatches. The on-chain tail (settle / claim / refund) is
// resumable across restarts, per record; pre-funding courier state is NOT resumable by design — the
// WS session dies with the process, and an unfunded record is safely abandonable (provably so, via
// the broadcast-intent flag).
//
// The chain/courier surfaces are seams ([XrChain], [XrCourier]) so the state machine is unit-testable;
// the live implementations call the SAME ambra_core FFIs the forward flow uses (xchainBtcHtlc,
// xchainSeqHtlcReverse, xchainFindBtcFunding, xchainBtcClaim, xchainSeqRefund, xchainReadSeqPreimage).
// ---------------------------------------------------------------------------

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'cross_courier.dart';
import 'seqob_client.dart' show CrossOffer;
import 'trade_slots.dart';
import 'tx_flow.dart';
import 'wallet_repository.dart';

/// How many Sequentia blocks must still remain before T_seq for an asset leg funded NOW to be claimable
/// by the maker in time (mirrors xrswap.js MIN_SEQ_CLAIM_WINDOW / the Go MinSeqFundWindow: 120 blocks,
/// ~1h at 30s slots).
const int kXrMinSeqClaimWindow = 120;

/// And on the parent chain: below this many blocks before T_btc we could no longer claim the maker's
/// BTC after it reveals, so funding would be one-sided (xrswap.js MIN_BTC_CLAIM_WINDOW).
const int kXrMinBtcClaimWindow = 6;

/// Bitcoin's canonical P2SH dust value + the drivers' per-spend fee floor/default — byte-for-byte the
/// Go xminslice.go constants (mirrored in xrswap.js). A partial slice below dust + 2x the spend fee is
/// unsettleable (the post-fee claim/refund output cannot relay), so it is refused PRE-FUND.
final BigInt kXrBtcDustLimit = BigInt.from(546);
final BigInt kXrLegSpendFeeFloor = BigInt.from(1000);
final BigInt kXrDefaultSpendFeeSats = BigInt.from(1000);

final BigInt _kScale = BigInt.from(100000000); // exchange-rate scale (atoms per 1e8 native)

/// A pre-lock failure: no maker committed any BTC, so the composer may retry the next resting offer
/// (the web driveReverse's 'retry'). Nothing was spent and nothing was persisted.
class XrNoMakerException implements Exception {
  XrNoMakerException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reverse-swap steps, mirroring xrswap.js ST + phases. `failed` is NOT treated as terminal for
/// fund-safety keying: a failed record may still hold a locked asset leg awaiting its CLTV refund —
/// abandon/refund key on the funded EVIDENCE (seqLeg / seqFundTxid / broadcastAttempted), never the step.
enum XrStep {
  btcLocked, // maker's BTC leg received + verified; nothing of ours spent
  btcConfirmed, // maker's BTC lock confirmed at btcLegHeight on our own view
  seqFunding, // redeem persisted; asset funding may be in flight (persist-before-broadcast)
  seqFunded, // asset leg confirmed + announced; waiting for the maker to reveal
  secretRevealed, // preimage learned (from the chain, or a hash-verified courier hint)
  btcClaimed, // we swept the maker's BTC — swap complete
  refunded, // asset leg reclaimed via CLTV (the maker stalled)
  failed,
}

/// The taker-funded Sequentia asset leg (set only once its funding CONFIRMS to a matched HTLC output).
class XrSeqLeg {
  XrSeqLeg({required this.txid, required this.vout, required this.blockHash});
  final String txid;
  final int vout;
  final String blockHash;

  Map<String, dynamic> toJson() => {'txid': txid, 'vout': vout, 'blockHash': blockHash};
  static XrSeqLeg fromJson(Map j) =>
      XrSeqLeg(txid: '${j['txid']}', vout: (j['vout'] as num?)?.toInt() ?? -1, blockHash: '${j['blockHash'] ?? ''}');
}

/// Local, taker-centric state of an in-flight reverse swap, persisted after every transition. Unlike the
/// forward record there is NO per-swap secret here — the BTC-claim + SEQ-refund keys are HD-derived in
/// the core — but the record still holds the only copy of the maker's terms (hash H, keys, locktimes)
/// from which the CLTV refund script is re-derived, so losing it while the asset is locked strands it.
class XrSwapRecord {
  XrSwapRecord({
    String? id,
    required this.step,
    required this.offerId,
    required this.makerPubkey,
    required this.seqAsset,
    required this.seqAmount,
    required this.btcAmount,
    required this.feeBtc,
    required this.hashHex,
    required this.makerSeqClaimPub,
    required this.makerBtcRefundPub,
    required this.takerBtcClaimPub,
    required this.takerSeqRefundPub,
    required this.btcLocktime,
    required this.seqLocktime,
    required this.btcLegTxid,
    required this.btcLegVout,
    required this.btcLegAmount,
    required this.btcLegRedeemScript,
    required this.btcP2shSpkHex,
    this.btcLegHeight = 0,
    this.seqRedeem = '',
    this.seqP2shAddress = '',
    this.seqP2shSpkHex = '',
    this.broadcastAttempted = false,
    this.seqFundTxid = '',
    this.seqLeg,
    this.preimageHex = '',
    this.btcClaimTxid = '',
    this.seqRefundTxid = '',
    this.detail = '',
  }) : id = id ?? newTradeId();

  /// Stable per-record id (multi-record store): saves upsert on it, so records never clobber.
  final String id;
  XrStep step;
  final String offerId;
  final String makerPubkey;
  final String seqAsset;
  final BigInt seqAmount; // the slice we sell (asset atoms)
  final BigInt btcAmount; // the floor-proportional BTC we receive (sats)
  final BigInt feeBtc;
  final String hashHex; // H = sha256(secret); the maker holds the secret
  final String makerSeqClaimPub; // maker claims our asset leg with the secret
  final String makerBtcRefundPub; // maker refunds its BTC leg after T_btc
  final String takerBtcClaimPub; // we claim the BTC leg with the revealed secret
  final String takerSeqRefundPub; // we refund the asset leg after T_seq
  final int btcLocktime; // T_btc (the longer leg)
  final int seqLocktime; // T_seq (the shorter leg)
  final String btcLegTxid; // the maker's BTC lock
  int btcLegVout;
  BigInt btcLegAmount;
  final String btcLegRedeemScript;
  final String btcP2shSpkHex; // the BTC HTLC P2SH spk (for find-funding)
  int btcLegHeight; // confirmation height of the maker's lock (0 = unconfirmed)
  String seqRedeem; // OUR asset-leg redeem script — persisted BEFORE any broadcast
  String seqP2shAddress; // the asset HTLC P2SH address (strand-recovery scan target)
  String seqP2shSpkHex;
  bool broadcastAttempted; // intent-before-broadcast: set at sign time, immediately pre-broadcast
  String seqFundTxid; // persisted AT broadcast
  XrSeqLeg? seqLeg; // set once the funding confirms to a matched HTLC output
  String preimageHex; // the maker's revealed secret (chain-read, or hash-verified hint)
  String btcClaimTxid;
  String seqRefundTxid;
  String detail;

  Map<String, dynamic> toJson() => {
        'id': id,
        'step': step.name,
        'offerId': offerId,
        'makerPubkey': makerPubkey,
        'seqAsset': seqAsset,
        'seqAmount': seqAmount.toString(),
        'btcAmount': btcAmount.toString(),
        'feeBtc': feeBtc.toString(),
        'hashHex': hashHex,
        'makerSeqClaimPub': makerSeqClaimPub,
        'makerBtcRefundPub': makerBtcRefundPub,
        'takerBtcClaimPub': takerBtcClaimPub,
        'takerSeqRefundPub': takerSeqRefundPub,
        'btcLocktime': btcLocktime,
        'seqLocktime': seqLocktime,
        'btcLegTxid': btcLegTxid,
        'btcLegVout': btcLegVout,
        'btcLegAmount': btcLegAmount.toString(),
        'btcLegRedeemScript': btcLegRedeemScript,
        'btcP2shSpkHex': btcP2shSpkHex,
        'btcLegHeight': btcLegHeight,
        'seqRedeem': seqRedeem,
        'seqP2shAddress': seqP2shAddress,
        'seqP2shSpkHex': seqP2shSpkHex,
        'broadcastAttempted': broadcastAttempted,
        'seqFundTxid': seqFundTxid,
        'seqLeg': seqLeg?.toJson(),
        'preimageHex': preimageHex,
        'btcClaimTxid': btcClaimTxid,
        'seqRefundTxid': seqRefundTxid,
        'detail': detail,
      };

  static XrSwapRecord fromJson(Map<String, dynamic> j) => XrSwapRecord(
        id: '${j['id'] ?? ''}'.isEmpty ? null : '${j['id']}',
        // An unrecognised persisted step decodes NON-terminal (never silently "done"): `failed` keeps the
        // record visible + its refund/abandon guards keyed on the funded evidence (the subswap lesson).
        step: XrStep.values.firstWhere((s) => s.name == j['step'], orElse: () => XrStep.failed),
        offerId: '${j['offerId'] ?? ''}',
        makerPubkey: '${j['makerPubkey'] ?? ''}',
        seqAsset: '${j['seqAsset']}',
        seqAmount: BigInt.parse('${j['seqAmount']}'),
        btcAmount: BigInt.parse('${j['btcAmount']}'),
        feeBtc: BigInt.tryParse('${j['feeBtc'] ?? '0'}') ?? BigInt.zero,
        hashHex: '${j['hashHex']}',
        makerSeqClaimPub: '${j['makerSeqClaimPub']}',
        makerBtcRefundPub: '${j['makerBtcRefundPub']}',
        takerBtcClaimPub: '${j['takerBtcClaimPub']}',
        takerSeqRefundPub: '${j['takerSeqRefundPub']}',
        btcLocktime: (j['btcLocktime'] as num).toInt(),
        seqLocktime: (j['seqLocktime'] as num).toInt(),
        btcLegTxid: '${j['btcLegTxid']}',
        btcLegVout: (j['btcLegVout'] as num?)?.toInt() ?? -1,
        btcLegAmount: BigInt.tryParse('${j['btcLegAmount'] ?? '0'}') ?? BigInt.zero,
        btcLegRedeemScript: '${j['btcLegRedeemScript']}',
        btcP2shSpkHex: '${j['btcP2shSpkHex'] ?? ''}',
        btcLegHeight: (j['btcLegHeight'] as num?)?.toInt() ?? 0,
        seqRedeem: '${j['seqRedeem'] ?? ''}',
        seqP2shAddress: '${j['seqP2shAddress'] ?? ''}',
        seqP2shSpkHex: '${j['seqP2shSpkHex'] ?? ''}',
        broadcastAttempted: j['broadcastAttempted'] == true,
        seqFundTxid: '${j['seqFundTxid'] ?? ''}',
        seqLeg: j['seqLeg'] == null ? null : XrSeqLeg.fromJson(j['seqLeg'] as Map),
        preimageHex: '${j['preimageHex'] ?? ''}',
        btcClaimTxid: '${j['btcClaimTxid'] ?? ''}',
        seqRefundTxid: '${j['seqRefundTxid'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
      );

  /// Swap finished cleanly (either side of the atomic pair resolved).
  bool get terminal => step == XrStep.btcClaimed || step == XrStep.refunded;

  /// True while our asset is (or MIGHT be) locked on-chain with the reclaim material living only in this
  /// record. Keys on the broadcast EVIDENCE, not the step: `broadcastAttempted` is set immediately before
  /// the irreversible broadcast, so an unset flag with no txid PROVES nothing was funded (clean-clearable),
  /// while a set flag keeps the record until the funding is resolved (found + settled/refunded, or the
  /// strand-recovery scan adopts/clears it). Mirrors xrswap.js onAbandon's seq_redeem keying, hardened
  /// with the subswap intent-before-broadcast discipline.
  bool get holdsOrMightHoldAsset =>
      !terminal && (seqLeg != null || seqFundTxid.isNotEmpty || broadcastAttempted);
}

/// Persists the active reverse swaps — a MULTI-RECORD list under a new key with one-time never-lossy
/// adoption of the legacy single-slot record. A read NEVER deletes stored material; only an explicit
/// per-record [remove] does. Distinct keys from the forward-cross store so the two never mix.
class XrSwapStore {
  XrSwapStore._();
  static final TradeListStore _list =
      TradeListStore(listKey: 'ambra.xrswaps', legacyKey: 'ambra.xrswap.active');

  /// Every persisted reverse-swap record. Undecodable entries are skipped but PRESERVED on disk.
  static Future<List<XrSwapRecord>> loadAll() async {
    final read = await _list.readAll();
    final out = <XrSwapRecord>[];
    for (final e in read.entries) {
      try {
        out.add(XrSwapRecord.fromJson(e));
      } catch (_) {/* preserved on disk; not drivable by this build */}
    }
    return out;
  }

  /// Compat single-record read: by [id] when given, else the first with (possible) funds, else the
  /// most recent record.
  static Future<XrSwapRecord?> load({String? id}) async {
    final all = await loadAll();
    if (all.isEmpty) return null;
    if (id != null && id.isNotEmpty) {
      for (final r in all) {
        if (r.id == id) return r;
      }
      return null;
    }
    for (final r in all) {
      if (r.holdsOrMightHoldAsset) return r;
    }
    return all.first;
  }

  static Future<void> save(XrSwapRecord r) => _list.upsert(r.toJson());

  /// Remove ONE record by id (after the guarded abandon / terminal cleanup) — never the whole store.
  static Future<void> remove(String id) => _list.removeById(id);

  /// The persisted swaps the store must protect: non-terminal AND holding (or possibly holding) a
  /// locked asset leg. The slot count + the composer's in-flight cards + resume iterate these.
  static Future<List<XrSwapRecord>> inFlightWithFunds() async =>
      (await loadAll()).where((r) => r.holdsOrMightHoldAsset).toList();

  /// TEST-ONLY full wipe.
  static Future<void> clear() => _list.wipeAll();
}

/// The courier seam the reverse driver talks through — [CrossCourier]'s exact surface, abstracted so the
/// state machine is unit-testable without a relay.
abstract class XrCourier {
  Future<void> send(Map<String, dynamic> xcmsg);
  Future<Map<String, dynamic>> recv(String wantType, {Duration timeout});
  Future<void> fail(String code, String message);
  Future<void> close();
}

class _CrossCourierXr implements XrCourier {
  _CrossCourierXr(this._c);
  final CrossCourier _c;
  @override
  Future<void> send(Map<String, dynamic> xcmsg) => _c.send(xcmsg);
  @override
  Future<Map<String, dynamic>> recv(String wantType, {Duration timeout = const Duration(seconds: 30)}) =>
      _c.recv(wantType, timeout: timeout);
  @override
  Future<void> fail(String code, String message) => _c.fail(code, message);
  @override
  Future<void> close() => _c.close();
}

/// The maker's BTC-leg funding as read from OUR OWN chain view (null = not visible yet).
class XrBtcFunding {
  XrBtcFunding({required this.vout, required this.valueSats, required this.height, required this.confirmed});
  final int vout;
  final BigInt valueSats;
  final int height;
  final bool confirmed;
}

/// A confirmed Sequentia funding output matched to OUR HTLC spk (null = not confirmed/matched yet).
class XrSeqFunding {
  XrSeqFunding({required this.vout, required this.blockHash});
  final int vout;
  final String blockHash;
}

/// The chain + core seam: every network/FFI touch the reverse driver makes, so tests can mock the world.
/// The live implementation reuses the SAME primitives as the forward flow.
abstract class XrChain {
  Future<String> takerBtcClaimPub();
  Future<String> takerSeqRefundPub();

  /// Rebuild the maker's BTC-leg HTLC from the agreed terms (claim = us, refund = maker, T_btc) — the
  /// script the maker's leg MUST byte-match before we trust it.
  Future<core.BtcHtlcInfo> btcHtlc(
      {required String hashHex, required String claimPubHex, required String refundPubHex, required int locktime});

  /// Build OUR asset-leg HTLC (claim = maker with the secret, refund = our HD key after T_seq).
  Future<core.SeqHtlcInfo> seqHtlcReverse(
      {required String hashHex, required String makerSeqClaimPubHex, required int seqLocktime});

  /// The maker's BTC lock on testnet4, by txid + our recomputed P2SH spk. Null while not visible.
  Future<XrBtcFunding?> findBtcFunding({required String txid, required String p2shSpkHex});

  Future<int> seqTipHeight(); // -1 when unreadable (a failed read is not a verdict)
  Future<int> btcTipHeight(); // -1 when unreadable

  /// Our node's LIVE anchor view — the tip's committed Bitcoin-anchor height + its health. Null when
  /// unreadable, so the caller WAITS rather than proceeding on an unknown anchor (fail closed).
  Future<({int height, bool ok})?> anchorTip();

  /// The anchor of the block confirming our asset leg, re-derived BY TXID (never a cached block hash —
  /// asking by txid asks "which block confirms this leg NOW"). anchor -1 = UNKNOWN, never 0.
  Future<({int anchor, bool onActiveChain})> legAnchor(String txid);

  /// Fund the asset HTLC: auth -> build -> sign -> [onAboutToBroadcast] -> the single irreversible
  /// broadcast. Returns the txid. The hook MUST fire immediately before the broadcast (tx_flow contract).
  Future<String> fundSeqHtlc(
      {required String address,
      required String assetId,
      required BigInt amountAtoms,
      required Future<void> Function() onAboutToBroadcast});

  /// Our asset funding, by txid: the confirmed output matching [p2shSpkHex] (never a defaulted vout 0).
  Future<XrSeqFunding?> findSeqFunding({required String txid, required String p2shSpkHex});

  /// Strand recovery: scan the HTLC address for an already-broadcast funding output paying [p2shSpkHex].
  /// Returns its txid, or null when nothing is found (fund never landed — or the backend lags: the
  /// caller must treat null as "unresolved", never as proof of emptiness while intent was recorded).
  Future<String?> findSeqFundingTxidByAddress({required String p2shAddress, required String p2shSpkHex});

  /// The maker's revealed preimage, read OFF-CHAIN from its spend of our asset leg. Null until visible.
  Future<String?> readSeqPreimage({required String seqLegTxid, required int vout, required String hashHex});

  /// Claim the maker's BTC leg with the revealed preimage. Returns the claim txid.
  Future<String> claimBtc(
      {required String btcTxid,
      required int btcVout,
      required BigInt amountSats,
      required String redeemScriptHex,
      required String preimageHex});

  /// Refund our asset leg via the CLTV branch (valid once the Sequentia tip reaches T_seq).
  Future<String> refundSeq(
      {required String seqTxid,
      required int seqVout,
      required BigInt amountAtoms,
      required String assetId,
      required String redeemScriptHex,
      required int seqLocktime});

  /// The published exchange rate for [assetHex] (atoms per 1e8 native), or null when unpriced/feed-down —
  /// used by the pre-fund dust guard (which then falls back to the flat native minimum, per xminslice.go).
  Future<BigInt?> assetRate(String assetHex);
}

/// Poll cadences + bounds. Knobs, not deadlines: the anchor wait is bounded ONLY by the timelocks (see
/// [XrSwapService.fundWindowClosed]); tests shorten the cadences to zero.
class XrTiming {
  const XrTiming({
    this.anchorPoll = const Duration(seconds: 15),
    this.btcConfPoll = const Duration(seconds: 8),
    this.btcConfMaxTries = 600,
    this.seqConfPoll = const Duration(seconds: 12),
    this.seqConfMaxTries = 240,
    this.settlePoll = const Duration(seconds: 5),
    this.settleMaxTries = 720,
    this.revealHintTimeout = const Duration(seconds: 20),
    this.btcLockedTimeout = const Duration(seconds: 30),
  });
  final Duration anchorPoll;
  final Duration btcConfPoll;
  final int btcConfMaxTries;
  final Duration seqConfPoll;
  final int seqConfMaxTries;
  final Duration settlePoll;
  final int settleMaxTries;
  final Duration revealHintTimeout;
  final Duration btcLockedTimeout;
}

/// The reverse (SELL asset for on-chain BTC) driver. Static like its siblings; the chain seam + timing
/// are swappable for tests.
class XrSwapService {
  XrSwapService._();

  static XrChain chain = XrChainLive();
  static XrTiming timing = const XrTiming();

  // ---- pure terms math (byte-for-byte mirrors of the Go daemon / xrswap.js) --------------------------

  /// ProportionalBtcFloor — the BTC (sats) the maker PAYS for `take` atoms of a `whole`-atom offer priced
  /// at `wholeBtc` sats. FLOOR is the maker's favour (the MAKER gives the BTC); a whole take returns
  /// wholeBtc EXACTLY. The Go maker recomputes the SAME value and funds its BTC leg to it, so both sides
  /// agree bit-for-bit.
  static BigInt proportionalBtcFloor(BigInt wholeBtc, BigInt take, BigInt whole) {
    if (whole <= BigInt.zero || take >= whole) return wholeBtc;
    return (wholeBtc * take) ~/ whole;
  }

  /// The smallest BTC leg (sats) a partial may create: dust + 2x the per-spend fee (xminslice.go).
  static BigInt minSafeBtcLegSats(BigInt spendFeeSats) {
    var fee = spendFeeSats;
    if (fee < kXrLegSpendFeeFloor) fee = kXrLegSpendFeeFloor;
    return kXrBtcDustLimit + BigInt.two * fee;
  }

  /// The smallest asset leg (atoms) a partial may create: the native spend fee converted to the asset's
  /// OWN atoms via the open-fee-market rate (ceil(fee*1e8/rate)), then 1 atom dust + 2x that fee. A null
  /// [rate] (unpriced / feed down) falls back to the flat native target, mirroring xminslice.go.
  static BigInt minSafeAssetLeg(BigInt? rate, BigInt spendFeeSats) {
    var fee = spendFeeSats;
    if (fee < kXrLegSpendFeeFloor) fee = kXrLegSpendFeeFloor;
    if (rate != null && rate > BigInt.zero) {
      fee = (fee * _kScale + rate - BigInt.one) ~/ rate;
      if (fee == BigInt.zero) fee = BigInt.one;
    }
    return BigInt.one + BigInt.two * fee;
  }

  /// Why this partial's BTC leg is unsafely small, or null when safe (a whole take is never a partial
  /// dust slice and is always null).
  static String? minSafeBtcReason(BigInt takeSeq, BigInt whole, BigInt btcLeg, BigInt spendFeeSats) {
    if (takeSeq >= whole) return null;
    final m = minSafeBtcLegSats(spendFeeSats);
    if (btcLeg < m) {
      return 'this amount prices to a $btcLeg-sat Bitcoin leg, below the safe minimum $m (dust + fee) - sell a larger amount';
    }
    return null;
  }

  /// Why this partial's asset leg is unsafely small, or null when safe.
  static String? minSafeAssetReason(BigInt? rate, BigInt takeSeq, BigInt whole, BigInt assetLeg, BigInt spendFeeSats) {
    if (takeSeq >= whole) return null;
    final m = minSafeAssetLeg(rate, spendFeeSats);
    if (assetLeg < m) {
      return 'this amount leaves a $assetLeg-atom asset leg, below the safe minimum $m (dust + fee) - sell a larger amount';
    }
    return null;
  }

  static String _sha256Hex(String hexStr) {
    final bytes = <int>[];
    for (var i = 0; i + 1 < hexStr.length; i += 2) {
      bytes.add(int.parse(hexStr.substring(i, i + 2), radix: 16));
    }
    return sha256.convert(bytes).toString();
  }

  static BigInt _big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
  static int _int(Object? v) => v is int ? v : int.tryParse('${v ?? 0}') ?? 0;

  // ---- fund-window guard (the ONLY thing allowed to end the anchor wait automatically) ---------------

  /// Why funding is no longer safe, or null while it still is. A flat wall-clock timeout is deliberately
  /// absent (owner ruling, ported from xrswap.js fundWindowClosed): contested blocks take as long as they
  /// take, and it is the USER who decides when that is intolerable. A chain read that FAILS is not a
  /// verdict — it contributes nothing and we keep waiting.
  static Future<String?> fundWindowClosed(XrSwapRecord r) async {
    try {
      final seqNow = await chain.seqTipHeight();
      if (seqNow >= 0 && r.seqLocktime > 0 && seqNow + kXrMinSeqClaimWindow >= r.seqLocktime) {
        return 'the Sequentia chain has moved to block $seqNow, leaving less than $kXrMinSeqClaimWindow blocks before '
            'your asset refund at ${r.seqLocktime} - an asset leg funded now could not be taken in time, so nothing was spent';
      }
    } catch (_) {}
    try {
      final btcNow = await chain.btcTipHeight();
      if (btcNow >= 0 && r.btcLocktime > 0 && btcNow + kXrMinBtcClaimWindow >= r.btcLocktime) {
        return "Bitcoin has reached block $btcNow, too close to the maker's refund at ${r.btcLocktime} for you to "
            'claim the BTC afterwards - nothing was spent';
      }
    } catch (_) {}
    return null;
  }

  // ---- the driver ------------------------------------------------------------------------------------

  /// SELL [requestedAtoms] (null / >= the offer = the whole offer) of [offer]'s asset for on-chain BTC.
  /// One consent is taken by the CALLER before this runs (review == execution: show the caller
  /// [proportionalBtcFloor] of the slice, which is exactly what settles). Throws [XrNoMakerException]
  /// when no maker committed any BTC (retriable down the book — nothing spent, nothing persisted); any
  /// post-lock failure is terminal for THIS swap and surfaces via the persisted record.
  static Future<XrSwapRecord> sellForBtc(CrossOffer offer,
      {BigInt? requestedAtoms, void Function(String)? onStep}) async {
    final oSeq = offer.assetAtoms;
    final oBtc = offer.btcSats;
    final whole = requestedAtoms == null || requestedAtoms <= BigInt.zero || requestedAtoms >= oSeq;
    final takeSeq = whole ? oSeq : requestedAtoms;

    XrCourier courier;
    try {
      final c = await CrossCourier.open(
        offerId: offer.offerId,
        makerPubHex: offer.makerPubkey,
        takeAmount: takeSeq,
      );
      courier = _CrossCourierXr(c);
    } catch (_) {
      throw XrNoMakerException('The maker did not respond. Nothing was spent - try the next offer.');
    }
    return runWithCourier(
      courier,
      offerId: offer.offerId,
      makerPubkey: offer.makerPubkey,
      seqAsset: offer.seqAsset,
      offerAssetAtoms: oSeq,
      offerBtcSats: oBtc,
      takeSeq: takeSeq,
      onStep: onStep,
    );
  }

  /// The full reverse handshake over an already-open [courier] — split out so tests can inject a fake.
  @visibleForTesting
  static Future<XrSwapRecord> runWithCourier(
    XrCourier courier, {
    required String offerId,
    required String makerPubkey,
    required String seqAsset,
    required BigInt offerAssetAtoms,
    required BigInt offerBtcSats,
    required BigInt takeSeq,
    void Function(String)? onStep,
  }) async {
    void step(String s) => onStep?.call(s);

    // SHARED SLOT GATE (web tradeSlotsFree): records upsert by id so a second sell can never overwrite
    // a record protecting a locked asset leg — the single-slot hard refusal is replaced by the bounded
    // concurrent-trade count across all rail-crossing kinds.
    final refusal = await TradeSlots.refusalIfFull();
    if (refusal != null) {
      await courier.close();
      throw Exception(refusal);
    }

    // Price OUR slice at the offer's OWN ratio, FLOOR (the maker's favour) — the SAME value the maker
    // recomputes and funds its BTC leg to. Fail CLOSED pre-session on a slice that cannot fit.
    final wantBtc = proportionalBtcFloor(offerBtcSats, takeSeq, offerAssetAtoms);
    if (offerAssetAtoms <= BigInt.zero ||
        offerBtcSats <= BigInt.zero ||
        takeSeq <= BigInt.zero ||
        takeSeq > offerAssetAtoms ||
        wantBtc <= BigInt.zero) {
      await courier.close();
      throw Exception('That sell amount does not fit this offer - nothing was spent.');
    }
    // MIN-SLICE DUST GUARD (xminslice.go / xrswap.js): refuse an unsettleable partial BEFORE any coin
    // moves — the BTC leg we will CLAIM and the asset leg we will FUND must both clear dust + fees.
    BigInt? rate;
    try {
      rate = await chain.assetRate(seqAsset);
    } catch (_) {
      rate = null;
    }
    final dust = minSafeBtcReason(takeSeq, offerAssetAtoms, wantBtc, kXrDefaultSpendFeeSats) ??
        minSafeAssetReason(rate, takeSeq, offerAssetAtoms, takeSeq, kXrDefaultSpendFeeSats);
    if (dust != null) {
      await courier.close();
      throw Exception('$dust - nothing was spent.');
    }

    final btcClaimPub = await chain.takerBtcClaimPub();
    final seqRefundPub = await chain.takerSeqRefundPub();

    // 1. Terms request; the maker locks BTC FIRST and answers btc_leg_locked. A failure before any leg
    //    arrives means NO maker committed BTC -> retriable (XrNoMakerException). seq_amount is a JSON
    //    NUMBER: the Go uint64 field rejects a quoted string.
    step('Contacting the maker…');
    Map<String, dynamic> locked;
    try {
      await courier.send({
        'type': XcType.termsRequest,
        'taker_seq_refund_pub': seqRefundPub,
        'taker_btc_claim_pub': btcClaimPub,
        'seq_amount': takeSeq.toInt(),
      });
      locked = await courier.recv(XcType.btcLegLocked, timeout: timing.btcLockedTimeout);
    } catch (_) {
      await courier.close();
      throw XrNoMakerException('The maker did not lock any Bitcoin. Nothing was spent - try the next offer.');
    }

    // The record id, hoisted so the post-courier settle tail can reload THIS record by id.
    late final String recId;
    try {
      final leg = (locked['leg'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      final tBtc = _int(leg['locktime']) != 0 ? _int(leg['locktime']) : _int(locked['btc_locktime']);
      final tSeq = _int(locked['seq_locktime']);
      final mBtcAmount = _big(locked['btc_amount']);
      final mSeqAmount = _big(locked['seq_amount']);
      final hashHex = '${locked['hash_h'] ?? ''}'.toLowerCase();
      final makerSeqClaimPub = '${locked['maker_seq_claim_pub'] ?? ''}';
      final makerBtcRefundPub = '${locked['maker_refund_pub'] ?? ''}';

      // Rebuild the BTC-leg script OURSELVES (claim = us with the preimage, refund = maker after T_btc);
      // byte-mismatch = not the leg we agreed to. Also derives the P2SH spk our find-funding keys on.
      final rebuilt = await chain.btcHtlc(
        hashHex: hashHex,
        claimPubHex: btcClaimPub,
        refundPubHex: makerBtcRefundPub,
        locktime: tBtc,
      );

      final rec = XrSwapRecord(
        step: XrStep.btcLocked,
        offerId: offerId,
        makerPubkey: makerPubkey,
        seqAsset: seqAsset,
        seqAmount: takeSeq,
        btcAmount: wantBtc,
        feeBtc: _big(locked['fee_btc']),
        hashHex: hashHex,
        makerSeqClaimPub: makerSeqClaimPub,
        makerBtcRefundPub: makerBtcRefundPub,
        takerBtcClaimPub: btcClaimPub,
        takerSeqRefundPub: seqRefundPub,
        btcLocktime: tBtc,
        seqLocktime: tSeq,
        btcLegTxid: '${leg['txid'] ?? ''}',
        btcLegVout: _int(leg['vout']),
        btcLegAmount: _big(leg['amount']),
        btcLegRedeemScript: '${leg['redeem_script'] ?? ''}',
        btcP2shSpkHex: rebuilt.p2ShSpkHex,
      );
      recId = rec.id;

      // 2. Reject bad terms BEFORE funding — slice-vs-slice binding (mirrors xdriver_reverse.go:182-189
      //    and xrswap.js): the maker must pay exactly the proportional BTC for OUR slice, in the terms
      //    field AND the funded leg, and size the trade to takeSeq. Nothing is spent on abort.
      if (mBtcAmount != wantBtc || rec.btcLegAmount != wantBtc) {
        return _failAbort(courier, rec, 'terms_mismatch',
            'the maker did not lock the proportional BTC for your slice - nothing was spent');
      }
      if (mSeqAmount != takeSeq) {
        return _failAbort(courier, rec, 'terms_mismatch',
            'the maker sized the trade differently from your slice - nothing was spent');
      }
      if (hashHex.isEmpty || makerSeqClaimPub.isEmpty || makerBtcRefundPub.isEmpty || rec.btcLegTxid.isEmpty) {
        return _failAbort(courier, rec, 'terms_mismatch', 'the maker sent incomplete terms - nothing was spent');
      }
      if (rebuilt.redeemScriptHex.toLowerCase() != rec.btcLegRedeemScript.toLowerCase()) {
        return _failAbort(courier, rec, 'btc_leg_invalid',
            'maker BTC-leg script does not match the agreed terms - do not fund - nothing was spent');
      }
      if (!(tBtc > tSeq)) {
        return _failAbort(
            courier, rec, 'btc_leg_invalid', 'bad timeout ordering (T_btc must exceed T_seq) - nothing was spent');
      }
      // T_seq FLOOR: ordering alone is not enough — a T_seq only a few blocks above the tip would be
      // dead on arrival (inside its own refund margin before the anchor gate can run). A tip read that
      // FAILS is not a verdict; fundWindowClosed re-reads immediately before funding.
      try {
        final tip = await chain.seqTipHeight();
        if (tip >= 0 && tSeq > 0 && tSeq < tip + kXrMinSeqClaimWindow) {
          return _failAbort(courier, rec, 'btc_leg_invalid',
              "the maker's asset timeout T_seq=$tSeq is only ${tSeq - tip} blocks above the current Sequentia tip "
              '$tip; this wallet needs at least $kXrMinSeqClaimWindow to settle safely - nothing was spent');
        }
      } catch (_) {}

      await XrSwapStore.save(rec);

      // 3. Wait for the maker's BTC lock to confirm ON OUR OWN VIEW, verifying the ACTUAL on-chain value
      //    meets the agreed amount (a maker can report the agreed amount yet lock less).
      step("Waiting for the maker's Bitcoin lock to confirm…");
      var height = 0;
      for (var i = 0; i < timing.btcConfMaxTries && height == 0; i++) {
        XrBtcFunding? f;
        try {
          f = await chain.findBtcFunding(txid: rec.btcLegTxid, p2shSpkHex: rec.btcP2shSpkHex);
        } catch (_) {
          f = null; // transient; keep polling
        }
        if (f != null && f.confirmed && f.height > 0) {
          if (f.valueSats < rec.btcAmount) {
            return _failAbort(courier, rec, 'btc_leg_invalid',
                "the maker's on-chain BTC lock (${f.valueSats} sats) is less than the agreed ${rec.btcAmount} - "
                'nothing of yours was spent');
          }
          rec
            ..btcLegVout = f.vout
            ..btcLegAmount = f.valueSats;
          height = f.height;
          break;
        }
        final closed = await fundWindowClosed(rec);
        if (closed != null) return _failAbort(courier, rec, 'fund_window_closed', closed);
        await Future<void>.delayed(timing.btcConfPoll);
      }
      if (height == 0) {
        return _failAbort(courier, rec, 'btc_leg_unconfirmed',
            "the maker's BTC lock did not confirm in time - nothing of yours was spent");
      }
      rec
        ..btcLegHeight = height
        ..step = XrStep.btcConfirmed;
      await XrSwapStore.save(rec);

      // 4. ANCHOR PRECONDITION — MANDATORY, and it must happen BEFORE the asset moves (a block's
      //    committed anchor is frozen at confirmation; a wait afterwards can never clear it). Target is
      //    the lock height PLUS ONE, absorbing the maker's own between-two-reads race (waiting longer is
      //    never unsafe). The wait ends only at the timelocks (fundWindowClosed) — never a wall clock.
      step("Waiting for Sequentia to anchor at or above the maker's Bitcoin lock…");
      final target = height + 1;
      for (;;) {
        ({int height, bool ok})? st;
        try {
          st = await chain.anchorTip();
        } catch (_) {
          st = null; // unreadable: wait, never proceed on an unknown anchor
        }
        if (st != null && st.ok && st.height >= target) break;
        final closed = await fundWindowClosed(rec);
        if (closed != null) return _failAbort(courier, rec, 'anchor_not_caught_up', closed);
        await Future<void>.delayed(timing.anchorPoll);
      }

      // 4b. RE-VERIFY the maker's BTC leg: the anchor wait is bounded by timelocks, not a clock, and one
      //     parent-chain reorg is all the maker needs to double-spend the input it funded with. Funding
      //     against a dead (or moved) BTC leg is the one-sided loss this gate exists to prevent.
      {
        XrBtcFunding? f2;
        try {
          f2 = await chain.findBtcFunding(txid: rec.btcLegTxid, p2shSpkHex: rec.btcP2shSpkHex);
        } catch (_) {
          f2 = null;
        }
        if (f2 == null || !f2.confirmed || f2.valueSats < rec.btcAmount) {
          return _failAbort(courier, rec, 'btc_leg_gone',
              "the maker's BTC lock is no longer on chain with the agreed amount - your asset was NOT funded, "
              'nothing of yours was spent');
        }
        if (f2.height != height) {
          return _failAbort(courier, rec, 'btc_leg_gone',
              "the maker's BTC lock moved from block $height to ${f2.height} (a Bitcoin reorg) - your asset was "
              'NOT funded, nothing of yours was spent');
        }
        final closed = await fundWindowClosed(rec);
        if (closed != null) return _failAbort(courier, rec, 'seq_window_closed', closed);
      }

      // 5. Fund our asset leg. PERSIST-BEFORE-BROADCAST: the redeem script + HTLC address are saved
      //    before the send; broadcastAttempted at sign time (immediately before the irreversible
      //    broadcast); the txid at broadcast. No crash window strands a funded leg unrecorded.
      step('Locking your asset on Sequentia…');
      final htlc = await chain.seqHtlcReverse(
        hashHex: rec.hashHex,
        makerSeqClaimPubHex: rec.makerSeqClaimPub,
        seqLocktime: rec.seqLocktime,
      );
      rec
        ..seqRedeem = htlc.redeemScriptHex
        ..seqP2shAddress = htlc.p2ShAddress
        ..seqP2shSpkHex = htlc.p2ShSpkHex
        ..step = XrStep.seqFunding;
      await XrSwapStore.save(rec);
      if (rec.seqFundTxid.isEmpty) {
        final txid = await chain.fundSeqHtlc(
          address: htlc.p2ShAddress,
          assetId: rec.seqAsset,
          amountAtoms: rec.seqAmount,
          onAboutToBroadcast: () async {
            rec.broadcastAttempted = true;
            await XrSwapStore.save(rec);
          },
        );
        rec.seqFundTxid = txid;
        await XrSwapStore.save(rec);
      }

      // 5b. Confirmation + announcement: wait for the funding, run the post-fund anchor assertion,
      //     announce seq_leg_funded, take the reveal fast-path hint. `false` = the leg confirmed
      //     UNDER-ANCHORED and was withheld — do NOT invite the settle tail now (the refund off-ramp
      //     keys on the persisted seqLeg; a later [resume] still settles if the maker claims anyway).
      final announced = await _confirmAndAnnounceSeqLeg(rec, courier, step);
      if (!announced) return rec;
    } finally {
      await courier.close();
    }

    // 6. Settle on-chain (courier no longer needed): read the revealed secret from the maker's claim and
    //    claim the BTC leg. Resumable across restarts. Reload THIS record by id (multi-record store).
    final rec2 = await XrSwapStore.load(id: recId);
    if (rec2 != null && !rec2.terminal && rec2.step != XrStep.failed && rec2.seqLeg != null) {
      return settle(rec2, onStep: onStep);
    }
    return (await XrSwapStore.load(id: recId))!;
  }

  /// Wait for OUR asset funding to confirm to a matched HTLC output (FAIL CLOSED on an spk no-match —
  /// never default the vout to 0), assert its anchor, announce it, and take the courier reveal hint.
  /// Returns false when the leg confirmed under-anchored and was withheld from the maker.
  static Future<bool> _confirmAndAnnounceSeqLeg(
      XrSwapRecord rec, XrCourier courier, void Function(String) step) async {
    step('Waiting for your asset lock to confirm (about one block)…');
    XrSeqFunding? conf;
    for (var i = 0; i < timing.seqConfMaxTries && conf == null; i++) {
      try {
        conf = await chain.findSeqFunding(txid: rec.seqFundTxid, p2shSpkHex: rec.seqP2shSpkHex);
      } catch (_) {
        conf = null; // transient
      }
      if (conf == null) await Future<void>.delayed(timing.seqConfPoll);
    }
    if (conf == null) {
      throw Exception('your asset lock has not confirmed to a matched HTLC output yet; it stays resumable and is '
          'refundable after block ${rec.seqLocktime}');
    }
    rec
      ..seqLeg = XrSeqLeg(txid: rec.seqFundTxid, vout: conf.vout, blockHash: conf.blockHash)
      ..step = XrStep.seqFunded;
    await XrSwapStore.save(rec);

    // POST-FUNDING ASSERTION (not a log line): a Sequentia reorg can land our funding on a lower-anchored
    // branch — exactly the leg that could outlive the maker's BTC leg, i.e. our own money. If it did, do
    // NOT invite the claim (a courtesy: the maker can find the P2SH itself; the real defences are the
    // precondition above and the maker's own gate). anchor -1 = UNKNOWN, withheld, never treated as fine.
    ({int anchor, bool onActiveChain}) ev;
    try {
      ev = await chain.legAnchor(rec.seqLeg!.txid);
    } catch (_) {
      ev = (anchor: -1, onActiveChain: false);
    }
    final legAnchor = (ev.anchor >= 0 && ev.onActiveChain) ? ev.anchor : null;
    if (legAnchor == null || legAnchor < rec.btcLegHeight) {
      rec.detail = 'your asset leg landed in a Sequentia block anchored at '
          '${legAnchor == null ? 'an unreadable height' : '$legAnchor'} - below the maker\'s BTC lock at '
          '${rec.btcLegHeight}. It was NOT offered to the maker; you reclaim it after block ${rec.seqLocktime}.';
      await XrSwapStore.save(rec);
      try {
        await courier.fail('seq_leg_underanchored',
            'our asset leg confirmed under-anchored; do NOT claim it (we refund it after T_seq) - refund your BTC after T_btc');
      } catch (_) {}
      return false; // the refund off-ramp keys on seqLeg, which is set: the asset is recoverable
    }

    await courier.send({
      'type': XcType.seqLegFunded,
      'leg': {
        'txid': rec.seqLeg!.txid,
        'vout': rec.seqLeg!.vout,
        'amount': rec.seqAmount.toInt(),
        'asset': rec.seqAsset,
        'redeem_script': rec.seqRedeem,
        'locktime': rec.seqLocktime,
        'block_hash': rec.seqLeg!.blockHash,
        'anchor_height': legAnchor,
      },
    });
    step('Asset leg funded - waiting for the maker to reveal the secret…');

    // Fast path: a courtesy secret_revealed. Accept ONLY if it hashes to H (else it is worthless); the
    // authoritative source is the on-chain read in [settle], so a withheld/bogus message costs nothing.
    try {
      final rev = await courier.recv(XcType.secretRevealed, timeout: timing.revealHintTimeout);
      final pre = '${rev['preimage'] ?? ''}'.toLowerCase();
      if (pre.isNotEmpty && _sha256Hex(pre) == rec.hashHex) {
        rec.preimageHex = pre;
        await XrSwapStore.save(rec);
      }
    } catch (_) {/* the on-chain read will find it */}
    return true;
  }

  /// The courier-independent tail: poll for the revealed secret (persisted hint, else read OFF-CHAIN
  /// from the maker's asset-leg claim), then claim the maker's BTC leg. The RESUME entrypoint once the
  /// asset leg is funded. Idempotent.
  static Future<XrSwapRecord> settle(XrSwapRecord rec, {void Function(String)? onStep}) async {
    void step(String s) => onStep?.call(s);
    final leg = rec.seqLeg;
    if (leg == null) throw Exception('no funded asset leg to settle');
    if (rec.btcClaimTxid.isNotEmpty || rec.terminal) return rec;

    step('Waiting for the maker to reveal the secret on Sequentia…');
    for (var i = 0; i < timing.settleMaxTries && rec.preimageHex.isEmpty; i++) {
      try {
        final pre = await chain.readSeqPreimage(seqLegTxid: leg.txid, vout: leg.vout, hashHex: rec.hashHex);
        if (pre != null && pre.isNotEmpty) {
          rec
            ..preimageHex = pre.toLowerCase()
            ..step = XrStep.secretRevealed;
          await XrSwapStore.save(rec);
          break;
        }
      } catch (_) {/* transient; keep polling */}
      await Future<void>.delayed(timing.settlePoll);
    }
    if (rec.preimageHex.isEmpty) {
      throw Exception('the maker has not revealed the secret yet; the swap stays resumable, and your asset is '
          'refundable after block ${rec.seqLocktime} if the maker never takes it');
    }
    if (rec.step.index < XrStep.secretRevealed.index) {
      rec.step = XrStep.secretRevealed;
      await XrSwapStore.save(rec);
    }

    step('Claiming your Bitcoin…');
    final txid = await chain.claimBtc(
      btcTxid: rec.btcLegTxid,
      btcVout: rec.btcLegVout,
      amountSats: rec.btcLegAmount,
      redeemScriptHex: rec.btcLegRedeemScript,
      preimageHex: rec.preimageHex,
    );
    rec
      ..btcClaimTxid = txid
      ..step = XrStep.btcClaimed
      ..detail = '';
    await XrSwapStore.save(rec);
    step('Swap complete - you received BTC for your asset.');
    return rec;
  }

  /// Resume the ON-CHAIN TAIL of a persisted swap after a restart (xrswap.js renderReverse's ladder).
  /// Pre-funding courier state is NOT resumable by design (the WS session died with the process — an
  /// unfunded record is safely abandonable); everything from the broadcast on IS:
  ///   seqLeg set            -> settle (read the revealed secret + claim the BTC)
  ///   seqFundTxid persisted -> the app died in the confirm wait: re-confirm, adopt the leg, settle
  ///   broadcast intent only -> fund() threw after the node may have accepted the tx (a lost response):
  ///                            scan the HTLC address, ADOPT the found txid, then resume — never re-fund.
  /// Returns the record (possibly advanced), or null when nothing is persisted. With the multi-record
  /// store, EVERY non-terminal record is resumed INDEPENDENTLY (one stuck maker never blocks another
  /// record's settle/refund); [record] targets a specific one (the resume sheet). The return value is
  /// the targeted record when given, else the first record touched (compat).
  static Future<XrSwapRecord?> resume({void Function(String)? onStep, XrSwapRecord? record}) async {
    if (record != null) return _resumeOne(record, onStep: onStep);
    List<XrSwapRecord> recs;
    try {
      recs = await XrSwapStore.loadAll();
    } catch (_) {
      return null;
    }
    XrSwapRecord? first;
    await Future.wait([
      for (final r in recs)
        if (!r.terminal)
          _resumeOne(r, onStep: onStep).then((v) => first ??= v).catchError((Object _) => null),
    ]);
    return first;
  }

  static Future<XrSwapRecord?> _resumeOne(XrSwapRecord rec, {void Function(String)? onStep}) async {
    if (rec.terminal) return rec;
    if (rec.seqLeg != null) {
      if (rec.btcClaimTxid.isNotEmpty) return rec;
      return settle(rec, onStep: onStep);
    }
    if (rec.seqFundTxid.isNotEmpty) {
      await resumeSeqLeg(rec);
      if (rec.seqLeg != null) return settle(rec, onStep: onStep);
      return rec;
    }
    if (rec.broadcastAttempted && rec.seqRedeem.isNotEmpty) {
      // STRAND RECOVERY: intent was recorded but no txid — the broadcast MAY have landed. Scan the HTLC
      // address for the funding output; adopt its txid and resume. Nothing found = unresolved (a backend
      // can lag), NOT proof of emptiness: the record stays, and [canAbandon] keeps refusing to clear it.
      String? found;
      try {
        found = await chain.findSeqFundingTxidByAddress(
            p2shAddress: rec.seqP2shAddress, p2shSpkHex: rec.seqP2shSpkHex);
      } catch (_) {
        found = null;
      }
      if (found != null && found.isNotEmpty) {
        rec.seqFundTxid = found;
        await XrSwapStore.save(rec);
        await resumeSeqLeg(rec);
        if (rec.seqLeg != null) return settle(rec, onStep: onStep);
      }
      return rec;
    }
    return rec; // pre-funding: nothing of ours is at risk
  }

  /// Recover an asset leg that was BROADCAST before a restart. NEVER funds: it reuses the persisted
  /// seqFundTxid, waits for the confirmation and records the leg (which the refund off-ramp keys on).
  /// There is deliberately no re-announce — the courier session is gone and its keys were per-session;
  /// the maker either already saw the leg, or it did not and we refund after T_seq.
  @visibleForTesting
  static Future<XrSwapRecord> resumeSeqLeg(XrSwapRecord rec) async {
    if (rec.seqLeg != null) return rec;
    if (rec.seqFundTxid.isEmpty) throw Exception('nothing to resume: the asset leg was never broadcast');
    if (rec.seqRedeem.isEmpty) throw Exception('nothing to resume: the asset-leg script was not persisted');
    XrSeqFunding? conf;
    for (var i = 0; i < timing.seqConfMaxTries && conf == null; i++) {
      try {
        conf = await chain.findSeqFunding(txid: rec.seqFundTxid, p2shSpkHex: rec.seqP2shSpkHex);
      } catch (_) {
        conf = null;
      }
      if (conf == null) await Future<void>.delayed(timing.seqConfPoll);
    }
    if (conf == null) return rec; // not confirmed yet; stays resumable
    rec
      ..seqLeg = XrSeqLeg(txid: rec.seqFundTxid, vout: conf.vout, blockHash: conf.blockHash)
      ..step = XrStep.seqFunded;
    await XrSwapStore.save(rec);
    return rec;
  }

  // ---- refund off-ramp (the asset leg, after T_seq) --------------------------------------------------

  /// True when the CLTV refund of our asset leg is spendable: the leg is funded, the swap is not done,
  /// the maker has NOT already claimed it (at secretRevealed the secret is out — claim the BTC instead),
  /// and the Sequentia tip has reached T_seq.
  static Future<bool> refundSeqReady(XrSwapRecord rec) async {
    if (rec.seqLeg == null || rec.terminal || rec.step == XrStep.secretRevealed || rec.preimageHex.isNotEmpty) {
      return false;
    }
    final tip = await chain.seqTipHeight();
    return tip >= 0 && tip >= rec.seqLocktime;
  }

  /// Reclaim our asset leg via the CLTV/ELSE branch. Only do this if the maker stalled and never took
  /// the leg (otherwise the secret is already out and the BTC claim is the right move).
  static Future<XrSwapRecord> refundSeq(XrSwapRecord rec) async {
    final leg = rec.seqLeg;
    if (leg == null) throw Exception('no asset leg to refund');
    if (rec.terminal) throw Exception('this swap is already settled');
    // Defence in depth: the refund is non-final until the tip reaches T_seq. Fail OPEN when the tip is
    // unreadable — the on-chain spend still rejects a premature refund, so the user is never blocked.
    final tip = await chain.seqTipHeight();
    if (tip >= 0 && tip < rec.seqLocktime) {
      throw Exception('the refund unlocks at Sequentia block ${rec.seqLocktime}, '
          'about ${rec.seqLocktime - tip} block(s) away');
    }
    final txid = await chain.refundSeq(
      seqTxid: leg.txid,
      seqVout: leg.vout,
      amountAtoms: rec.seqAmount,
      assetId: rec.seqAsset,
      redeemScriptHex: rec.seqRedeem,
      seqLocktime: rec.seqLocktime,
    );
    rec
      ..seqRefundTxid = txid
      ..step = XrStep.refunded
      ..detail = 'asset leg refunded by you';
    await XrSwapStore.save(rec);
    return rec;
  }

  // ---- abandon ---------------------------------------------------------------------------------------

  /// Whether the persisted record may be cleared without stranding anything: terminal, or PROVABLY
  /// unfunded (no leg, no txid, and the broadcast intent never fired — the hook fires immediately before
  /// the irreversible broadcast, so an unset flag proves nothing went out). NEVER clear a record that
  /// might hold a locked asset: it carries the only copy of the terms the CLTV refund is derived from.
  static bool canAbandon(XrSwapRecord rec) => rec.terminal || !rec.holdsOrMightHoldAsset;

  /// Clear ONE record — refused (returns false) while it still protects a locked (or possibly locked)
  /// asset leg. Refund it first (after T_seq), or let [resume] resolve the strand. Judged on the FRESH
  /// on-disk record by id (never a stale UI copy), and removes exactly that record.
  static Future<bool> abandon(XrSwapRecord record) async {
    final rec = await XrSwapStore.load(id: record.id);
    if (rec == null) return true; // already gone
    if (!canAbandon(rec)) return false;
    await XrSwapStore.remove(rec.id);
    return true;
  }

  // ---- shared failure path ---------------------------------------------------------------------------

  /// Courier a fail note, persist the failed record + detail, and throw. Only for PRE-FUND aborts —
  /// nothing of ours has moved, so the record carries no reclaim material (still kept, for the UI).
  static Future<XrSwapRecord> _failAbort(XrCourier courier, XrSwapRecord rec, String code, String msg) async {
    try {
      await courier.fail(code, msg);
    } catch (_) {}
    rec
      ..step = XrStep.failed
      ..detail = msg;
    await XrSwapStore.save(rec);
    throw Exception(msg);
  }
}

/// The live chain seam: the SAME ambra_core FFIs + esplora/LSP endpoints the forward flow uses.
class XrChainLive implements XrChain {
  /// How many times a single anchor read is retried before it counts as UNKNOWN (a transient 502 must
  /// cost a retry, not somebody's trade — ported from xrswap.js ANCHOR_READ_TRIES).
  static const _anchorReadTries = 3;

  Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('wallet unavailable');
    return m;
  }

  @override
  Future<String> takerBtcClaimPub() async => core.xchainBtcClaimPubkey(mnemonic: await _mnemonic());

  // The SEQ-refund pubkey MUST be the key xchainSeqHtlcReverse embeds as the refund branch — the
  // taker's canonical SEQ key (xchainSeqClaimPubkey), so the maker rebuilds the identical script.
  @override
  Future<String> takerSeqRefundPub() async => core.xchainSeqClaimPubkey(mnemonic: await _mnemonic());

  @override
  Future<core.BtcHtlcInfo> btcHtlc(
          {required String hashHex,
          required String claimPubHex,
          required String refundPubHex,
          required int locktime}) =>
      core.xchainBtcHtlc(hashHex: hashHex, claimPubHex: claimPubHex, refundPubHex: refundPubHex, locktime: locktime);

  @override
  Future<core.SeqHtlcInfo> seqHtlcReverse(
          {required String hashHex, required String makerSeqClaimPubHex, required int seqLocktime}) async =>
      core.xchainSeqHtlcReverse(
        mnemonic: await _mnemonic(),
        hashHex: hashHex,
        makerSeqClaimPubHex: makerSeqClaimPubHex,
        seqLocktime: seqLocktime,
      );

  @override
  Future<XrBtcFunding?> findBtcFunding({required String txid, required String p2shSpkHex}) async {
    try {
      final f = await core.xchainFindBtcFunding(t4Api: Backend.testnet4, txid: txid, p2ShSpkHex: p2shSpkHex);
      return XrBtcFunding(
        vout: f.vout,
        valueSats: BigInt.tryParse(f.valueSats) ?? BigInt.zero,
        height: f.height.toInt(),
        confirmed: f.confirmations >= 1 && f.height > 0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int> _tip(String base) async {
    try {
      final r = await http
          .get(Uri.parse('$base/blocks/tip/height'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return -1;
      return int.tryParse(r.body.trim()) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<int> seqTipHeight() => _tip(Backend.esplora);

  @override
  Future<int> btcTipHeight() => _tip(Backend.testnet4);

  @override
  Future<({int height, bool ok})?> anchorTip() async {
    // The LSP's read-only /anchor: {ok, anchor_height, anchor_status}. anchor_status absent (an older
    // LSP) is NOT ok — fail closed rather than assume a healthy anchor we cannot see.
    try {
      final r = await http
          .get(Uri.parse('${Backend.lsp}/anchor'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (j['ok'] != true) return null;
      final h = (j['anchor_height'] as num?)?.toInt();
      if (h == null) return null;
      return (height: h, ok: j['anchor_status'] == 'ok');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<({int anchor, bool onActiveChain})> legAnchor(String txid) async {
    // Ask by TXID ("which block confirms this leg NOW") and count the answer only when that block is on
    // the ACTIVE chain. anchor -1 = UNKNOWN, never 0 (0 reads as "anchored below the lock" — terminal).
    for (var i = 0; i < _anchorReadTries; i++) {
      try {
        final r = await http
            .get(Uri.parse('${Backend.lsp}/anchor?tx=${Uri.encodeComponent(txid)}'), headers: Backend.authHeaders)
            .timeout(const Duration(seconds: 6));
        if (r.statusCode == 200) {
          final j = jsonDecode(r.body) as Map<String, dynamic>;
          if (j['ok'] == true) {
            final h = (j['anchor_height'] as num?)?.toInt();
            if (h == null) return (anchor: -1, onActiveChain: false); // truthfully "not confirmed yet"
            // on_active_chain absent (older LSP): a tx lookup already resolves through the node's own
            // view of which block confirms it, so treat absence as proven for the tx path.
            final active = j.containsKey('on_active_chain') ? j['on_active_chain'] == true : true;
            return (anchor: h, onActiveChain: active);
          }
        }
      } catch (_) {}
      if (i < _anchorReadTries - 1) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return (anchor: -1, onActiveChain: false);
  }

  @override
  Future<String> fundSeqHtlc(
      {required String address,
      required String assetId,
      required BigInt amountAtoms,
      required Future<void> Function() onAboutToBroadcast}) {
    return authorizeBuildBroadcast(
      (mnemonic) => core.buildSendTx(
        mnemonic: mnemonic,
        esploraUrl: Backend.esplora,
        recipients: [core.Recipient(address: address, assetId: assetId, satoshi: amountAtoms)],
        feeRateSatKvb: null,
        feeAsset: null,
      ),
      onAboutToBroadcast: onAboutToBroadcast,
    );
  }

  Future<Map<String, dynamic>?> _seqTx(String txid) async {
    try {
      final r = await http
          .get(Uri.parse('${Backend.esplora}/tx/$txid'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static int _findVout(Map<String, dynamic> tx, String p2shSpkHex) {
    final vouts = (tx['vout'] as List?) ?? const [];
    final want = p2shSpkHex.toLowerCase();
    for (var i = 0; i < vouts.length; i++) {
      final o = vouts[i];
      if (o is Map && '${o['scriptpubkey'] ?? ''}'.toLowerCase() == want) return i;
    }
    return -1;
  }

  @override
  Future<XrSeqFunding?> findSeqFunding({required String txid, required String p2shSpkHex}) async {
    final tx = await _seqTx(txid);
    if (tx == null) return null;
    final v = _findVout(tx, p2shSpkHex);
    final status = tx['status'] as Map?;
    final confirmed = status != null && status['confirmed'] == true;
    if (v < 0 || !confirmed) return null;
    final bh = '${status['block_hash'] ?? ''}';
    if (bh.isEmpty) return null;
    return XrSeqFunding(vout: v, blockHash: bh);
  }

  @override
  Future<String?> findSeqFundingTxidByAddress({required String p2shAddress, required String p2shSpkHex}) async {
    try {
      final r = await http
          .get(Uri.parse('${Backend.esplora}/address/$p2shAddress/txs'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final list = jsonDecode(r.body);
      if (list is! List) return null;
      for (final e in list) {
        if (e is! Map) continue;
        final tx = Map<String, dynamic>.from(e);
        if (_findVout(tx, p2shSpkHex) >= 0) return '${tx['txid'] ?? ''}';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> readSeqPreimage({required String seqLegTxid, required int vout, required String hashHex}) =>
      core.xchainReadSeqPreimage(
          seqEsplora: Backend.esplora, seqLegTxid: seqLegTxid, seqVout: vout, hashHex: hashHex);

  @override
  Future<String> claimBtc(
      {required String btcTxid,
      required int btcVout,
      required BigInt amountSats,
      required String redeemScriptHex,
      required String preimageHex}) async {
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m);
    // Legacy P2SH HTLC spend ~ 220 vB at ~2 sat/vB (the same sizing as the forward refundBtc).
    final feeSats = BigInt.from(440);
    final hex = await core.xchainBtcClaim(
      mnemonic: m,
      btcTxid: btcTxid,
      btcVout: btcVout,
      btcAmountSats: amountSats,
      destAddress: dest,
      feeSats: feeSats,
      redeemScriptHex: redeemScriptHex,
      preimageHex: preimageHex,
    );
    return core.btcBroadcast(t4Api: Backend.testnet4, txHex: hex);
  }

  @override
  Future<String> refundSeq(
      {required String seqTxid,
      required int seqVout,
      required BigInt amountAtoms,
      required String assetId,
      required String redeemScriptHex,
      required int seqLocktime}) async {
    final m = await _mnemonic();
    final dest = await core.receiveAddress(mnemonic: m);
    final fee = await _assetRefundFee(assetId, amountAtoms);
    final hex = await core.xchainSeqRefund(
      mnemonic: m,
      seqTxid: seqTxid,
      seqVout: seqVout,
      seqAmount: amountAtoms,
      seqAssetId: assetId,
      destAddress: dest,
      feeAtoms: fee,
      redeemScriptHex: redeemScriptHex,
      seqLocktime: seqLocktime,
    );
    return core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
  }

  /// The refund fee in atoms of the LOCKED asset (the HTLC holds only that asset): the native reference
  /// fee for a ~400-vB spend converted at the asset's published rate (ceil(native*1e8/rate)), min 1 atom,
  /// capped at half the output. Best-effort: an unreadable feed falls back to 1 atom — an under-fee'd
  /// REFUND simply does not relay yet (retriable; no secret at stake), while a naive flat atom count
  /// would be a huge reference-value fee the node rejects (memory principle 4).
  Future<BigInt> _assetRefundFee(String assetHex, BigInt amount) async {
    var fee = BigInt.one;
    try {
      final rates = await ApiClient.feeRates();
      final ticker = SeqAssets.labelFor(assetHex).ticker;
      final rate = rates[ticker] ?? rates[assetHex];
      if (rate != null && rate > BigInt.zero) {
        final native = BigInt.from(400); // ~vbytes * 1 sat/vB (the forward path's sizing)
        fee = (native * _kScale + rate - BigInt.one) ~/ rate;
        if (fee < BigInt.one) fee = BigInt.one;
      }
    } catch (_) {/* keep the minimal fallback */}
    final half = amount ~/ BigInt.two;
    if (half >= BigInt.one && fee > half) fee = half;
    return fee;
  }

  @override
  Future<BigInt?> assetRate(String assetHex) async {
    try {
      final rates = await ApiClient.feeRates();
      final ticker = SeqAssets.labelFor(assetHex).ticker;
      return rates[ticker] ?? rates[assetHex];
    } catch (_) {
      return null;
    }
  }
}
