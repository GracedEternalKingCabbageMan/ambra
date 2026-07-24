// ---------------------------------------------------------------------------
// subswap_service.dart — the P2P SUBMARINE taker (both directions), the mobile twin of the web wallet's
// subswap.js. FAITHFUL port of the verified taker (5 fund-safety rounds): do NOT re-derive the checks.
//
// PRINCIPLE (doc/sequentia/rail-crossing-p2p-lsp-design.md): matching is rail-blind; settlement picks a
// mutually-supported rail. A DIRECT peer-to-peer submarine is the FIRST-CLASS path whenever the
// counterparties line up (an interactive online maker that can itself accept BTC-LN). A BTC<->asset swap
// has two legs bound by ONE preimage H: on the submarine path the asset leg is a Sequentia on-chain HTLC
// and the BTC leg is a bolt11 (pure Lightning), so there is exactly ONE on-chain HTLC + a SINGLE T_seq
// gate — no coupled locktimes.
//
//   • runReverseBuy   (ln_direction=1): the maker locks the asset on-chain (claim=taker) + mints a
//     bolt11 on H; the taker VERIFIES the SEQ leg binds its OWN claim key on H (asset/amount/locktime),
//     that the funding output pays the HTLC P2SH, and that it is anchor-buried, ONLY THEN pays the
//     invoice (learning P), PERSISTS P + the leg, and claims the asset. The taker can never lose BTC-LN
//     without the verified, anchor-buried asset already locked to its own key on the same H.
//   • runSubmarineSell (ln_direction=0): the taker mints P/H, mints a bolt11 (HODL) on H at its OWN
//     BTC-LN node, funds the asset HTLC (claim=maker, refund=taker), announces both, and settles the
//     hold with P once the maker pays (revealing P so the maker claims the asset). If unpaid, the taker
//     refunds the asset after T_seq.
//
// Fund-safety (taker, both paths): VERIFY everything before the single irreversible act (paying the
// maker's invoice on the buy; settling the hold on the sell), and PERSIST P + the leg before the claim
// so a crash between the irreversible act and the claim never loses P (the only key to the asset).
//
// The SEQ-leg HTLC ops come from ambra_core (xchainSeqHtlcForward/Reverse, xchainSeqClaim/Refund,
// xchainVerifySeqLegSafe, xchainNewSecret) — REUSED, identical to the native cross flow. The BTC-LN
// pay/receive rides the user's OWN hosted BTC node via the LSP (device-cosigned; the LSP never holds the
// key). The bolt11 payment_hash + min_final_cltv decode is pure Dart (mirrors subswap.js).
// ---------------------------------------------------------------------------

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../rust/api.dart' as core;
import 'api_client.dart';
import 'config.dart';
import 'cross_courier.dart';
import 'lightning_service.dart';
import 'lsp_client.dart';
import 'tx_flow.dart';
import 'wallet_repository.dart';

/// XcSub message type tags — byte-for-byte the seqdex xcourier_submarine.go constants + the web
/// subswap.js XcSubType. An XcSub message rides the SAME sealed E2E courier as the cross lift.
class XcSubType {
  static const termsRequest = 'sub_terms_request';
  static const terms = 'sub_terms'; // normal (sell): the maker's per-lift terms
  static const assetFunded = 'sub_asset_funded'; // normal (sell): the taker funded the asset HTLC + bolt11
  static const assetLocked = 'sub_asset_locked'; // reverse (buy): the maker locked the asset HTLC + bolt11
  static const settled = 'sub_settled'; // maker claimed the asset (informational)
  static const fail = 'fail';
}

// REVERSE-SUBMARINE HOLD-CLTV BLOCK-TIME MODEL (subswap.js). The reverse-submarine taker's hold-invoice
// CLTV gate does the INVERSE (a BTC-block window -> a SEQ settle-deadline) of the forward leg-bridge, so
// it needs the OPPOSITE conservative ends: Bitcoin as SLOW as a sustained hashrate-lull average (~3x
// nominal 600 s) over Sequentia at its EXACT deterministic slot (30 s) => 1 BTC block spans ~60 SEQ
// slots. Using the forward ~1.67 here made this fund-safety gate ~36x too permissive.
const int kSlowBtcSecs = 1800;
const int kFastSeqSecs = 30;

/// The default SEQ claim/refund margin (blocks) the taker keeps below T_seq (subswap.js claimMargin 120).
const int kSubClaimMargin = 120;

/// Minimum Bitcoin-anchor burial the asset HTLC funding block must reach before the taker's irreversible
/// act (subswap.js minAnchorDepth 3). max0ConfAtoms 0 => the taker ALWAYS waits (never fronts a reorg).
const int kSubMinAnchorDepth = 3;

final BigInt _kScale = BigInt.from(100000000); // exchange-rate scale (atoms per reference unit)
final RegExp _kHex64 = RegExp(r'^[0-9a-fA-F]{64}$');

// ===========================================================================
// PURE bolt11 decoders — the CLIENT-SIDE mirror of the Go driver's clnLNLeg.Pay(bolt11, wantHash). PURE.
// ===========================================================================

const String _bech32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

/// The bolt11 tagged-field data groups (5-bit values), or null when the invoice cannot be parsed. Shared
/// by [bolt11PaymentHash] / [bolt11MinFinalCltv]. bech32 layout: timestamp(7) + tagged fields +
/// signature(104) + checksum(6). Returns the (values, taggedFieldsEnd) so a caller can walk the fields.
({List<int> vals, int end})? _bolt11Fields(String? bolt11) {
  if (bolt11 == null) return null;
  final s = bolt11.trim().toLowerCase();
  final sep = s.lastIndexOf('1');
  if (sep < 1) return null;
  final data = s.substring(sep + 1);
  final vals = <int>[];
  for (final ch in data.split('')) {
    final v = _bech32.indexOf(ch);
    if (v < 0) return null;
    vals.add(v);
  }
  if (vals.length < 7 + 104 + 6) return null; // too short for timestamp + signature + checksum
  return (vals: vals, end: vals.length - 104 - 6);
}

/// Decode `nbytes` big-endian bytes from `nbytes*8/5`-ceil 5-bit groups, or null when it cannot fill.
String? _fiveBitToHex(List<int> groups, int nbytes) {
  var acc = 0, bits = 0;
  final out = <int>[];
  for (final g in groups) {
    acc = (acc << 5) | g;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.add((acc >> bits) & 0xff);
      if (out.length == nbytes) break;
    }
    if (out.length == nbytes) break;
  }
  if (out.length != nbytes) return null;
  return out.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

/// The invoice's `p` (payment_hash) tagged field as 32-byte lowercased hex, or null when it cannot be
/// confidently extracted. The taker MUST prove the invoice it is about to pay is bound to the SAME H as
/// the on-chain asset HTLC — else paying yields a preimage that opens NOTHING and loses BTC-LN with no
/// asset (the single worst fund-loss on the reverse-submarine buy). The gate that consumes this fails
/// CLOSED on null. PURE. `p` = type 1, len 52 (260 bits -> 32 bytes).
String? bolt11PaymentHash(String? bolt11) {
  final f = _bolt11Fields(bolt11);
  if (f == null) return null;
  final vals = f.vals, end = f.end;
  var i = 7;
  String? payHash;
  while (i + 3 <= end) {
    final type = vals[i];
    final len = (vals[i + 1] << 5) | vals[i + 2];
    i += 3;
    if (i + len > end) break;
    if (type == 1 && len == 52) payHash = _fiveBitToHex(vals.sublist(i, i + 52), 32);
    i += len;
  }
  return payHash;
}

/// The invoice's `c` (min_final_cltv_expiry) tagged field, or the BOLT11 default 18 when ABSENT, or null
/// when the invoice cannot be parsed at all (the CLTV gate then fails closed). A bolt11 HOLD invoice is
/// byte-identical to a plain one, so this is the ONLY on-invoice signal of how long the recipient could
/// keep an incoming payment HELD — the reverse-submarine taker gates on it so a masquerading maker cannot
/// hold the taker's payment past T_seq, refund the asset, then settle the hold. PURE. First `c` wins.
int? bolt11MinFinalCltv(String? bolt11) {
  final f = _bolt11Fields(bolt11);
  if (f == null) return null;
  final vals = f.vals, end = f.end;
  var i = 7;
  int? cltv;
  while (i + 3 <= end) {
    final type = vals[i];
    final len = (vals[i + 1] << 5) | vals[i + 2];
    i += 3;
    if (i + len > end) break;
    if (type == 24 && cltv == null) {
      var acc = 0;
      for (var k = 0; k < len; k++) {
        acc = acc * 32 + vals[i + k]; // big-endian 5-bit integer
      }
      cltv = acc;
    }
    i += len;
  }
  return cltv ?? 18; // absent -> BOLT11 default 18
}

/// The invoice amount in msat, or null when absent / not confidently parseable (an amountless invoice, an
/// unknown prefix, or a sub-msat `p` amount). CONSERVATIVE by design: null rather than guess, so the
/// overpay guard NEVER false-rejects a valid invoice — it only refuses a confidently-parsed OVERPAY.
/// `<digits><multiplier>` after the `ln<currency>` prefix: m=1e-3, u=1e-6, n=1e-9, p=1e-12 BTC; msat =
/// BTC * 1e11. (bcrt is matched before bc so `lnbcrt…` parses.) PURE.
BigInt? bolt11AmountMsat(String? bolt11) {
  if (bolt11 == null) return null;
  final m = RegExp(r'^ln(bcrt|tbs|tsb|bc|tb|sb)(\d*)([munp]?)', caseSensitive: false).firstMatch(bolt11.trim());
  if (m == null || (m.group(2) ?? '').isEmpty) return null;
  final n = BigInt.tryParse(m.group(2)!);
  if (n == null) return null;
  switch ((m.group(3) ?? '').toLowerCase()) {
    case 'm':
      return n * BigInt.from(100000000); // milli-BTC * 1e8 msat
    case 'u':
      return n * BigInt.from(100000); // micro-BTC * 1e5 msat
    case 'n':
      return n * BigInt.from(100); // nano-BTC * 1e2 msat
    case 'p':
      return (n % BigInt.from(10) == BigInt.zero) ? n ~/ BigInt.from(10) : null; // pico = 0.1 msat units
    case '':
      return n * BigInt.from(100000000000); // whole BTC * 1e11 msat
    default:
      return null;
  }
}

// ===========================================================================
// PURE fund-safety cores (no I/O). Each independently testable; the driver composes them with real I/O.
// ===========================================================================

/// A pass/fail verdict for one fund-safety gate.
class SubVerdict {
  const SubVerdict(this.ok, this.reason);
  final bool ok;
  final String reason;
}

/// The rebuilt HTLC redeem script (derived from OUR inputs, never the maker's bytes) MUST byte-equal the
/// maker-provided script — that is what proves the asset HTLC's claim branch is spendable by US with P.
SubVerdict checkRedeemMatches({required String rebuilt, required String provided}) {
  final r = rebuilt.toLowerCase(), p = provided.toLowerCase();
  if (r.isEmpty) return const SubVerdict(false, 'no rebuilt redeem script');
  if (p.isEmpty) return const SubVerdict(false, 'no redeem_script provided');
  if (r != p) {
    return const SubVerdict(
        false, 'redeem_script does not match H + my-claim/maker-refund keys + locktime (asset HTLC is not locked to this wallet)');
  }
  return const SubVerdict(true, 'redeem binds my claim key on H');
}

/// The announced leg's amount/asset/locktime bind to the signed offer's expectations (whole-HTLC lift).
SubVerdict checkLegBinding({
  required BigInt legAmount,
  String? legAsset,
  required int legLocktime,
  required String? legTxid,
  required int legVout,
  required String expectAsset,
  required BigInt expectAtoms,
  required int expectLocktime,
}) {
  if (legAmount != expectAtoms) {
    return SubVerdict(false, 'asset leg amount $legAmount != offer $expectAtoms');
  }
  if (legAsset != null && legAsset.isNotEmpty && legAsset.toLowerCase() != expectAsset.toLowerCase()) {
    return SubVerdict(false, 'asset leg asset $legAsset != offer $expectAsset');
  }
  if (legLocktime != expectLocktime) {
    return SubVerdict(false, 'asset leg locktime $legLocktime != terms $expectLocktime');
  }
  if (legTxid == null || legTxid.isEmpty || legVout < 0) {
    return const SubVerdict(false, 'asset leg has no funding outpoint');
  }
  return const SubVerdict(true, 'leg binds to the offer');
}

/// The on-chain funding output ACTUALLY pays the HTLC P2SH the rebuilt redeem produces, with the expected
/// amount + asset. REQUIRE the P2SH match — NEVER skip it (fail CLOSED when either side is unreadable):
/// paying/exposing against an output we cannot bind to the redeem is the exact hole this closes.
SubVerdict checkFundingOutput({
  String? outputSpk,
  BigInt? outputValue,
  String? outputAsset,
  required String expectSpkHex,
  required BigInt expectAtoms,
  required String expectAsset,
}) {
  if (expectSpkHex.isEmpty) {
    return const SubVerdict(false, 'could not derive the HTLC P2SH scriptPubkey to verify the funding output (failing closed)');
  }
  if (outputSpk == null || outputSpk.isEmpty) {
    return const SubVerdict(false, 'the funding output scriptPubkey is unreadable — cannot confirm it pays the HTLC P2SH (failing closed)');
  }
  if (outputSpk.toLowerCase() != expectSpkHex.toLowerCase()) {
    return const SubVerdict(false, 'the funding output does not pay the HTLC P2SH');
  }
  if (outputValue != null && outputValue != expectAtoms) {
    return SubVerdict(false, 'the funding output value $outputValue != expected $expectAtoms');
  }
  if (outputAsset != null && outputAsset.isNotEmpty && outputAsset.toLowerCase() != expectAsset.toLowerCase()) {
    return SubVerdict(false, 'the funding output asset $outputAsset != expected $expectAsset');
  }
  return const SubVerdict(true, 'funding output pays the HTLC P2SH with the right asset + amount');
}

/// The HOLD-INVOICE MASQUERADE gate (fund-loss), PURE. A malicious interactive reverse-submarine maker
/// can hand a HOLD invoice whose min_final_cltv lets it keep the taker's payment HELD PAST T_seq: hold
/// it, refund the asset at T_seq, THEN settle the hold — capturing BTC-LN with NO asset. Convert the
/// finalCltv BTC-block window to Sequentia blocks with the CONSERVATIVE INVERSE ratio (slow-BTC /
/// fast-SEQ ~= 60) and REQUIRE the taker can still claim after the latest possible reveal:
/// settleDeadlineSeq + claimMargin < T_seq. [maxSafeCltvBtc] is the largest final CLTV that still clears
/// — the driver caps its OWN outgoing max-cltv to it so a HELD payment refunds as early as possible.
class HoldCltvVerdict {
  const HoldCltvVerdict(this.ok, this.reason, {this.finalCltv, this.settleDeadlineSeq, this.maxSafeCltvBtc});
  final bool ok;
  final String reason;
  final int? finalCltv;
  final int? settleDeadlineSeq;
  final int? maxSafeCltvBtc;
}

HoldCltvVerdict holdCltvSafeVsTseq({
  required int? finalCltv,
  required int seqTip,
  required int seqLocktime,
  required int claimMargin,
  int slowBtcSecs = kSlowBtcSecs,
  int fastSeqSecs = kFastSeqSecs,
}) {
  if (finalCltv == null || finalCltv < 0) {
    return const HoldCltvVerdict(
        false, 'the invoice min_final_cltv is undecodable — failing closed (never pay a hold that could settle past T_seq)');
  }
  final ratio = (slowBtcSecs > 0 ? slowBtcSecs : kSlowBtcSecs) / (fastSeqSecs > 0 ? fastSeqSecs : kFastSeqSecs);
  final fc = finalCltv, st = seqTip, lt = seqLocktime, cm = claimMargin;
  final claimableSeqBlocks = lt - st - cm;
  final maxSafeCltvBtc = ((claimableSeqBlocks - 1) / ratio).floor();
  final safeCap = maxSafeCltvBtc < 0 ? 0 : maxSafeCltvBtc;
  final settleDeadlineSeq = st + (fc * ratio).ceil();
  if (!(settleDeadlineSeq + cm < lt)) {
    return HoldCltvVerdict(
        false,
        'the invoice min_final_cltv $fc BTC blocks lets a HOLD stay settleable until ~SEQ height $settleDeadlineSeq, '
            'leaving < $cm blocks before T_seq $lt to claim — a masqueraded hold could settle past T_seq (BTC-LN captured, no asset). '
            'Refuse (safe max $safeCap BTC blocks).',
        finalCltv: fc,
        settleDeadlineSeq: settleDeadlineSeq,
        maxSafeCltvBtc: safeCap);
  }
  return HoldCltvVerdict(
      true,
      'the invoice min_final_cltv $fc BTC blocks fails back by ~SEQ height $settleDeadlineSeq, leaving >= $cm blocks '
          'before T_seq $lt — the taker can still claim after the latest possible reveal (safe)',
      finalCltv: fc,
      settleDeadlineSeq: settleDeadlineSeq,
      maxSafeCltvBtc: safeCap);
}

/// SIZE a rail-crossing take (subswap.js sizeSubswapTake). SUBMARINE offers are WHOLE-OFFER-ONLY: the
/// makers lock the whole offer in one HTLC, so a requested size below the whole offer can't be filled —
/// flagged [wholeOnly] so the composer blocks Place (fail closed) rather than lifting the whole offer.
class SubTakeSize {
  const SubTakeSize({required this.takeAtoms, required this.takeBtc, required this.overshoot, required this.wholeOnly});
  final BigInt takeAtoms;
  final BigInt takeBtc;
  final bool overshoot;
  final bool wholeOnly;
}

SubTakeSize sizeSubswapTake({required BigInt want, required BigInt offerAtoms, required BigInt offerBtc}) {
  final overshoot = want > BigInt.zero && offerAtoms > BigInt.zero && want < offerAtoms;
  return SubTakeSize(takeAtoms: offerAtoms, takeBtc: offerBtc, overshoot: overshoot, wholeOnly: overshoot);
}

// ===========================================================================
// Persisted record — one in-flight submarine at a time (whole-HTLC, resumable). The asset leg is a real
// time-locked commitment, so a crash between the irreversible act and the claim MUST recover. P + the
// verified leg are persisted BEFORE the claim (fund-safety), mirroring the web SUBSWAP record + RSwapStore.
// ===========================================================================

/// The submarine state machine (subswap.js SUBSWAP.state). BUY: starting -> verifying -> verified ->
/// paying -> claiming -> settled. SELL: starting -> funding -> settling -> settled|refunded.
///
/// [unknown] is a dedicated NON-TERMINAL sentinel for a persisted 'state' string this build does not
/// recognise (version skew / a state added in a FUTURE build / a foreign write). [SubswapRecord.fromJson]
/// decodes any unrecognised state to it (never to a TERMINAL state) so a live record can NEVER read as
/// terminal — the [terminal] getter returns FALSE for it, keeping the in-flight guard CLOSED. Matches the
/// web wallet's subswapTerminal(), which is true ONLY for the explicit terminal set and thus treats any
/// unknown state as non-terminal. NEVER map unknown -> failed (that would clobber a live swap's funds).
enum SubState { starting, verifying, verified, paying, claiming, settled, funding, settling, refunded, failed, unknown }

class SubswapRecord {
  SubswapRecord({
    required this.buy,
    required this.state,
    required this.asset,
    required this.assetAtoms,
    required this.btcSats,
    required this.offerId,
    required this.makerPubkey,
    this.hashHex = '',
    this.preimageHex = '',
    this.makerRefundPub = '',
    this.seqLocktime = 0,
    this.legTxid = '',
    this.legVout = -1,
    this.legRedeem = '',
    this.legP2shSpk = '',
    this.legP2shAddr = '',
    this.legBlockHash = '',
    this.bolt11 = '',
    this.btcNodeKey = '',
    this.seqClaimTxid = '',
    this.seqFundTxid = '',
    this.seqRefundTxid = '',
    this.broadcastAttempted = false,
    this.broadcastAt = 0,
    this.broadcastSeqHeight = 0,
    this.detail = '',
  });

  final bool buy; // true = reverse buy (ln_direction 1); false = normal sell (ln_direction 0)
  SubState state;
  final String asset; // asset id (hex)
  final BigInt assetAtoms;
  final BigInt btcSats;
  final String offerId;
  final String makerPubkey;
  String hashHex;
  String preimageHex;
  String makerRefundPub; // BUY: the maker's SEQ refund pubkey (rebuilds the redeem)
  int seqLocktime;
  String legTxid;
  int legVout;
  String legRedeem;
  String legP2shSpk; // SELL: the HTLC P2SH scriptPubkey (persisted at fund time so resume can match the vout)
  String legP2shAddr; // SELL: the HTLC P2SH address (persisted so resume can SCAN for the funding by address)
  String legBlockHash;
  String bolt11;
  String btcNodeKey;
  String seqClaimTxid;
  String seqFundTxid;
  String seqRefundTxid;

  /// SELL INTENT-BEFORE-BROADCAST marker (fund-loss, Task 2). Persisted `true` BEFORE the asset-HTLC fund is
  /// broadcast ([authorizeBuildBroadcast]) — the Dart twin of the web onAboutToFund intent. Its ONE job: make
  /// the D0 SELL-resume `definitivelyEmpty -> clear()` path UNREACHABLE once a broadcast may have gone out. A
  /// crash AFTER the broadcast but BEFORE [seqFundTxid] persists leaves a FUNDED HTLC with an empty seqFundTxid;
  /// a multi-backend /address/utxo scan that transiently returns `[]` (a node lagging the mempool) must then
  /// NEVER be read as "nothing was ever committed" and cleared. Only a record that never reached the broadcast
  /// (broadcastAttempted == false) may be dropped as pre-commitment.
  bool broadcastAttempted;

  /// SELL BROADCAST-TIME stamp (ms since epoch; 0 = unset). Persisted at the SAME moment [broadcastAttempted]
  /// is set — in the [authorizeBuildBroadcast] onAboutToBroadcast hook, immediately before the on-chain
  /// broadcast.
  ///
  /// DISPLAY ONLY (round 12): this stamp NO LONGER gates the abandon escape. Rounds 9-11 used it as a
  /// DateTime.now()-vs-broadcastAt wall-clock AGE GATE (kAbandonMinBroadcastAge / broadcastAgedForAbandon, both
  /// removed) — but a wall clock is defeatable: a forward device-clock jump erodes the margin, making a stale
  /// backend's empty scan read as "aged" and false-emptying a funded HTLC. The WHOLE abandon decision is now
  /// CLOCK-FREE: its entire staleness/reorg margin comes from the [broadcastSeqHeight] height proof
  /// ([SubswapService.tipHeightProvesEmptyScan]), which uses monotonic block HEIGHTS and no wall clock. This
  /// field is kept persisted only so the UI can show "broadcast at ~<time>" for information; nothing on the
  /// fund-safety path reads it.
  int broadcastAt;

  /// SELL BROADCAST-HEIGHT stamp (round 11, CLOCK-FREE; 0 = unset). The Sequentia tip HEIGHT read at the SAME
  /// moment [broadcastAttempted]/[broadcastAt] are set — in the [authorizeBuildBroadcast] onAboutToBroadcast hook,
  /// immediately before the on-chain broadcast, so it is at-or-below the height at which the funding could confirm.
  /// Its ONE job: give the abandon escape a CLOCK-FREE freshness proof. An empty on-chain HTLC scan is trusted only
  /// once the backend's CURRENT tip HEIGHT is >= this + [SubswapService.kAbandonMinConfDepth] — i.e. the backend is
  /// provably well past the funding-confirmation window, so a funded HTLC would be visible. Heights are MONOTONIC
  /// and independent of any wall clock, so device-clock skew cannot defeat the gate (the flaw that motivated round
  /// 11). Zeroed by the pre-broadcast-throw reset (nothing went out -> no height to prove against). A 0/absent stamp
  /// (pre-r11 record, or an unreadable tip at broadcast time) FAILS CLOSED — not abandonable. See
  /// [SubswapService.tipHeightProvesEmptyScan].
  int broadcastSeqHeight;
  String detail;

  /// NON-terminal for [SubState.unknown] BY CONSTRUCTION (it is not in the terminal set): an unrecognised
  /// persisted state keeps [SubswapStore.hasInFlight] CLOSED so a live record is never clobbered (Task 1).
  bool get terminal => state == SubState.settled || state == SubState.failed || state == SubState.refunded;

  Map<String, dynamic> toJson() => {
        'buy': buy,
        'state': state.name,
        'asset': asset,
        'assetAtoms': assetAtoms.toString(),
        'btcSats': btcSats.toString(),
        'offerId': offerId,
        'makerPubkey': makerPubkey,
        'hashHex': hashHex,
        'preimageHex': preimageHex,
        'makerRefundPub': makerRefundPub,
        'seqLocktime': seqLocktime,
        'legTxid': legTxid,
        'legVout': legVout,
        'legRedeem': legRedeem,
        'legP2shSpk': legP2shSpk,
        'legP2shAddr': legP2shAddr,
        'legBlockHash': legBlockHash,
        'bolt11': bolt11,
        'btcNodeKey': btcNodeKey,
        'seqClaimTxid': seqClaimTxid,
        'seqFundTxid': seqFundTxid,
        'seqRefundTxid': seqRefundTxid,
        'broadcastAttempted': broadcastAttempted,
        'broadcastAt': broadcastAt,
        'broadcastSeqHeight': broadcastSeqHeight,
        'detail': detail,
      };

  static SubswapRecord fromJson(Map<String, dynamic> j) => SubswapRecord(
        buy: j['buy'] == true,
        // UNRECOGNISED state -> SubState.unknown (NON-terminal), NEVER SubState.failed (terminal). A future/foreign
        // state string decoding to a terminal value would let the guard read a LIVE record as done and clobber it.
        state: SubState.values.firstWhere((s) => s.name == j['state'], orElse: () => SubState.unknown),
        asset: '${j['asset'] ?? ''}',
        assetAtoms: BigInt.tryParse('${j['assetAtoms'] ?? 0}') ?? BigInt.zero,
        btcSats: BigInt.tryParse('${j['btcSats'] ?? 0}') ?? BigInt.zero,
        offerId: '${j['offerId'] ?? ''}',
        makerPubkey: '${j['makerPubkey'] ?? ''}',
        hashHex: '${j['hashHex'] ?? ''}',
        preimageHex: '${j['preimageHex'] ?? ''}',
        makerRefundPub: '${j['makerRefundPub'] ?? ''}',
        seqLocktime: (j['seqLocktime'] as int?) ?? 0,
        legTxid: '${j['legTxid'] ?? ''}',
        legVout: (j['legVout'] as int?) ?? -1,
        legRedeem: '${j['legRedeem'] ?? ''}',
        legP2shSpk: '${j['legP2shSpk'] ?? ''}',
        legP2shAddr: '${j['legP2shAddr'] ?? ''}',
        legBlockHash: '${j['legBlockHash'] ?? ''}',
        bolt11: '${j['bolt11'] ?? ''}',
        btcNodeKey: '${j['btcNodeKey'] ?? ''}',
        seqClaimTxid: '${j['seqClaimTxid'] ?? ''}',
        seqFundTxid: '${j['seqFundTxid'] ?? ''}',
        seqRefundTxid: '${j['seqRefundTxid'] ?? ''}',
        broadcastAttempted: j['broadcastAttempted'] == true,
        broadcastAt: (j['broadcastAt'] as num?)?.toInt() ?? 0,
        broadcastSeqHeight: (j['broadcastSeqHeight'] as num?)?.toInt() ?? 0,
        detail: '${j['detail'] ?? ''}',
      );
}

/// Persists the single active submarine. Distinct key from the cross forward/reverse stores so the
/// wizards never clobber each other.
class SubswapStore {
  SubswapStore._();
  static const _key = 'ambra.subswap.active';
  static const _storage = FlutterSecureStorage();

  /// SYNCHRONOUS in-memory mirror of "a NON-TERMINAL submarine record exists" — the Dart twin of swap.js's
  /// module-level SUBSWAP + hasSubswapInFlight(). Secure-storage reads are async, so WITHOUT a synchronous
  /// flag a fresh _start could save a new record over a live one in the load() gap (destroying its
  /// H/P/redeem/txid -> STRANDED funds). Primed at cold start (via [primeInFlight], AWAITED in shell startup
  /// BEFORE the Swap tab is interactive) and kept current by every [load]/[save]/[clear], so both the review
  /// dispatch and _start can refuse a second submarine with NO async race. One submarine at a time
  /// (whole-HTLC, resumable) — matches the web, whose hasSubswapInFlight is authoritative from the first
  /// frame because it hydrates SYNCHRONOUSLY at module-eval.
  static bool _inFlight = false;
  static bool get hasInFlight => _inFlight;

  /// Whether the guard has been AUTHORITATIVELY established from disk yet (by [primeInFlight], any [load], or
  /// a [save]/[clear]). Until then the default-false [hasInFlight] is NOT trustworthy — a caller reaching the
  /// swap surface in the cold-start window before priming completes MUST do an awaited [load] before acting
  /// on the flag (belt-and-suspenders), never fail open on the unprimed default and clobber a live record.
  static bool _primed = false;
  static bool get primed => _primed;

  /// Whether the LAST [load]/[primeInFlight] failed on a read/decode error rather than returning a definitive
  /// answer (Task 1 SELF-HEAL). A transient secure-storage READ error at cold start fails [hasInFlight] SAFE
  /// (assumes in-flight) — correct for fund-safety, but it would leave an IDLE wallet blocked with the false
  /// 'swap in progress' until some unrelated load happened to succeed. The dispatch choke points ([_start] /
  /// [_dispatchSubmarine]) re-run an AWAITED [load] when `!primed || primeErrored`, so a now-succeeding read
  /// HEALS the guard right where a swap would start — an idle wallet becomes startable again. CLEARED only on
  /// a definitive success (a decodable record, or a definitive empty). Set on BOTH a transient read error and
  /// a durable decode error; the durable case additionally sets [corrupt] (which never self-heals on retry).
  static bool _primeErrored = false;
  static bool get primeErrored => _primeErrored;

  /// Whether the persisted record is present but NOT DRIVABLE by this build (Task 1/2): either DURABLY
  /// UNDECODABLE (a torn write / a keystore-migration decrypt mismatch that yields bytes but not a parseable
  /// record) OR decoded-but-with an UNRECOGNISED state (SubState.unknown — version skew / a future-build state /
  /// a foreign write). Both throw on EVERY [load], so neither self-heals. Distinct from a transient read error
  /// (which [primeErrored]+the heal cover): a corrupt/unknown record
  /// NEVER heals by retrying, so without this the rail would be blocked FOREVER behind the false 'you already
  /// have one in progress'. The UI surfaces an honest distinct state + an explicit guarded RECOVER/clear
  /// affordance ([readRaw] to inspect, [clear] to discard after warning it may represent an in-flight swap).
  /// Cleared by a definitive success or a [clear]/[save].
  static bool _corrupt = false;
  static bool get corrupt => _corrupt;

  /// Set the synchronous [hasInFlight] flag directly — belt-and-suspenders for callers that must FORCE the
  /// guard closed (e.g. the cold-start resume's .catchError, so a read failure never leaves it open).
  static void markInFlight(bool v) => _inFlight = v;

  /// AWAITED cold-start prime: split from the heavy settlement drive [SubswapService.resume] so the guard is
  /// authoritative BEFORE the swap UI is reachable. Loads the persisted record and sets [hasInFlight] to
  /// "a non-terminal record exists". Never throws into startup — a read/decode error fails safe inside [load]
  /// (assumes in-flight) and is swallowed here; the guard is left CLOSED, never open. A transient read error
  /// sets [primeErrored] so the first successful [load] at a dispatch choke point HEALS the guard (Task 1); a
  /// durable decode error additionally sets [corrupt] so the UI can offer recovery instead of blocking forever.
  static Future<void> primeInFlight() async {
    try {
      await load(); // a definitive read sets _inFlight + _primed; a read/decode error fails safe (in-flight)
    } catch (_) {
      // [load] already failed safe (_inFlight = true, _primed = true, _primeErrored = true, and _corrupt on a
      // decode error). Priming must not throw into startup.
    }
  }

  /// Load the persisted record AND keep the synchronous guard authoritative. FAIL SAFE (fund-loss): a locked
  /// keystore / decrypt / unreadable read is NOT mistaken for "no record" — it sets [hasInFlight] true
  /// (primed-but-uncertain) and rethrows, so _start / _dispatchSubmarine BLOCK rather than clobber a
  /// possibly-live on-disk record. A read that DEFINITIVELY returns null/empty is the ONLY path that sets
  /// not-in-flight.
  ///
  /// DISTINGUISH TRANSIENT READ vs DURABLE CORRUPT (Task 1/2): the `_storage.read` and the decode are in
  /// SEPARATE try-blocks. An exception from the READ is transient (a locked/busy keystore) — it sets
  /// [primeErrored] so a retry at a dispatch choke point can HEAL the guard. An exception from decoding a
  /// PRESENT non-empty value is DURABLE (a torn write / keystore-migration decrypt mismatch): it throws on
  /// every load, so it additionally sets [corrupt] and the UI surfaces an explicit recovery affordance instead
  /// of an unbounded silent block. A definitive success (either branch) clears both flags.
  static Future<SubswapRecord?> load() async {
    String? s;
    try {
      s = await _storage.read(key: _key);
    } catch (e) {
      // TRANSIENT READ error: not proof of "no record". Fail safe + mark HEALABLE (Task 1) — a later
      // succeeding read at a choke point re-runs load() and clears the block. NOT corrupt (retry may succeed).
      _inFlight = true;
      _primed = true;
      _primeErrored = true;
      rethrow;
    }
    if (s == null || s.isEmpty) {
      _inFlight = false; // DEFINITIVE no record — the ONLY path that sets not-in-flight
      _primed = true;
      _primeErrored = false;
      _corrupt = false;
      return null;
    }
    try {
      final rec = SubswapRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
      // UNKNOWN STATE (Task 1, fund-loss): the JSON decoded, but its persisted 'state' was unrecognised by this
      // build (version skew / a future-build state / a foreign write) -> SubState.unknown. It is deliberately
      // NON-terminal, so the guard would (correctly) stay CLOSED — but this build cannot DRIVE it (we don't know
      // its phase), and it may represent a LIVE, funded swap. Route it through the SAME durable-recovery path as a
      // corrupt record: NEVER clobber/clear it, surface an explicit guarded RECOVER affordance. The throw is caught
      // just below (sets _inFlight = true + _corrupt = true and rethrows [SubswapCorruptRecordException]), so the
      // drive/resume ([_resumeInner]'s leading load) can never reach a clear() for an unknown-state record.
      if (rec.state == SubState.unknown) throw const SubswapCorruptRecordException();
      _inFlight = !rec.terminal;
      _primed = true;
      _primeErrored = false;
      _corrupt = false;
      return rec;
    } catch (e) {
      // DURABLE DECODE error: a value IS present but is unparseable, so it will throw on EVERY load. Fail safe
      // (assume in-flight) AND flag [corrupt] so the UI offers an honest recovery affordance instead of an
      // unbounded silent block. [primeErrored] is set too (per Task 1), but the heal alone never clears a
      // corrupt record — only an explicit [clear]/[save] does.
      _inFlight = true;
      _primed = true;
      _primeErrored = true;
      _corrupt = true;
      throw const SubswapCorruptRecordException();
    }
  }

  /// The RAW persisted value for the recovery affordance to INSPECT before the user clears a [corrupt] record.
  /// Returns the stored string as-is (undecodable), or null on an empty store / a transient read error — the
  /// inspection is best-effort and must never itself throw into the recovery UI.
  static Future<String?> readRaw() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(SubswapRecord r) async {
    _inFlight = !r.terminal; // keep the synchronous guard current on every persisted transition
    _primed = true;
    _primeErrored = false; // a healthy write proves the store is readable + this record decodable
    _corrupt = false;
    await _storage.write(key: _key, value: jsonEncode(r.toJson()));
  }

  static Future<void> clear() async {
    _inFlight = false;
    _primed = true;
    _primeErrored = false; // the store is now definitively empty — no read/decode error, no corrupt record
    _corrupt = false;
    await _storage.delete(key: _key);
  }
}

/// Thrown by [SubswapStore.load] when the persisted record is present but DURABLY UNDECODABLE (Task 2). Lets
/// a caller distinguish the corrupt case (surface the recovery affordance) from a transient read error
/// (fails safe + self-heals) — though [SubswapStore.corrupt] is the synchronous signal the UI actually gates on.
class SubswapCorruptRecordException implements Exception {
  const SubswapCorruptRecordException();
  @override
  String toString() =>
      'Your rail-crossing swap record is unreadable (it may represent an in-flight swap). Recovery is needed before you can start another.';
}

/// The verdict of the AUTHORITATIVE HTLC-address scan the manual ABANDON escape gates on (round 8). Only
/// [empty] — a SUCCESSFUL read (esplora `/address/<a>/utxo` covers confirmed AND mempool) that returned NO
/// output at the HTLC P2SH — may enable the clear; [funded] (an output is there) and [unreadable] (a read
/// error / no scannable address) both keep the record RESUMABLE (fund-safe: never clear over possible funds
/// or an unread state).
enum HtlcScanResult { empty, funded, unreadable }

// ===========================================================================
// The driver — builds the real deps from ambra_core + the LSP + esplora + the courier, and runs the
// verified taker. Mirrors swap.js driveSubswap; the fund-safety cores above are the SAME logic the web
// unit-tests. `onStep` surfaces progress; the record is persisted after every transition.
// ===========================================================================

class SubswapService {
  SubswapService._();

  /// NO-DOUBLE-DRIVE guard (Task 3), the Dart twin of swap.js's `_subswapDriving`. A cold-start UNAWAITED
  /// [resume] (fired from shell) can still be settling the SAME record when the user taps 'Resume swap' (or a
  /// second cold-start path fires) — a SECOND concurrent drive would fire duplicate settle/claim/refund
  /// broadcasts (idempotent on-chain, but racy). This GLOBAL one-at-a-time flag (a submarine is one-at-a-time)
  /// is set at the start of any drive ([runReverseBuy]/[runSubmarineSell]/[resume]) and cleared in a finally,
  /// so a second concurrent drive short-circuits. Mirrors the web `if (... || _subswapDriving) return;`.
  static bool _driving = false;
  static bool get driving => _driving;

  /// TEST SEAM (Task 3) — force the one-at-a-time [_driving] guard so a unit test can assert that a concurrent
  /// [runReverseBuy]/[runSubmarineSell] throws and [resume] short-circuits, without spinning up a real drive
  /// (which needs the wallet + LSP + network). NEVER used in production code.
  @visibleForTesting
  static set debugDriving(bool v) => _driving = v;

  /// TEST SEAM (round 13) — override the AUTHORITATIVE RE-SCAN the abandon clear gate runs on the FRESH on-disk
  /// record immediately before [SubswapStore.clear] (the re-scan-before-clear that stops trusting the stale
  /// pre-dialog scan). Production leaves it null, so the real [scanHtlcForAbandon] runs (real esplora + tip-height
  /// I/O). A test sets it to drive the re-scan outcome (empty -> the clear proceeds; funded/unreadable -> the gate
  /// refuses) without spinning up the network. NEVER used in production code.
  @visibleForTesting
  static Future<HtlcScanResult> Function(SubswapRecord rec)? debugRescanForAbandon;

  // -- ROUND 8: user-initiated FUND-SAFE ABANDON of a stuck SELL 'funding' record ----------------------
  //
  // The residual liveness hole: a SELL that reached the broadcast INTENT (broadcastAttempted=true) but never
  // actually landed a funding tx — a hard-kill in the ms gap before finalizeAndBroadcast, or a definitive
  // broadcast rejection where the tx never entered the mempool — can NEVER be D0-auto-cleared. The D0
  // pre-commitment drop requires broadcastAttempted==false, and once the intent is set an empty scan is (rightly,
  // for the AUTOMATIC path) treated as "a broadcast MAY have gone out" and kept resumable forever. Being
  // non-terminal + non-corrupt, the record also never reaches the corrupt-recovery affordance. So the rail wedges
  // on 'swap in progress' with NO escape. This is NOT fund-loss (nothing was funded), but it is a liveness
  // dead-end. The escape below is USER-initiated + WARNED (never automatic) and FUND-SAFE by construction: it
  // clears ONLY a SELL still in 'funding' (legTxid empty — not yet settling) whose AUTHORITATIVE on-chain
  // HTLC-address scan is DEFINITIVELY EMPTY. A funded or unreadable scan NEVER clears (keeps it resumable),
  // mirroring the corrupt-recovery guardrails; the human warning is the final gate the automatic path cannot ask.

  /// The minimum number of Sequentia BLOCKS the backend's current tip HEIGHT must sit ABOVE the record's
  /// [SubswapRecord.broadcastSeqHeight] before an empty `/address/utxo` scan may be trusted to abandon (round 11
  /// CLOCK-FREE fund-loss gate; round 12 made it the SOLE margin). This single height depth now provides the
  /// ENTIRE staleness AND reorg margin of the abandon decision — there is NO wall-clock companion gate. It
  /// REPLACES the earlier device-clock block-TIME check (tipFreshForAbandon) AND the round-9 wall-clock age gate
  /// (kAbandonMinBroadcastAge / broadcastAgedForAbandon, both removed round 12): both compared to DateTime.now()
  /// and could be defeated by a slow/fast device clock — a forward clock jump eroded the age margin, making a
  /// stale backend's false 200-`[]` on a FUNDED HTLC read as EMPTY and stranding the asset. Heights are
  /// MONOTONIC (modulo anchor reorgs, see below) and independent of any wall clock, so this gate cannot be moved
  /// by device-clock skew.
  ///
  /// SIZED FOR ~2h AND REORG-SAFE (round 12): ~240 blocks at [kFastSeqSecs] ~30s slots ≈ 2 hours. This is well
  /// past BOTH (a) any funding-confirmation depth — a real asset-HTLC fund confirms within a slot or two of
  /// broadcast — AND (b) any realistic Bitcoin-anchored reorg depth. Because it is now the ONLY margin (no wall
  /// clock backstop), it is deliberately deep: a tip that is 240 blocks past the broadcast height genuinely
  /// proves the funding window is buried, so an empty scan is genuinely unfunded rather than a lagging/stalled
  /// replica.
  ///
  /// REORG NOTE (Bitcoin-anchoring supremacy): Sequentia references a Bitcoin block header per block and reorgs
  /// whenever Bitcoin reorgs, so Sequentia heights are monotonic ONLY modulo anchor reorgs. 240 blocks (~2h) is
  /// chosen to exceed any realistic anchor-reorg depth, so tip >= broadcastSeqHeight + 240 truly proves the
  /// funding window is buried. And if a reorg ever WERE deep enough to revert past [SubswapRecord.broadcastSeqHeight],
  /// it would also revert/unconfirm the funding tx itself — so an empty scan at that point is CORRECT (nothing is
  /// funded on the surviving chain), not a false negative. Either way the height proof stays fund-safe.
  ///
  /// A backend whose tip has NOT advanced this many blocks past broadcast classifies the empty scan as
  /// UNREADABLE (fail closed) — the fund-safe direction: a marginally-behind backend only costs a retry, never a
  /// false clear over a possibly-funded HTLC.
  static const int kAbandonMinConfDepth = 240;

  /// Whether [rec] is a candidate for the manual ABANDON affordance: a SELL still in the pre-settlement
  /// 'funding' phase with [legTxid] empty AND [seqFundTxid] empty — once legTxid is set it is 'settling', has a
  /// funded on-chain HTLC, and must NEVER be abandonable. PURE. This is ONLY the PHASE gate (whether to OFFER
  /// the escape at all).
  ///
  /// SEQ-FUND-TXID GUARD (round 10, fund-loss): a persisted [seqFundTxid] is DIRECT proof the funding tx was
  /// recorded — the asset HTLC WAS broadcast and its txid saved (subswap_service.dart persists it right after
  /// [xchainSeqBroadcast]). Such a record is FUNDED and must be refused regardless of any on-chain scan: an
  /// esplora backend that transiently returns `[]` (lagging the mempool, or STALLED-but-serving) must never let
  /// a record with a recorded fund txid be abandoned. The empty-scan path exists only as a BACKSTOP for the
  /// narrow window where the fund landed but [seqFundTxid] never persisted (a crash between broadcast and save);
  /// once the txid is on disk, it is authoritative over the scan.
  ///
  /// Being abandonable ALSO requires a DEFINITIVELY-EMPTY authoritative scan (which itself requires the
  /// CLOCK-FREE tip-HEIGHT proof — see [scanHtlcForAbandon] / [tipHeightProvesEmptyScan]) AND a
  /// fresh-reload-not-advanced record AND nothing-driving AND identity — ALL enforced together by
  /// [abandonUnfundedSell], which re-derives them from disk + the live guard rather than trusting a stale rec.
  /// There is NO wall-clock age gate (removed round 12): the height depth [kAbandonMinConfDepth] provides the
  /// entire staleness/reorg margin, so no DateTime.now() sits on the abandon fund-safety path.
  static bool canAbandonFunding(SubswapRecord rec) =>
      !rec.buy && rec.state == SubState.funding && rec.legTxid.isEmpty && rec.seqFundTxid.isEmpty;

  /// Classify the raw [_seqAddressUtxos] return for the abandon gate. PURE. null (a non-200 / read error) is
  /// UNREADABLE (never enables abandon); any entry is FUNDED (an output sits at the HTLC P2SH); an empty list is
  /// DEFINITIVELY EMPTY (esplora `/utxo` covers confirmed AND mempool, so `[]` means genuinely unfunded) ONLY
  /// WHEN [tipProvesEmpty] holds — i.e. the backend's tip HEIGHT proves it is past the funding-confirmation window.
  ///
  /// TIP-HEIGHT PROOF (round 11, CLOCK-FREE, fund-loss): an empty list from a STALLED-but-serving backend is a
  /// false negative — the HTLC is funded but the backend's frozen index does not show it. So an empty scan is
  /// trusted as [HtlcScanResult.empty] only when [tipProvesEmpty] is true (the backend's current tip HEIGHT is
  /// well past the height captured at broadcast — see [tipHeightProvesEmptyScan]); against a not-advanced backend
  /// an empty list is UNREADABLE, not empty, so the abandon is refused (fund-safe). This replaces the round-10
  /// device-clock block-TIME check (removed): heights are MONOTONIC and clock-independent, so device-clock skew
  /// cannot promote a stale backend's `[]` to EMPTY. [tipProvesEmpty] is irrelevant to the null (already
  /// unreadable) and non-empty (already funded) cases — it is consulted only to promote an empty list.
  static HtlcScanResult classifyHtlcScan(List<dynamic>? utxos, {bool tipProvesEmpty = false}) {
    if (utxos == null) return HtlcScanResult.unreadable;
    if (utxos.isNotEmpty) return HtlcScanResult.funded;
    // Empty list: definitively empty ONLY when the tip HEIGHT proves it; otherwise a stalled backend's false empty.
    return tipProvesEmpty ? HtlcScanResult.empty : HtlcScanResult.unreadable;
  }

  /// CLOCK-FREE height proof that an empty `/address/utxo` scan is trustworthy (round 11, fund-loss). PURE.
  /// REPLACES the device-clock tipFreshForAbandon (removed): instead of comparing a tip block-TIME to
  /// DateTime.now() — which a slow/fast device clock could defeat, making a stale tip read as "fresh" and
  /// false-emptying a funded HTLC — it compares the backend's CURRENT tip [tipHeight] to the [broadcastSeqHeight]
  /// captured at broadcast. True (an empty scan may be trusted) ONLY when the backend has advanced its tip to at
  /// least broadcastSeqHeight + [minConfDepth] — provably past the funding-confirmation window, so a funded HTLC
  /// would be visible. Heights are MONOTONIC and independent of any wall clock, so no device-clock skew changes
  /// the decision. FAILS CLOSED (returns false -> the empty scan stays UNREADABLE) when [broadcastSeqHeight] is
  /// 0/absent (a pre-r11 record, or an unreadable tip at broadcast time) or when [tipHeight] is negative (an
  /// unreadable current tip) — an unprovable tip can never certify an empty scan as abandonable.
  static bool tipHeightProvesEmptyScan({
    required int tipHeight,
    required int broadcastSeqHeight,
    int minConfDepth = kAbandonMinConfDepth,
  }) {
    if (broadcastSeqHeight <= 0) return false; // pre-r11 / unstamped / unreadable-at-broadcast -> fail closed
    if (tipHeight < 0) return false; // unreadable current tip -> fail closed
    return tipHeight >= broadcastSeqHeight + minConfDepth;
  }

  /// Run the AUTHORITATIVE on-chain HTLC-address scan for the abandon gate: read the persisted HTLC P2SH
  /// address's confirmed + mempool UTXOs ([_seqAddressUtxos]) and classify. An EMPTY persisted address cannot
  /// prove non-funding, so it is treated as UNREADABLE (fail closed — never enable abandon on a record whose
  /// HTLC we cannot even scan).
  ///
  /// TIP-HEIGHT PROOF (round 11, CLOCK-FREE, fund-loss): a null (read error) is already UNREADABLE and a non-empty
  /// list is already FUNDED, both independent of the tip. ONLY when the list is empty does the tip HEIGHT matter:
  /// the backend's current tip ([_seqTipHeight]) must be at least [kAbandonMinConfDepth] blocks PAST the record's
  /// [SubswapRecord.broadcastSeqHeight] ([tipHeightProvesEmptyScan]) before the empty list is promoted to
  /// [HtlcScanResult.empty]. A stalled-but-serving backend (tip not advanced past the funding window) returns a
  /// false empty on a funded HTLC; the height proof classifies that as UNREADABLE, so the abandon is refused
  /// rather than clearing over locked funds. Heights are monotonic + clock-independent, so device-clock skew (the
  /// round-11 flaw in the old block-TIME check) cannot defeat it.
  ///
  /// BEST-EFFORT CONSISTENCY: the tip HEIGHT is read as close as possible to the `/utxo` read, and — deliberately
  /// — read FIRST. For a SINGLE backend that is monotonically catching up, reading the height first bounds chain
  /// progress at time T1, and the (later) utxo read is then against a tip at least that high; so if the height
  /// gate passes, that same replica has already indexed the funding block and its utxo read would show the funding
  /// rather than []. This gives a provable single-oracle guarantee. It does NOT hold across a load-balancer that
  /// routes the two reads to DIFFERENT replicas (utxo -> a lagging one, height -> a fresh one) — that irreducible
  /// single-oracle residual is documented on [abandonUnfundedSell]; esplora exposes no atomic utxo+tip read, and
  /// there is no independent second Sequentia-UTXO oracle in the client to cross-check against.
  static Future<HtlcScanResult> scanHtlcForAbandon(SubswapRecord rec) async {
    final addr = rec.legP2shAddr;
    if (addr.isEmpty) return HtlcScanResult.unreadable;
    // Read the tip HEIGHT FIRST, then the utxos immediately after (best-effort adjacency + single-oracle safety:
    // the later utxo read is against a chain at least as advanced as the height we gate on).
    final tipHeight = await _seqTipHeight();
    final utxos = await _seqAddressUtxos(addr);
    if (utxos == null) return HtlcScanResult.unreadable; // read error — never enable abandon
    if (utxos.isNotEmpty) return HtlcScanResult.funded; // an output at the HTLC P2SH — funded, tip is irrelevant
    // Empty list: trust it as definitively-empty ONLY if the tip HEIGHT proves the backend is past the funding window.
    final proves = tipHeightProvesEmptyScan(tipHeight: tipHeight, broadcastSeqHeight: rec.broadcastSeqHeight);
    return classifyHtlcScan(utxos, tipProvesEmpty: proves);
  }

  /// FUND-SAFE clear gate for the manual abandon — the ONLY place the escape drops a 'funding' record, and
  /// SAFE-BY-CONSTRUCTION: it can NEVER clear a possibly-funded or stale record, and it is FULLY CLOCK-FREE
  /// (round 12 — no DateTime.now() anywhere on this fund-safety path). It re-derives every fact from
  /// AUTHORITATIVE state (disk + the live guard), never trusting the passed-in [rec] beyond routing, and clears
  /// ONLY when ALL of these gates hold:
  ///   1. NOT-DRIVING — [_driving] is clear, so no cold-start resume/drive is advancing this record. We refuse
  ///      while one is in flight AND hold the one-at-a-time guard for the brief decision so none can START and
  ///      advance the record between our fresh reload and the clear (fixes the concurrent-resume clobber).
  ///   2. FRESH RELOAD + SEQ-FUND-TXID GUARD — the record RE-LOADED FROM DISK (never the stale [rec]) is the
  ///      SAME swap (offer + HTLC address the caller scanned) AND still [canAbandonFunding] on the FRESH record:
  ///      an eligible SELL 'funding' record with an empty legTxid AND an empty [seqFundTxid] (round 10). A
  ///      persisted seqFundTxid is DIRECT proof the funding tx was recorded, so a fresh record carrying one is
  ///      FUNDED and refused regardless of the scan. If a concurrent resume found the funding and advanced it to
  ///      settling/terminal, set a legTxid, or persisted a seqFundTxid — or a different swap now occupies the
  ///      single slot — the FRESH record wins and we ABORT (fixes the stale-rec clobber; a foreign scan never
  ///      clears the disk record).
  ///   3. IDENTITY — the fresh on-disk record is the SAME swap (offer + HTLC address) the caller scanned; a
  ///      different swap now in the single slot means the passed [scan] does not apply, so abort.
  ///   4a. PRE-DIALOG EMPTY SCAN (offer evidence, NOT the authoritative signal) — the caller's [scan], captured
  ///      BEFORE the user saw the warning dialog, must be DEFINITIVELY EMPTY. This only proves the escape was
  ///      OFFERED on empty evidence; it is deliberately NOT trusted as the clear signal (a user can linger on the
  ///      dialog while a broadcast confirms — see 4b).
  ///   4b. RE-SCAN BEFORE CLEAR (the SOLE staleness/reorg margin, CLOCK-FREE; round 13) — immediately before the
  ///      clear, under the held _driving guard, RE-RUN [scanHtlcForAbandon] on the FRESH record and require it is
  ///      STILL [HtlcScanResult.empty]. [scanHtlcForAbandon] only produces [HtlcScanResult.empty] when the
  ///      backend's tip HEIGHT is proven to be at least [kAbandonMinConfDepth] (~240) blocks PAST the record's
  ///      broadcast height (see [tipHeightProvesEmptyScan]), so a stalled-but-serving backend's false 200-`[]`
  ///      arrives here as UNREADABLE and is refused. This height depth alone provides the ENTIRE staleness AND
  ///      anchor-reorg margin — there is NO wall-clock age gate (removed round 12). Heights are MONOTONIC (modulo
  ///      anchor reorgs, which 240 blocks is sized to exceed) and clock-independent, so a slow/fast device clock
  ///      — including a forward jump — cannot promote a stale scan to EMPTY. Re-scanning HERE (not trusting 4a)
  ///      closes the DIALOG-LINGER window: a funding tx that (re)broadcast and confirmed while the user read the
  ///      warning now shows FUNDED on this fresh read and the clear is refused.
  /// Returns true iff it cleared (rail freed). ANY failed gate keeps the record resumable. NEVER call without
  /// first showing the user the explicit "your asset could be at the HTLC address" warning.
  ///
  /// RESIDUAL (honest IRREDUCIBLE limitation — NOT an unconditional guarantee): with the decision now fully
  /// clock-free AND re-scanned at clear time, the ONLY remaining residual is the SINGLE-ESPLORA-ORACLE trust
  /// root, in two capture-and-check-time variants of the same replica-split. The abandon's 'unfunded' authority
  /// ultimately rests on ONE esplora oracle; there is no independent second Sequentia-UTXO oracle in the client
  /// to cross-check against, so a single backend behind a load balancer is the irreducible trust root:
  ///   (i) CHECK-TIME split — the re-scan's `/address/utxo` read routes to a LAGGING replica (a false 200-`[]` on
  ///       a funded HTLC) while its adjacent `/blocks/tip/height` read hits a FRESH replica that satisfies the
  ///       height proof. The height proof [tipHeightProvesEmptyScan] closes the SAME-replica / single-catching-up
  ///       case (reading the height first bounds progress; a same replica that passes the height gate has indexed
  ///       the funding block), and is clock-free so device-clock skew no longer defeats it — but it CANNOT assert
  ///       cross-replica consistency the client cannot guarantee, and this code deliberately does not pretend to.
  ///   (ii) CAPTURE-TIME split — the broadcast-time [SubswapRecord.broadcastSeqHeight] stamp is read from esplora
  ///       too, so height-proof soundness ASSUMES that stamp is within [kAbandonMinConfDepth] of the TRUE tip at
  ///       broadcast; a lagging broadcast-time replica that under-records it would let the proof pass early. The
  ///       broadcast hook mitigates by stamping the MAX of a couple of tip reads (over-recording only makes the
  ///       proof MORE conservative), but it is the same single-oracle class and cannot be eliminated client-side.
  /// The RE-SCAN-BEFORE-CLEAR (gate 4b) additionally closes the DIALOG-LINGER window that trusting the stale
  /// pre-dialog [scan] left open — a funding that (re)confirms while the user reads the warning is caught. The
  /// layered gates shrink the residual false-empty to an extremely narrow intersection: a load-balanced backend
  /// would have to split reads across a lagging + a fresh replica (at check time, or under-record at capture
  /// time) AND the record has NO recorded seqFundTxid (the SEQ-FUND-TXID GUARD) AND the fresh on-disk record is
  /// still an eligible 'funding' record AND no drive is advancing it AND the human clicked past the explicit
  /// "your asset could be at the HTLC address" warning — all at once. Even then this is strictly SAFER than the
  /// web wallet's D0 path, which auto-clears an unfunded SELL with NO tip cross-check and NO human confirmation.
  /// This is a bounded best-effort escape for a real liveness dead-end, documented as such — NOT a claim that a
  /// false clear is impossible. A truly independent second Sequentia-UTXO source would be the only full fix (out
  /// of scope; noted).
  static Future<bool> abandonUnfundedSell(SubswapRecord rec, HtlcScanResult scan) async {
    // Gate 4a (cheap/pure PRE-DIALOG scan) + gate 1 (read): refuse a non-empty pre-dialog scan or an in-flight
    // drive before touching disk. The passed-in [scan] is the WARNING's evidence, captured BEFORE the user saw
    // the abandon dialog; it is deliberately NOT the authoritative clear signal (see the re-scan below).
    if (scan != HtlcScanResult.empty) return false; // PRE-DIALOG EMPTY-SCAN gate — a funded/unreadable pre-scan never proceeds
    if (_driving) return false; // NOT-DRIVING gate — a resume is advancing this record; let it win
    // Acquire the one-at-a-time guard so no resume can START and advance the record during our fresh-reload ->
    // re-scan -> clear window (safe-by-construction against the cold-start-resume clobber). Released in the finally.
    _driving = true;
    try {
      // Gate 2 — FRESH RELOAD: operate on the on-disk record, NEVER the passed-in stale one. Fail closed on an
      // unreadable/corrupt reload (never clear over a record we cannot even read).
      SubswapRecord? fresh;
      try {
        fresh = await SubswapStore.load();
      } catch (_) {
        return false;
      }
      if (fresh == null) return false; // already gone — nothing to clear
      // Gate 3 — IDENTITY: the disk record must be the SAME swap the caller scanned (its HTLC address is what
      // [scan] covers). If a different swap now occupies the single-swap slot, the passed scan does not apply.
      if (fresh.offerId != rec.offerId || fresh.legP2shAddr != rec.legP2shAddr) return false;
      // A concurrent resume that advanced past 'funding' (settling/terminal), set a legTxid (found the funding
      // on-chain), or persisted a seqFundTxid (recorded the funding broadcast — round 10 SEQ-FUND-TXID GUARD)
      // makes this NOT [canAbandonFunding] on the fresh record — abort, the recorded funding wins over any scan.
      if (!canAbandonFunding(fresh)) return false;
      // Gate 4b — RE-SCAN BEFORE CLEAR (round 13, silent-degrade -> fund-loss): the pre-dialog [scan] must NOT be
      // trusted at clear time. The user can linger on the warning dialog for an unbounded interval, and a
      // (re)broadcast funding tx can confirm in that gap — after the pre-dialog scan read empty. So RE-RUN the
      // AUTHORITATIVE clock-free height-proof + /utxo scan ([scanHtlcForAbandon]) on the FRESH record HERE, under
      // the held _driving guard, and FAIL CLOSED unless it is STILL definitively empty. A funding that landed
      // during the dialog delay now classifies FUNDED (or, if the backend is only transiently behind, UNREADABLE),
      // both of which refuse the clear (fund-safe). This is the authoritative EMPTY-SCAN gate; gate 4a only proves
      // the escape was OFFERED on empty evidence.
      final rescan = await (debugRescanForAbandon ?? scanHtlcForAbandon)(fresh);
      if (rescan != HtlcScanResult.empty) return false;
      // ALL gates hold (NO wall clock consulted — the re-scan's clock-free height proof is the sole margin):
      // the warned clear proceeds (rail freed).
      await SubswapStore.clear();
      return true;
    } finally {
      _driving = false;
    }
  }

  static Future<String> _mnemonic() async {
    final m = await WalletRepository.instance.readMnemonic();
    if (m == null) throw Exception('Your wallet is locked; unlock it and try again.');
    return m;
  }

  // -- REVERSE BUY (ln_direction=1) -------------------------------------------------------------------

  /// Run the P2P reverse-submarine BUY to completion (pay BTC over Lightning, receive the asset on-chain).
  /// VERIFY-BEFORE-PAY (all fail-closed BEFORE the single irreversible payInvoice): redeem+binding+P2SH
  /// (claim=my key on H, right asset/amount/locktime, funding pays the HTLC P2SH); seq claim window;
  /// anchor-buried POLL; bolt11 payment_hash == H; bolt11 amount == the offer price; re-check the claim
  /// window; hold-CLTV gate; PERSIST leg+bolt11+H; then pay -> learn P -> PERSIST P -> claim.
  /// Wrapped by the [_driving] NO-DOUBLE-DRIVE guard (Task 3) so it never runs concurrently with a resume.
  static Future<SubswapRecord> runReverseBuy(SubswapRecord rec, {void Function(String)? onStep}) async {
    if (_driving) {
      throw Exception('A rail-crossing swap is already being driven; wait for it to finish or resume it before starting another.');
    }
    _driving = true;
    try {
      return await _runReverseBuy(rec, onStep: onStep);
    } finally {
      _driving = false;
    }
  }

  static Future<SubswapRecord> _runReverseBuy(SubswapRecord rec, {void Function(String)? onStep}) async {
    void step(String s) => onStep?.call(s);
    final m = await _mnemonic();
    final claimPub = await core.xchainSeqClaimPubkey(mnemonic: m); // the taker's OWN canonical SEQ claim key
    if (rec.assetAtoms <= BigInt.zero) throw Exception('reverse submarine: offer expectations (asset + atoms) are required');

    step('Opening a private channel to the maker…');
    final courier = await CrossCourier.open(
      offerId: rec.offerId,
      makerPubHex: rec.makerPubkey,
      takeAmount: rec.assetAtoms,
    );
    try {
      // 1. Request terms; hand the maker our SEQ-claim pubkey up front.
      await courier.send({'type': XcSubType.termsRequest, 'taker_seq_claim_pub': claimPub.toLowerCase()});
      step('Waiting for the maker to lock the asset…');
      final locked = await courier.recv(XcSubType.assetLocked, timeout: const Duration(minutes: 15));
      rec.state = SubState.verifying;
      await SubswapStore.save(rec);

      final leg = (locked['leg'] as Map?)?.cast<String, dynamic>();
      final bolt11 = '${locked['bolt11'] ?? ''}';
      final hashH = '${locked['hash_h'] ?? locked['hashH'] ?? ''}'.toLowerCase();
      final makerRefundPub = '${locked['maker_refund_pub'] ?? locked['makerRefundPub'] ?? ''}';
      final seqLocktime = _int(locked['seq_locktime'] ?? locked['seqLocktime']);
      if (leg == null || bolt11.isEmpty || !_kHex64.hasMatch(hashH)) {
        await courier.fail('MISSING_LEG', 'asset leg + bolt11 required');
        throw Exception('reverse submarine: the maker sent no asset leg / bolt11 / H');
      }
      final legTxid = '${leg['txid'] ?? ''}';
      final legVout = _int(leg['vout']);
      final legAmount = _big(leg['amount']);
      final legAsset = '${leg['asset'] ?? ''}';
      final legLocktime = _int(leg['locktime'] ?? seqLocktime);
      final providedRedeem = '${leg['redeem_script'] ?? leg['redeemScript'] ?? ''}';

      step('Verifying the asset is locked to your key…');
      // 2a. Rebuild the FORWARD redeem (claim = OUR canonical key on H, refund = the maker's key) and
      //     byte-compare — proves the asset HTLC's claim branch is spendable by US with P. This also
      //     yields the P2SH spk we require the funding output to pay.
      final htlc = await core.xchainSeqHtlcForward(
        mnemonic: m,
        hashHex: hashH,
        makerSeqRefundPubHex: makerRefundPub,
        seqLocktime: seqLocktime,
      );
      final vr = checkRedeemMatches(rebuilt: htlc.redeemScriptHex, provided: providedRedeem);
      if (!vr.ok) {
        await courier.fail('SEQ_LEG_INVALID', vr.reason);
        throw Exception('reverse submarine: ${vr.reason}');
      }
      // 2b. Bind the leg's amount/asset/locktime to the signed offer's expectations.
      final vb = checkLegBinding(
        legAmount: legAmount,
        legAsset: legAsset,
        legLocktime: legLocktime,
        legTxid: legTxid,
        legVout: legVout,
        expectAsset: rec.asset,
        expectAtoms: rec.assetAtoms,
        expectLocktime: seqLocktime,
      );
      if (!vb.ok) {
        await courier.fail('SEQ_LEG_INVALID', vb.reason);
        throw Exception('reverse submarine: ${vb.reason}');
      }
      // 2c. Read the on-chain funding output and confirm it pays the HTLC P2SH with the right asset+amount.
      final tx = await _seqTx(legTxid);
      final vouts = (tx?['vout'] as List?) ?? const [];
      final o = (legVout >= 0 && legVout < vouts.length) ? vouts[legVout] as Map? : null;
      final vf = checkFundingOutput(
        outputSpk: o == null ? null : '${o['scriptpubkey'] ?? ''}',
        outputValue: o == null ? null : _big(o['value']),
        outputAsset: o == null ? null : '${o['asset'] ?? ''}',
        expectSpkHex: htlc.p2ShSpkHex,
        expectAtoms: rec.assetAtoms,
        expectAsset: rec.asset,
      );
      if (!vf.ok) {
        await courier.fail('SEQ_LEG_INVALID', vf.reason);
        throw Exception('reverse submarine: ${vf.reason}');
      }
      rec
        ..hashHex = hashH
        ..makerRefundPub = makerRefundPub
        ..seqLocktime = seqLocktime
        ..legTxid = legTxid
        ..legVout = legVout
        ..legRedeem = htlc.redeemScriptHex
        ..state = SubState.verified;
      await SubswapStore.save(rec);

      // 3. SEQ CLAIM WINDOW: T_seq must leave enough runway that after paying + claiming we are still
      //    strictly before it. Refuse a leg whose window is already too small.
      final seqTip1 = await _seqTipHeight();
      if (seqTip1 < 0) {
        await courier.fail('SEQ_TIP_UNREADABLE', 'seq tip');
        throw Exception('reverse submarine: the Sequentia tip is unreadable (cannot gate the claim window; failing closed)');
      }
      if (!(seqLocktime > seqTip1 + kSubClaimMargin)) {
        await courier.fail('BAD_LOCKTIME', 'seq_locktime leaves too small a claim window');
        throw Exception('reverse submarine: seq_locktime $seqLocktime vs tip $seqTip1 leaves < $kSubClaimMargin-block claim window');
      }

      // 4. ANCHOR GATE: POLL until the asset HTLC funding block is Bitcoin-anchor-buried >= minAnchorDepth
      //    (a fresh 0–2 conf leg is WAITED OUT, not aborted) — a plain invoice cannot be refunded once paid.
      step('Waiting for the asset to anchor to Bitcoin…');
      final anchored = await _waitAnchorBuried(
        txid: legTxid,
        minDepth: kSubMinAnchorDepth,
        onWait: () => step('Waiting for the asset block to confirm and anchor to Bitcoin…'),
      );
      if (!anchored) {
        await courier.fail('ANCHOR_TIMEOUT', 'asset HTLC not anchor-buried in time');
        throw Exception('reverse submarine: the asset HTLC did not anchor-bury in time; your Bitcoin was NOT paid.');
      }

      // 5. PAYMENT-HASH gate: the invoice payment_hash MUST equal H BEFORE paying. Paying a hash != H
      //    yields a preimage that opens NOTHING — the single worst fund-loss. FAIL CLOSED on undecodable.
      final payHash = bolt11PaymentHash(bolt11);
      if (payHash == null || payHash != hashH) {
        await courier.fail('BAD_INVOICE_HASH', 'bolt11 payment_hash != H');
        throw Exception(
            'reverse submarine: the invoice payment_hash ${payHash ?? '(undecodable)'} != the asset HTLC hash H — NOT paying (it would open nothing)');
      }
      // 6. AMOUNT gate: a STATED invoice amount MUST equal the offer's BTC price. Amountless is fine.
      final invMsat = bolt11AmountMsat(bolt11);
      final expectMsat = rec.btcSats * BigInt.from(1000);
      if (invMsat != null && invMsat != expectMsat) {
        await courier.fail('BAD_INVOICE_AMOUNT', 'bolt11 amount != the offer price');
        throw Exception('reverse submarine: the invoice demands $invMsat msat != the offer\'s $expectMsat msat');
      }
      // 7. RE-CHECK the claim window immediately before the irreversible pay (the tip advanced during the poll).
      final seqTip2 = await _seqTipHeight();
      if (seqTip2 < 0 || !(seqLocktime > seqTip2 + kSubClaimMargin)) {
        await courier.fail('BAD_LOCKTIME', 'seq claim window closed before pay');
        throw Exception('reverse submarine: the claim window closed before paying (seq_locktime $seqLocktime vs tip $seqTip2) — NOT paying');
      }
      // 7b. HOLD-INVOICE CLTV gate (the hold masquerade). Decode min_final_cltv and REQUIRE the LATEST the
      //     maker could still settle leaves us a claim margin before T_seq. Cap our OWN outgoing max-cltv at
      //     fc so a HELD payment refunds as early as the invoice allows.
      final finalCltv = bolt11MinFinalCltv(bolt11);
      final cltvGate = holdCltvSafeVsTseq(finalCltv: finalCltv, seqTip: seqTip2, seqLocktime: seqLocktime, claimMargin: kSubClaimMargin);
      if (!cltvGate.ok) {
        await courier.fail('BAD_HOLD_CLTV', 'bolt11 min_final_cltv could let a hold settle past T_seq');
        throw Exception('reverse submarine: ${cltvGate.reason}');
      }
      final payMaxCltv = finalCltv ?? 0;

      // 8. CRASH GAP: persist the leg + bolt11 + H + a 'paying' marker BEFORE payInvoice, so a crash
      //    between the (irreversible) pay and learning P can RECOVER P (resume re-queries the node) + claim.
      rec
        ..bolt11 = bolt11
        ..state = SubState.paying;
      await SubswapStore.save(rec);

      // 9. Pay the invoice over the user's OWN BTC-LN node -> learn P. IRREVERSIBLE. Thread wantHash(H) +
      //    amountMsat + maxCltv so the node binds them (client-side gates above remain the PRIMARY guard).
      step('Paying the maker over Lightning…');
      final btcNodeKey = await LightningService.instance.connectNode(m, chain: 'btc');
      rec.btcNodeKey = btcNodeKey;
      await SubswapStore.save(rec);
      final pay = await LspClient.nodePay(
        nodeKey: btcNodeKey,
        bolt11: bolt11,
        wantHash: hashH,
        amountMsat: expectMsat,
        maxCltv: payMaxCltv > 0 ? payMaxCltv : null,
      );
      final preimage = (pay.preimage ?? '').toLowerCase();
      if (!_kHex64.hasMatch(preimage)) {
        throw Exception('reverse submarine: the Bitcoin Lightning payment returned no 32-byte preimage');
      }
      // Defence-in-depth (mirror subswap.js post-pay sha256(P)==H): the preimage we were paid MUST hash to
      // H BEFORE we persist it and claim — a hosted node / LSP that returns a wrong preimage past wantHash
      // is caught here (a wrong P opens NOTHING). Fail closed on any mismatch.
      if (_sha256Hex(preimage) != hashH) {
        throw Exception('reverse submarine: the learned preimage does not hash to H');
      }
      rec
        ..preimageHex = preimage
        ..state = SubState.claiming;
      await SubswapStore.save(rec);

      // 10. Claim the asset with the learned P (RETRYABLE — we hold P; a failure here resumes via the record).
      step('Claiming your asset…');
      await _claimReverse(rec, m);
      step('Swap complete.');
      return rec;
    } catch (e) {
      await courier.close();
      rethrow;
    } finally {
      await courier.close();
    }
  }

  /// Claim the reverse-buy asset leg with the persisted P (idempotent-safe: a re-claim of an already-spent
  /// HTLC just fails harmlessly and the asset is already ours). Used inline + on resume.
  static Future<void> _claimReverse(SubswapRecord rec, String mnemonic) async {
    final dest = await core.receiveAddress(mnemonic: mnemonic); // our own tb1 (valid SEQ addr)
    final fee = await _seqClaimFee(rec.asset, rec.assetAtoms);
    final hex = await core.xchainSeqClaim(
      mnemonic: mnemonic,
      seqTxid: rec.legTxid,
      seqVout: rec.legVout,
      seqAmount: rec.assetAtoms,
      seqAssetId: rec.asset,
      destAddress: dest,
      hashHex: rec.hashHex,
      makerSeqRefundPubHex: rec.makerRefundPub,
      seqLocktime: rec.seqLocktime,
      fee: fee,
      preimageHex: rec.preimageHex,
    );
    final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
    rec
      ..seqClaimTxid = txid
      ..state = SubState.settled;
    await SubswapStore.save(rec);
  }

  // -- NORMAL SELL (ln_direction=0) -------------------------------------------------------------------

  /// Run the P2P normal-submarine SELL to completion (pay the asset on-chain, receive BTC over Lightning).
  /// SELL PERSIST-BEFORE-FUND (fund-loss): P/H/redeem + the intended leg are persisted BEFORE the asset
  /// HTLC broadcasts, so a reload during the ~12min confirm recovers everything (never a
  /// funded-but-unpersisted asset). The taker's ONE irreversible act is settling the hold — which
  /// simultaneously captures the BTC and reveals P — so it can never reveal P without capturing the BTC.
  /// Wrapped by the [_driving] NO-DOUBLE-DRIVE guard (Task 3); its ~2h maker-pay poll never overlaps a resume.
  static Future<SubswapRecord> runSubmarineSell(SubswapRecord rec, {void Function(String)? onStep}) async {
    if (_driving) {
      throw Exception('A rail-crossing swap is already being driven; wait for it to finish or resume it before starting another.');
    }
    _driving = true;
    try {
      return await _runSubmarineSell(rec, onStep: onStep);
    } finally {
      _driving = false;
    }
  }

  static Future<SubswapRecord> _runSubmarineSell(SubswapRecord rec, {void Function(String)? onStep}) async {
    void step(String s) => onStep?.call(s);
    final m = await _mnemonic();
    final refundPub = await core.xchainSeqClaimPubkey(mnemonic: m); // canonical key, here the SEQ REFUND key
    if (rec.assetAtoms <= BigInt.zero || rec.btcSats <= BigInt.zero) {
      throw Exception('normal submarine: offer expectations (asset + atoms + msat) are required');
    }

    step('Opening a private channel to the maker…');
    final courier = await CrossCourier.open(
      offerId: rec.offerId,
      makerPubHex: rec.makerPubkey,
      takeAmount: rec.assetAtoms,
    );
    try {
      // 1. Request terms.
      await courier.send({'type': XcSubType.termsRequest});
      final terms = await courier.recv(XcSubType.terms, timeout: const Duration(minutes: 2));

      // 2. Validate terms against the signed offer + a live-tip claim window.
      final makerClaimPub = '${terms['maker_seq_claim_pub'] ?? terms['makerSeqClaimPub'] ?? ''}';
      final seqAmount = _big(terms['seq_amount'] ?? terms['seqAmount']);
      final seqLocktime = _int(terms['seq_locktime'] ?? terms['seqLocktime']);
      if (makerClaimPub.isEmpty) {
        await courier.fail('BAD_PUBKEY', 'maker_seq_claim_pub');
        throw Exception('normal submarine: bad maker_seq_claim_pub');
      }
      if (seqAmount != rec.assetAtoms) {
        await courier.fail('BAD_AMOUNT', 'seq_amount != offer');
        throw Exception('normal submarine: seq_amount $seqAmount != offer ${rec.assetAtoms}');
      }
      final seqTip = await _seqTipHeight();
      if (seqTip < 0 || !(seqLocktime > seqTip) || (seqLocktime - seqTip) < kSubClaimMargin) {
        await courier.fail('BAD_LOCKTIME', 'seq_locktime leaves too small a refund window');
        throw Exception('normal submarine: seq_locktime $seqLocktime vs tip $seqTip (min window $kSubClaimMargin)');
      }

      // 3. Mint P/H at the core, mint a bolt11 (HODL hold on H) at our OWN BTC-LN node — we RECEIVE its BTC-LN.
      step('Preparing your Lightning invoice…');
      final secret = await core.xchainNewSecret();
      final preimage = secret.secretHex.toLowerCase();
      final hashH = secret.hashHex.toLowerCase();
      final btcNodeKey = await LightningService.instance.connectNode(m, chain: 'btc');
      try {
        await LspClient.channelInbound(nodeKey: btcNodeKey, amount: rec.btcSats.toInt());
      } catch (_) {/* best-effort JIT inbound; a funded channel may already have room */}
      final hold = await LspClient.nodeInvoice(
        nodeKey: btcNodeKey,
        amount: rec.btcSats.toInt(),
        paymentHash: hashH,
        preimage: preimage,
      );
      if (hold.nodeId == null || hold.nodeId!.isEmpty) {
        throw Exception('normal submarine: could not mint the BTC-LN invoice on your node');
      }

      // 4. Build the reverse redeem (claim = maker, refund = us), then PERSIST P/H/redeem + the INTENDED
      //    leg BEFORE broadcasting the asset HTLC (crash-safety) — never strand a funded-but-unpersisted asset.
      final htlc = await core.xchainSeqHtlcReverse(
        mnemonic: m,
        hashHex: hashH,
        makerSeqClaimPubHex: makerClaimPub,
        seqLocktime: seqLocktime,
      );
      rec
        ..hashHex = hashH
        ..preimageHex = preimage
        ..seqLocktime = seqLocktime
        ..makerRefundPub = refundPub // the taker's own refund pubkey (for record symmetry)
        ..legRedeem = htlc.redeemScriptHex
        ..legP2shSpk = htlc.p2ShSpkHex // persist the HTLC P2SH spk/address so a resume in the confirm
        ..legP2shAddr = htlc.p2ShAddress // window can re-derive/scan the funding outpoint (crash-safety)
        ..btcNodeKey = btcNodeKey
        ..bolt11 = hold.bolt11 ?? ''
        ..state = SubState.funding;
      await SubswapStore.save(rec);

      // 5. Fund the asset HTLC. Real money moves — payment auth (biometric) → build → sign → the single
      //    irreversible on-chain broadcast, all inside [authorizeBuildBroadcast]. INTENT-BEFORE-BROADCAST
      //    (fund-loss, Task 2 — corrected round 7): persist broadcastAttempted=true via the onAboutToBroadcast
      //    hook, which fires INSIDE authorizeBuildBroadcast AFTER auth+build+sign succeed and IMMEDIATELY BEFORE
      //    finalizeAndBroadcast — the Dart twin of the web onAboutToFund intent, set at the SAME moment the web
      //    sets it (right before the actual fund). Setting it HERE, not earlier (before the biometric), is the
      //    whole fix: a user who CANCELS the biometric — or an insufficient-funds / sign error — throws with
      //    NOTHING funded and broadcastAttempted STILL false, so the D0 resume can drop the never-funded record
      //    (definitivelyEmpty) and the rail is NOT falsely wedged 'swap in progress' with no escape. Its ONE job
      //    once set: make the D0 SELL-resume definitivelyEmpty -> clear() path UNREACHABLE once a broadcast MAY
      //    have gone out. A crash AFTER the broadcast but BEFORE seqFundTxid persists (the post-broadcast save
      //    below) leaves a FUNDED HTLC with an empty seqFundTxid; the D0-resume address scan can then transiently
      //    return [] (a backend lagging the mempool) and MUST NOT read that as pre-commitment and clear it. With
      //    the flag set, that empty/failed scan stays RESUMABLE. seqFundTxid is still empty at hook time, so the
      //    ONLY thing distinguishing "never broadcast" from "broadcast, txid-not-yet-persisted" is this flag.
      step('Locking your asset on Sequentia…');
      var broadcastHookFired = false;
      final String fundTxid;
      try {
        fundTxid = await authorizeBuildBroadcast(
          (mnemonic) => core.buildSendTx(
            mnemonic: mnemonic,
            esploraUrl: Backend.esplora,
            recipients: [core.Recipient(address: htlc.p2ShAddress, assetId: rec.asset, satoshi: rec.assetAtoms)],
            feeRateSatKvb: null,
            feeAsset: null,
          ),
          onAboutToBroadcast: () async {
            broadcastHookFired = true;
            rec.broadcastAttempted = true;
            rec.broadcastAt = DateTime.now().millisecondsSinceEpoch; // broadcast-time stamp, DISPLAY ONLY (round 12: no longer gates abandon)
            // CLOCK-FREE HEIGHT stamp for the abandon HEIGHT PROOF (round 11): read the Sequentia tip height at the
            // moment of broadcast (at-or-below where the funding can confirm). An unreadable tip (-1) stores 0 —
            // the record then fails closed (not abandonable) rather than trusting a scan it cannot height-prove.
            //
            // BEST-EFFORT MAX (round 13): capture from the MAX of a couple of tip reads so ONE lagging broadcast-time
            // replica cannot UNDER-record the height. Under-recording is the dangerous direction — a too-low
            // broadcastSeqHeight would let the abandon height proof [tipHeightProvesEmptyScan] pass too EARLY (before
            // the funding window is truly buried), risking a false-empty clear over a funded HTLC. MAX is fund-safe:
            // over-recording only makes the proof MORE conservative (it waits longer; never a false empty). This is a
            // capture-time variant of the single-oracle residual — soundness still ASSUMES the best of these reads is
            // within kAbandonMinConfDepth of the true tip (documented on [abandonUnfundedSell]). An unreadable read
            // (-1) simply loses the max; if BOTH are unreadable the stamp is 0 -> fails closed (not abandonable).
            final h1 = await _seqTipHeight();
            final h2 = await _seqTipHeight();
            final h = h1 > h2 ? h1 : h2;
            rec.broadcastSeqHeight = h > 0 ? h : 0;
            await SubswapStore.save(rec);
          },
        );
      } catch (e) {
        // Belt-and-suspenders (round 7): a throw BEFORE the pre-broadcast hook fired (biometric auth-cancel /
        // insufficient funds / sign error) means NOTHING was funded — FORCE broadcastAttempted back to false so
        // the never-funded record stays definitively-empty/clearable via the D0 pre-commitment path and the rail
        // is not wedged. A throw AT/AFTER the hook (the broadcast may have gone out) keeps broadcastAttempted
        // true -> RESUMABLE, never cleared. Persist only when we actually flip a persisted-true back to false.
        if (!broadcastHookFired && rec.broadcastAttempted) {
          rec.broadcastAttempted = false;
          rec.broadcastAt = 0; // no broadcast went out -> clear the display stamp too
          rec.broadcastSeqHeight = 0; // and the height stamp -> the never-funded record has nothing to prove against
          await SubswapStore.save(rec);
        }
        rethrow;
      }
      rec.seqFundTxid = fundTxid;
      await SubswapStore.save(rec);

      // 5b. Wait for the funding to confirm; capture the REAL HTLC-P2SH vout + block hash. FAIL CLOSED on an
      //     spk no-match: NEVER default the vout to 0 (that would settle/refund against the change output).
      //     Keep polling within the confirm loop until the actual HTLC output matches in a confirmed block;
      //     if it never matches, throw (the leg outpoint — settle + CLTV-refund target — must be the real vout).
      step('Waiting for your asset lock to confirm (about one block)…');
      var vout = -1;
      var blockHash = '';
      for (var i = 0; i < 240; i++) {
        final tx = await _seqTx(fundTxid);
        if (tx != null) {
          final v = _findVout(tx, htlc.p2ShSpkHex);
          final status = tx['status'] as Map?;
          final confirmed = status != null && status['confirmed'] == true;
          if (v >= 0 && confirmed) {
            final bh = '${status['block_hash'] ?? ''}';
            if (bh.isNotEmpty) {
              vout = v;
              blockHash = bh;
              break;
            }
          }
        }
        await Future<void>.delayed(const Duration(seconds: 12));
      }
      if (blockHash.isEmpty || vout < 0) {
        throw Exception('normal submarine: your asset HTLC has not confirmed to a matched HTLC output yet; it is refundable after block $seqLocktime.');
      }
      rec
        ..legTxid = fundTxid
        ..legVout = vout
        ..legBlockHash = blockHash
        ..state = SubState.settling;
      await SubswapStore.save(rec);

      // 6. Announce the funded leg + the invoice (the maker verifies + anchor-gates + pays).
      await courier.send({
        'type': XcSubType.assetFunded,
        'hash_h': hashH,
        'taker_seq_refund_pub': refundPub.toLowerCase(),
        if ((hold.bolt11 ?? '').isNotEmpty) 'bolt11': hold.bolt11,
        'taker_ln_node_id': hold.nodeId, // pay-by-hash fallback when no payable bolt11
        'amount_msat': (rec.btcSats * BigInt.from(1000)).toInt(),
        'leg': {
          'txid': fundTxid,
          'vout': vout,
          'amount': rec.assetAtoms.toInt(),
          'asset': rec.asset,
          'redeem_script': htlc.redeemScriptHex,
          'locktime': seqLocktime,
          'block_hash': blockHash,
        },
      });

      // 7. Await the hold being HELD, then SETTLE it with P (receive BTC-LN + reveal P -> maker claims asset).
      step('Waiting for the maker to pay your invoice…');
      final deadline = DateTime.now().add(const Duration(hours: 2));
      while (true) {
        HodlInvoiceStatus? s;
        try {
          s = await LspClient.invoiceStatus(nodeKey: btcNodeKey, paymentHash: hashH);
        } catch (_) {/* keep waiting (mirror the web .catch) */}
        if (s != null && s.settled) {
          rec.state = SubState.settled;
          await SubswapStore.save(rec);
          return rec;
        }
        if (s != null && s.held) {
          step('Settling — receiving your Bitcoin…');
          await LspClient.nodeSettle(nodeKey: btcNodeKey, paymentHash: hashH, preimage: preimage); // capture + reveal
          rec.state = SubState.settled;
          await SubswapStore.save(rec);
          return rec;
        }
        if (DateTime.now().isAfter(deadline)) {
          // Unpaid: keep the leg for a T_seq refund (recovered via [resume]). Nothing else was committed.
          rec.detail = 'The maker never paid your invoice in time; your asset is refundable after block $seqLocktime.';
          await SubswapStore.save(rec);
          return rec;
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    } catch (e) {
      await courier.close();
      rethrow;
    } finally {
      await courier.close();
    }
  }

  // -- RESUME on load ---------------------------------------------------------------------------------

  /// Resume a persisted submarine. FUND-SAFETY: a BUY that already learned P + verified the leg (state
  /// 'claiming') re-claims idempotently (a crash between the irreversible act and the claim never strands
  /// the asset). A BUY that persisted its leg + bolt11 + H before the pay ('paying') MAY have paid, so it
  /// re-queries the node for the settled payment on H (idempotent re-pay returns the cached preimage),
  /// then claims — guarded by the claim window. A SELL still in the confirm window ('funding') re-derives
  /// or scans its funding outpoint and continues (dropping ONLY a definitive pre-commitment). A SELL whose
  /// asset HTLC is funded ('settling') re-checks the hold: settle if HELD, else refund after T_seq.
  /// Terminal records are dropped.
  ///
  /// NO-DOUBLE-DRIVE (Task 3): the cold-start UNAWAITED resume (shell) and a user tap on 'Resume swap' both
  /// call this; the [_driving] guard short-circuits the second so the SAME record is never settled/claimed/
  /// refunded twice concurrently. The internal D0->C handoff calls [_resumeInner] directly (already inside the
  /// guard) so the re-entrant continuation is not itself short-circuited.
  static Future<void> resume({void Function(String)? onStep}) async {
    if (_driving) return; // a drive is already running this record — do not fire a second concurrent one
    _driving = true;
    try {
      await _resumeInner(onStep: onStep);
    } finally {
      _driving = false;
    }
  }

  static Future<void> _resumeInner({void Function(String)? onStep}) async {
    // The synchronous guard is PRIMED earlier, in shell's AWAITED startup ([SubswapStore.primeInFlight]),
    // so it is already authoritative before the Swap tab is interactive. This heavy settlement drive runs
    // UNAWAITED, AFTER priming. [load] itself keeps the guard current (a definitive null => not-in-flight; a
    // read error fails safe to in-flight and rethrows to the caller's .catchError), so no separate
    // markInFlight is needed here (Task 1/2).
    final rec = await SubswapStore.load();
    if (rec == null) return;
    if (rec.terminal) {
      await SubswapStore.clear();
      return;
    }
    final m = await _mnemonic();

    // (A) A BUY that already learned P + verified the leg: re-claim idempotently.
    if (rec.buy && rec.preimageHex.isNotEmpty && rec.legTxid.isNotEmpty && rec.state == SubState.claiming) {
      try {
        await _claimReverse(rec, m);
      } catch (e) {
        rec.detail = e.toString().replaceFirst('Exception: ', ''); // leave RESUMABLE (we hold P)
        await SubswapStore.save(rec);
      }
      return;
    }

    // (B) CRASH GAP — a BUY that persisted leg + bolt11 + H before the (irreversible) pay but crashed
    //     before learning P. It MAY have paid, so NEVER drop it: re-query the node (idempotent re-pay
    //     returns the cached preimage), then claim. Guarded by the claim window (past T_seq we do NOT re-pay).
    if (rec.buy && rec.state == SubState.paying && rec.legTxid.isNotEmpty && rec.bolt11.isNotEmpty && rec.preimageHex.isEmpty) {
      try {
        final tip = await _seqTipHeight();
        if (tip >= 0 && !(rec.seqLocktime > tip + kSubClaimMargin)) {
          rec.detail = 'The claim window has closed; not re-paying (no loss).';
          await SubswapStore.save(rec);
          return;
        }
        final btcNodeKey = rec.btcNodeKey.isNotEmpty ? rec.btcNodeKey : await LightningService.instance.connectNode(m, chain: 'btc');
        final pay = await LspClient.nodePay(nodeKey: btcNodeKey, bolt11: rec.bolt11, wantHash: rec.hashHex); // idempotent: cached P
        final preimage = (pay.preimage ?? '').toLowerCase();
        // Require a 32-byte P that ALSO hashes to H (mirror resumeReversePay's sha256(P)==H) before claiming —
        // a recovered preimage that does not hash to H opens nothing, so keep resumable rather than claim on it.
        if (_kHex64.hasMatch(preimage) && _sha256Hex(preimage) == rec.hashHex.toLowerCase()) {
          rec
            ..preimageHex = preimage
            ..btcNodeKey = btcNodeKey
            ..state = SubState.claiming;
          await SubswapStore.save(rec);
          await _claimReverse(rec, m);
        } else {
          rec.detail = _kHex64.hasMatch(preimage)
              ? 'The recovered preimage does not hash to H — not claiming (keep resumable).'
              : 'The Bitcoin Lightning payment has not settled yet — keep resumable.';
          await SubswapStore.save(rec); // NEVER dropped
        }
      } catch (e) {
        rec.detail = e.toString().replaceFirst('Exception: ', '');
        await SubswapStore.save(rec);
      }
      return;
    }

    // (D0) CRASH GAP (SELL fund-loss) — a SELL that PERSISTED P/H/redeem + the intended leg BEFORE it
    //      broadcast the asset HTLC (state 'funding') but crashed during the confirm window. The asset MAY be
    //      funded on-chain, so this record must NEVER be dropped: re-derive the funding outpoint from the
    //      persisted fund txid, else SCAN the HTLC P2SH address. It is PRE-COMMITMENT (drop cleanly) ONLY when the
    //      broadcast was NEVER reached (broadcastAttempted == false) AND the P2SH is definitively empty. A
    //      transient/unreadable read — OR any broadcastAttempted record with an empty scan (Task 2: a backend
    //      lagging the mempool) — is NOT definitive -> keep it resumable (retry next boot), never a false drop of a
    //      funded-but-txid-unpersisted asset. Once found, advance to 'settling' and continue at (C). Mirrors web D0.
    if (!rec.buy &&
        rec.state == SubState.funding &&
        rec.legRedeem.isNotEmpty &&
        rec.legTxid.isEmpty &&
        rec.preimageHex.isNotEmpty &&
        rec.hashHex.isNotEmpty) {
      try {
        final spk = rec.legP2shSpk.toLowerCase();
        final addr = rec.legP2shAddr;
        String? foundTxid;
        var foundVout = -1;
        var foundBlockHash = '';
        var definitivelyEmpty = false;

        // 1) Primary: the persisted fund txid (set right after broadcast). Match the REAL HTLC-P2SH vout —
        //    never a change output. A null tx read here is NOT definitive (could be transient/eventual).
        if (rec.seqFundTxid.isNotEmpty && spk.isNotEmpty) {
          final tx = await _seqTx(rec.seqFundTxid);
          if (tx != null) {
            final v = _findVout(tx, spk);
            if (v >= 0) {
              foundTxid = rec.seqFundTxid;
              foundVout = v;
              final status = tx['status'] as Map?;
              if (status != null && status['confirmed'] == true) foundBlockHash = '${status['block_hash'] ?? ''}';
            }
          }
        }

        // 2) Fallback: SCAN the HTLC P2SH address for the funding outpoint — covers a broadcast whose txid
        //    was never persisted (crash between broadcast and the seqFundTxid save). Esplora /address/<a>/utxo
        //    includes the mempool, so a definitive EMPTY (200, []) with NO fund txid means nothing was ever
        //    committed. A read error returns null -> NOT definitive -> keep resumable.
        if (foundTxid == null && addr.isNotEmpty) {
          final utxos = await _seqAddressUtxos(addr);
          if (utxos == null) {
            rec.detail = 'Recovering your rail-crossing sell · waiting for the asset HTLC to appear on-chain.';
            await SubswapStore.save(rec); // transient — NEVER dropped
            return;
          }
          if (utxos.isNotEmpty) {
            final u = (utxos.first as Map);
            foundTxid = '${u['txid'] ?? ''}';
            foundVout = _int(u['vout']);
            final status = u['status'] as Map?;
            if (status != null && status['confirmed'] == true) foundBlockHash = '${status['block_hash'] ?? ''}';
          } else if (rec.seqFundTxid.isEmpty && !rec.broadcastAttempted) {
            // PRE-COMMITMENT ONLY: no fund txid, the broadcast was NEVER reached (broadcastAttempted == false —
            // the flag is set ONLY by the onAboutToBroadcast hook inside authorizeBuildBroadcast, which fires
            // AFTER auth+build+sign succeed and IMMEDIATELY BEFORE finalizeAndBroadcast, so an unset flag proves
            // no broadcast went out), AND the P2SH is definitively unfunded (esplora /utxo covers confirmed +
            // mempool). This is the
            // ONLY case that may be dropped. Once broadcastAttempted is set (Task 2), an empty/failed scan is
            // NEVER definitive: a backend lagging the mempool must not strand a FUNDED HTLC whose seqFundTxid had
            // not yet persisted — keep it RESUMABLE (retry next boot). A set seqFundTxid likewise keeps it live.
            definitivelyEmpty = true;
          }
        }

        if (foundTxid != null && foundTxid.isNotEmpty && foundVout >= 0) {
          rec
            ..legTxid = foundTxid
            ..legVout = foundVout
            ..legBlockHash = foundBlockHash.isNotEmpty ? foundBlockHash : rec.legBlockHash
            ..state = SubState.settling;
          await SubswapStore.save(rec);
          await _resumeInner(onStep: onStep); // continue at (C): settle with P / refund after T_seq (re-entrant, still inside the drive guard)
          return;
        }
        if (definitivelyEmpty) {
          // Reachable ONLY when broadcastAttempted == false (Task 2): the broadcast was never reached and the
          // P2SH is definitively unfunded, so nothing was ever locked and the live courier session is gone —
          // drop cleanly (no dangling record wedging the rail, no double-fund — nothing to fund). A record whose
          // broadcast WAS attempted can never take this branch, so a funded-but-txid-unpersisted HTLC is never cleared.
          await SubswapStore.clear();
          return;
        }
        // Not yet visible / unreadable: keep resumable (never a false drop of a possibly-funded SELL).
        rec.detail = 'Recovering your rail-crossing sell · waiting for the asset HTLC to appear on-chain.';
        await SubswapStore.save(rec);
      } catch (e) {
        rec.detail = e.toString().replaceFirst('Exception: ', '');
        await SubswapStore.save(rec);
      }
      return;
    }

    // (C) A SELL whose asset HTLC is funded: re-check the hold — settle with P if HELD, else refund after T_seq.
    if (!rec.buy && rec.legTxid.isNotEmpty && rec.state == SubState.settling) {
      try {
        final btcNodeKey = rec.btcNodeKey.isNotEmpty ? rec.btcNodeKey : await LightningService.instance.connectNode(m, chain: 'btc');
        HodlInvoiceStatus? s;
        try {
          s = await LspClient.invoiceStatus(nodeKey: btcNodeKey, paymentHash: rec.hashHex);
        } catch (_) {}
        if (s != null && s.settled) {
          rec.state = SubState.settled;
          await SubswapStore.save(rec);
          return;
        }
        if (s != null && s.held && rec.preimageHex.isNotEmpty) {
          await LspClient.nodeSettle(nodeKey: btcNodeKey, paymentHash: rec.hashHex, preimage: rec.preimageHex);
          rec.state = SubState.settled;
          await SubswapStore.save(rec);
          return;
        }
        // Not paid: reclaim the asset via CLTV after T_seq (idempotent — a pre-timeout attempt just fails).
        final tip = await _seqTipHeight();
        if (tip >= 0 && tip >= rec.seqLocktime) {
          final dest = await core.receiveAddress(mnemonic: m);
          final fee = await _seqRefundFee(rec.asset, rec.assetAtoms);
          final hex = await core.xchainSeqRefund(
            mnemonic: m,
            seqTxid: rec.legTxid,
            seqVout: rec.legVout,
            seqAmount: rec.assetAtoms,
            seqAssetId: rec.asset,
            destAddress: dest,
            feeAtoms: fee,
            redeemScriptHex: rec.legRedeem,
            seqLocktime: rec.seqLocktime,
          );
          final txid = await core.xchainSeqBroadcast(seqEsplora: Backend.esplora, txHex: hex);
          rec
            ..seqRefundTxid = txid
            ..state = SubState.refunded;
          await SubswapStore.save(rec);
        }
      } catch (e) {
        rec.detail = e.toString().replaceFirst('Exception: ', '');
        await SubswapStore.save(rec);
      }
      return;
    }

    // Pre-commitment (no P, no funded leg): the live courier session cannot be resumed and nothing was
    // committed — drop it. (A 'paying' buy / funded sell are handled above and NEVER reach here.)
    await SubswapStore.clear();
  }

  // -- chain reads + per-asset fees (mirror XchainReverseSwapService / XchainSwapService) --------------

  /// POLL the SEQ funding block's Bitcoin-anchor depth until buried >= [minDepth], or a deadline elapses.
  /// The funding block is derived from the ACTUAL txid's OWN confirmed status (never a maker-supplied
  /// block). A still-mempool (0-conf) funding is WAITED OUT (never trusted). Fails CLOSED on timeout.
  static Future<bool> _waitAnchorBuried({
    required String txid,
    required int minDepth,
    void Function()? onWait,
    Duration deadline = const Duration(minutes: 20),
    Duration poll = const Duration(seconds: 20),
  }) async {
    final until = DateTime.now().add(deadline);
    while (true) {
      final tx = await _seqTx(txid);
      final status = tx?['status'] as Map?;
      final confirmed = status != null && status['confirmed'] == true;
      final blockHash = '${status?['block_hash'] ?? ''}';
      if (confirmed && blockHash.isNotEmpty) {
        try {
          // No BTC on-chain leg on the submarine path, so btcLegHeight = 0 (no BTC-height constraint); the
          // depth + anchorstatus gate governs. The block hash is the txid's OWN canonical block (esplora).
          final ev = await core.xchainVerifySeqLegSafe(
            seqEsplora: Backend.esplora,
            seqBlockHash: blockHash,
            btcLegHeight: 0,
            t4Api: Backend.testnet4,
            minDepth: minDepth,
          );
          if (ev.ok) return true;
        } catch (_) {/* transient / not-yet-anchored — wait and retry */}
      }
      if (DateTime.now().isAfter(until)) return false;
      onWait?.call();
      await Future<void>.delayed(poll);
    }
  }

  /// The SEQ-claim fee in atoms of the CLAIMED asset, from the published rate (min 1 atom, capped at half
  /// the output). Fails CLOSED when the feed has no per-asset rate — an unmineable claim leaves P public
  /// while the leg sits unmined (mirror XchainSwapService._seqClaimFee).
  static Future<BigInt> _seqClaimFee(String assetHex, BigInt amount) async {
    final ticker = SeqAssets.labelFor(assetHex).ticker;
    final rates = await ApiClient.feeRates();
    final rate = rates[ticker] ?? rates[assetHex];
    if (rate == null || rate <= BigInt.zero) {
      throw Exception('No Sequentia fee rate for $ticker, so the claim fee cannot be sized safely; your secret was NOT revealed.');
    }
    final native = BigInt.from(400);
    var fee = (native * _kScale + rate - BigInt.one) ~/ rate;
    if (fee < BigInt.one) fee = BigInt.one;
    final half = amount ~/ BigInt.two;
    if (half >= BigInt.one && fee > half) fee = half;
    return fee;
  }

  /// The SEQ-refund fee in atoms of the traded asset (min 1 atom, capped at half). Best-effort feed;
  /// falls back to the reference scale when the feed omits the asset (mirror XchainReverseSwapService).
  static Future<BigInt> _seqRefundFee(String assetHex, BigInt amount) async {
    final ticker = SeqAssets.labelFor(assetHex).ticker;
    Map<String, BigInt> rates;
    try {
      rates = await ApiClient.feeRates();
    } catch (_) {
      rates = const {};
    }
    final rate = rates[ticker] ?? rates[assetHex] ?? _kScale;
    final native = BigInt.from(400);
    var fee = (native * _kScale + rate - BigInt.one) ~/ rate;
    if (fee < BigInt.one) fee = BigInt.one;
    final half = amount ~/ BigInt.two;
    if (fee > half) fee = half < BigInt.one ? BigInt.one : half;
    return fee;
  }

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

  /// The confirmed + mempool UTXOs at [address] via esplora `/address/<addr>/utxo`. Returns the list on a
  /// DEFINITIVE read (an empty list means the address is genuinely unfunded — /utxo includes the mempool),
  /// or null on a transient read error (a non-200 / exception), so the SELL-resume never drops a
  /// possibly-funded leg on an unreadable state. Used to SCAN the HTLC P2SH for a lost/unpersisted funding.
  static Future<List<dynamic>?> _seqAddressUtxos(String address) async {
    try {
      final resp = await http
          .get(Uri.parse('${Backend.esplora}/address/$address/utxo'), headers: Backend.authHeaders)
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body);
      return j is List ? j : null;
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

  // NOTE (round 11): the round-10 `_seqTipBlockTimeSecs` helper (tip block-TIME, for the device-clock freshness
  // check) is GONE. The abandon freshness gate is now CLOCK-FREE and height-based ([tipHeightProvesEmptyScan]),
  // so it reads only the tip HEIGHT ([_seqTipHeight]) — no block-time, no DateTime.now() in the primary gate.

  static BigInt _big(Object? v) => BigInt.tryParse('${v ?? 0}') ?? BigInt.zero;
  static int _int(Object? v) => v is int ? v : int.tryParse('${v ?? 0}') ?? 0;

  /// sha256 of the [preimageHex] bytes, as 32-byte lowercased hex — the H = sha256(P) check the taker runs
  /// post-pay (defence past wantHash) and on resume before claiming. Returns '' on an unparseable preimage
  /// so the caller's `!= H` comparison fails closed.
  static String _sha256Hex(String preimageHex) {
    try {
      return sha256.convert(_hexBytes(preimageHex)).toString().toLowerCase();
    } catch (_) {
      return '';
    }
  }

  static List<int> _hexBytes(String hex) {
    final s = (hex.startsWith('0x') ? hex.substring(2) : hex);
    if (s.isEmpty || s.length.isOdd) throw const FormatException('bad hex');
    final out = List<int>.filled(s.length ~/ 2, 0);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
